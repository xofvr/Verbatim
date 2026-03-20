@preconcurrency import AVFoundation
import CoreAudio
import Dependencies
import DependenciesMacros
import Foundation
import os

private let audioLogger = Logger(subsystem: "farhan.verbatim", category: "AudioClient")

enum AudioClientError: LocalizedError, Sendable {
    case notRecording
    case failedToStart(reason: String)

    var errorDescription: String? {
        switch self {
        case .notRecording:
            return "No recording is currently active."
        case .failedToStart(let reason):
            return "Verbatim could not start recording audio: \(reason)"
        }
    }
}

@DependencyClient
public struct AudioClient: Sendable {
    public var isRecording: @Sendable () async -> Bool = { false }
    public var warmup: @Sendable () -> Void = {}
    public var startRecording: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    public var stopRecording: @Sendable () async throws -> URL
    public var cancelRecording: @Sendable () async -> Void = {}
    public var setInputDevice: @Sendable (_ uid: String?) -> Void = { _ in }
    public var availableInputDevices: @Sendable () -> [AudioInputDevice] = { [] }
    public var onInputDevicesChanged: @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in }
}

extension AudioClient: DependencyKey {
    public static var liveValue: Self {
        return Self(
            isRecording: {
                LiveAudioCaptureRuntimeContainer.shared.isRecording
            },
            warmup: {
                LiveAudioCaptureRuntimeContainer.shared.warmup()
            },
            startRecording: { levelHandler in
                try await LiveAudioCaptureRuntimeContainer.shared.startRecording(levelHandler: levelHandler)
            },
            stopRecording: {
                try await LiveAudioCaptureRuntimeContainer.shared.stopRecording()
            },
            cancelRecording: {
                await LiveAudioCaptureRuntimeContainer.shared.cancelRecording()
            },
            setInputDevice: { uid in
                LiveAudioCaptureRuntimeContainer.shared.setInputDevice(uid)
            },
            availableInputDevices: {
                LiveAudioCaptureRuntimeContainer.shared.availableInputDevices()
            },
            onInputDevicesChanged: { handler in
                LiveAudioCaptureRuntimeContainer.shared.onInputDevicesChanged(handler)
            }
        )
    }
}

extension AudioClient: TestDependencyKey {
    public static var testValue: Self {
        Self(
            isRecording: { false },
            warmup: {},
            startRecording: { _ in },
            stopRecording: { URL(fileURLWithPath: "/dev/null") },
            cancelRecording: {},
            setInputDevice: { _ in },
            availableInputDevices: { [] },
            onInputDevicesChanged: { _ in }
        )
    }
}

public extension DependencyValues {
    var audioClient: AudioClient {
        get { self[AudioClient.self] }
        set { self[AudioClient.self] = newValue }
    }
}

/// Thread-safe rolling-average level smoother, captured by the audio tap
/// closure so that `LiveAudioCaptureRuntime` is never referenced from the
/// real-time audio thread.
private final class LevelSmoother: @unchecked Sendable {
    private var levels: [Double] = []
    private let windowSize: Int
    private let lock = NSLock()

    init(windowSize: Int = 8) {
        self.windowSize = windowSize
    }

    func smooth(_ level: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        levels.append(level)
        if levels.count > windowSize {
            levels.removeFirst(levels.count - windowSize)
        }
        return levels.reduce(0, +) / Double(levels.count)
    }
}

private final class LiveAudioCaptureRuntime: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "farhan.verbatim.audio.capture.runtime")
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var simulatedRecordingSourceURL: URL?
    private var recordingURL: URL?
    private var levelHandler: @Sendable (Double) -> Void = { _ in }
    private var levelTimer: DispatchSourceTimer?
    private let levelSmoother = LevelSmoother()
    private var selectedDeviceUID: String?
    private let deviceManager = AudioDeviceManager()
    private var standbyEngine: AVAudioEngine?

    private static let sampleRate: Double = 44_100
    private static let channels: AVAudioChannelCount = 1
    private static let bitDepth: UInt32 = 16

    var isRecording: Bool {
        stateQueue.sync {
            if simulatedRecordingSourceURL != nil {
                return true
            }
            return engine?.isRunning ?? false
        }
    }

    func warmup() {
        stateQueue.async { [self] in
            warmupStandbyLocked()
        }
    }

    func setInputDevice(_ uid: String?) {
        stateQueue.async { [self] in
            selectedDeviceUID = (uid?.isEmpty == true) ? nil : uid
        }
    }

    func availableInputDevices() -> [AudioInputDevice] {
        deviceManager.availableInputDevices()
    }

    func onInputDevicesChanged(_ handler: @escaping @Sendable () -> Void) {
        deviceManager.startMonitoring(handler)
    }

    func startRecording(levelHandler: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                do {
                    try startRecordingLocked(levelHandler: levelHandler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func warmupStandbyLocked() {
        guard standbyEngine == nil, engine == nil else { return }
        guard Self.e2eAudioFixtureURL() == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // Guard against no input devices being available (e.g. no microphone attached)
        guard !deviceManager.availableInputDevices().isEmpty else { return }

        let eng = AVAudioEngine()
        applyDeviceSelectionLocked(to: eng)
        standbyEngine = eng
    }

    private func applyDeviceSelectionLocked(to eng: AVAudioEngine) {
        guard let uid = selectedDeviceUID else { return }
        let devices = deviceManager.availableInputDevices()
        guard let device = devices.first(where: { $0.uid == uid }) else { return }

        let inputNode = eng.inputNode
        let audioUnit = inputNode.audioUnit!
        var deviceID = device.id
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func startRecordingLocked(levelHandler: @escaping @Sendable (Double) -> Void) throws {
        guard engine == nil, simulatedRecordingSourceURL == nil else { return }
        self.levelHandler = levelHandler

        if let e2eAudioURL = Self.e2eAudioFixtureURL() {
            simulatedRecordingSourceURL = e2eAudioURL
            recordingURL = e2eAudioURL
            startSimulatedLevelPollingLocked()
            return
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            audioLogger.error("Microphone permission not authorized (status: \(String(describing: micStatus), privacy: .public))")
            throw AudioClientError.failedToStart(reason: "microphone permission not granted")
        }

        let audioURL = FileManager.default.temporaryDirectory
            .appending(path: "verbatim-\(UUID().uuidString).wav")

        // Use pre-warmed standby engine or create fresh
        let eng: AVAudioEngine
        if let standby = standbyEngine {
            standbyEngine = nil
            eng = standby
        } else {
            eng = AVAudioEngine()
            applyDeviceSelectionLocked(to: eng)
        }

        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioLogger.info("Input format: \(inputFormat.description, privacy: .public)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            audioLogger.error("Invalid input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            throw AudioClientError.failedToStart(reason: "no valid audio input — is a microphone connected?")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        ) else {
            audioLogger.error("Could not create output AVAudioFormat")
            throw AudioClientError.failedToStart(reason: "could not create output audio format")
        }

        guard let file = try? AVAudioFile(
            forWriting: audioURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        ) else {
            audioLogger.error("Could not create AVAudioFile at \(audioURL.path, privacy: .public)")
            throw AudioClientError.failedToStart(reason: "could not create audio file")
        }

        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard converter != nil || inputFormat == outputFormat else {
            audioLogger.error("No converter available: input \(inputFormat.description, privacy: .public) → output \(outputFormat.description, privacy: .public)")
            throw AudioClientError.failedToStart(reason: "incompatible audio format — try a different input device")
        }

        let smoother = self.levelSmoother
        let handler = levelHandler

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // Compute RMS for level metering
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sumOfSquares: Float = 0
            let samples = channelData[0]
            for i in 0..<frameLength {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
            let rms = sqrt(sumOfSquares / Float(frameLength))
            let power: Float = rms > 0 ? 20 * log10(rms) : -160
            let normalized = Self.normalizePower(power)
            let smoothed = smoother.smooth(normalized)
            DispatchQueue.main.async {
                handler(smoothed)
            }

            // Write audio to file, converting format if needed
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * (Self.sampleRate / inputFormat.sampleRate)
                )
                guard frameCapacity > 0,
                      let convertedBuffer = AVAudioPCMBuffer(
                          pcmFormat: outputFormat,
                          frameCapacity: max(frameCapacity, 1)
                      ) else { return }

                var error: NSError?
                nonisolated(unsafe) var inputConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil, convertedBuffer.frameLength > 0 {
                    try? file.write(from: convertedBuffer)
                }
            } else {
                try? file.write(from: buffer)
            }
        }

        do {
            try eng.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioLogger.error("AVAudioEngine failed to start: \(error.localizedDescription, privacy: .public)")
            throw AudioClientError.failedToStart(reason: "audio engine failed to start — \(error.localizedDescription)")
        }

        audioLogger.info("Recording started successfully")
        self.engine = eng
        self.audioFile = file
        recordingURL = audioURL
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                do {
                    let url = try stopRecordingLocked()
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stopRecordingLocked() throws -> URL {
        if let fixtureURL = simulatedRecordingSourceURL {
            return try stopSimulatedRecordingLocked(sourceURL: fixtureURL)
        }

        guard let eng = engine, let url = recordingURL else {
            throw AudioClientError.notRecording
        }

        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        self.engine = nil
        self.audioFile = nil
        recordingURL = nil
        levelHandler(0)

        // Pre-warm next standby engine in the background
        stateQueue.asyncAfter(deadline: .now() + 0.1) { [self] in
            warmupStandbyLocked()
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0

        guard fileSize > 44 else {
            audioLogger.error("Recording file too small (\(fileSize) bytes), discarding")
            try? FileManager.default.removeItem(at: url)
            throw AudioClientError.failedToStart(reason: "recording was empty — no audio was captured")
        }

        return url
    }

    func cancelRecording() async {
        await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                cancelRecordingLocked()
                continuation.resume()
            }
        }
    }

    private func cancelRecordingLocked() {
        if simulatedRecordingSourceURL != nil {
            stopLevelPollingLocked()
            simulatedRecordingSourceURL = nil
            recordingURL = nil
            levelHandler(0)
            return
        }

        guard let eng = engine else { return }

        eng.inputNode.removeTap(onBus: 0)
        eng.stop()

        let url = recordingURL
        self.engine = nil
        self.audioFile = nil
        recordingURL = nil
        levelHandler(0)
        if let url {
            try? FileManager.default.removeItem(at: url)
        }

        // Pre-warm next standby engine in the background
        stateQueue.asyncAfter(deadline: .now() + 0.1) { [self] in
            warmupStandbyLocked()
        }
    }

    private func stopSimulatedRecordingLocked(sourceURL: URL) throws -> URL {
        stopLevelPollingLocked()
        simulatedRecordingSourceURL = nil
        recordingURL = nil
        levelHandler(0)

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "verbatim-e2e-\(UUID().uuidString).wav")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? Int64 ?? 0
        guard fileSize > 44 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioClientError.failedToStart(reason: "simulated recording file was empty")
        }
        return outputURL
    }

    private func startSimulatedLevelPollingLocked() {
        levelTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(60))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let smoothed = self.levelSmoother.smooth(0.34)
            let handler = self.levelHandler
            DispatchQueue.main.async {
                handler(smoothed)
            }
        }
        levelTimer = timer
        timer.resume()
    }

    private func stopLevelPollingLocked() {
        levelTimer?.cancel()
        levelTimer = nil
    }

    nonisolated private static func normalizePower(_ power: Float) -> Double {
        if power <= -80 {
            return 0
        }
        let normalized = (Double(power) + 50.0) / 50.0
        return max(0, min(1, normalized))
    }

    nonisolated private static func e2eAudioFixtureURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["VERBATIM_E2E_AUDIO_FILE"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let path = UserDefaults.standard.string(forKey: "e2e_audio_file"), !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }
}

private enum LiveAudioCaptureRuntimeContainer {
    static let shared = LiveAudioCaptureRuntime()
}
