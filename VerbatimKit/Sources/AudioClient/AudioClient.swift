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

/// State for the raw AUHAL direct capture path, passed to the C render
/// callback via refCon. Used when the system default input is Bluetooth
/// but we want a non-Bluetooth device — bypasses AVAudioEngine's aggregate
/// device which would briefly activate the Bluetooth microphone.
private final class DirectCaptureContext: @unchecked Sendable {
    let audioUnit: AudioUnit
    let audioFile: AVAudioFile
    let converter: AVAudioConverter?
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    let smoother: LevelSmoother
    var levelHandler: @Sendable (Double) -> Void

    init(audioUnit: AudioUnit, audioFile: AVAudioFile, converter: AVAudioConverter?,
         inputFormat: AVAudioFormat, outputFormat: AVAudioFormat,
         smoother: LevelSmoother, levelHandler: @escaping @Sendable (Double) -> Void) {
        self.audioUnit = audioUnit
        self.audioFile = audioFile
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.smoother = smoother
        self.levelHandler = levelHandler
    }
}

/// C-callable render callback for direct AUHAL capture. Called on the
/// audio I/O thread when input data is available from the hardware.
private func directCaptureInputProc(
    _ refCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<DirectCaptureContext>.fromOpaque(refCon).takeUnretainedValue()
    let asbd = ctx.inputFormat.streamDescription.pointee
    let bytesPerFrame = asbd.mBytesPerFrame
    let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bufferCount = isNonInterleaved ? Int(asbd.mChannelsPerFrame) : 1

    // Allocate buffer list for AudioUnitRender
    let ablByteCount = MemoryLayout<AudioBufferList>.size
        + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
    let ablPtr = UnsafeMutableRawPointer.allocate(
        byteCount: ablByteCount, alignment: MemoryLayout<AudioBufferList>.alignment
    ).assumingMemoryBound(to: AudioBufferList.self)
    defer { ablPtr.deallocate() }
    ablPtr.pointee.mNumberBuffers = UInt32(bufferCount)
    let bufs = UnsafeMutableAudioBufferListPointer(ablPtr)

    let dataSize = Int(inNumberFrames) * Int(bytesPerFrame)
    let channelsPerBuf: UInt32 = isNonInterleaved ? 1 : asbd.mChannelsPerFrame
    for i in 0..<bufferCount {
        let data = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 4)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: dataSize)
        bufs[i] = AudioBuffer(
            mNumberChannels: channelsPerBuf,
            mDataByteSize: UInt32(dataSize),
            mData: data
        )
    }
    defer { for i in 0..<bufferCount { bufs[i].mData?.deallocate() } }

    // Render input audio from the AUHAL
    let renderStatus = AudioUnitRender(
        ctx.audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr
    )
    guard renderStatus == noErr else { return renderStatus }

    // Level metering from first channel
    if let data = bufs[0].mData {
        let samples = data.assumingMemoryBound(to: Float.self)
        var sumOfSquares: Float = 0
        for i in 0..<Int(inNumberFrames) {
            let s = samples[i]
            sumOfSquares += s * s
        }
        let rms = sqrt(sumOfSquares / Float(inNumberFrames))
        let power: Float = rms > 0 ? 20 * log10(rms) : -160
        let normalized: Double = power <= -80
            ? 0
            : max(0, min(1, (Double(power) + 50.0) / 50.0))
        let smoothed = ctx.smoother.smooth(normalized)
        let handler = ctx.levelHandler
        DispatchQueue.main.async { handler(smoothed) }
    }

    // Create AVAudioPCMBuffer wrapping the rendered data
    guard let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: ctx.inputFormat, frameCapacity: inNumberFrames
    ) else { return noErr }
    pcmBuffer.frameLength = inNumberFrames
    if let dstChannels = pcmBuffer.floatChannelData {
        for ch in 0..<bufferCount {
            if let src = bufs[ch].mData {
                memcpy(dstChannels[ch], src, dataSize)
            }
        }
    }

    // Write to file, converting format if needed
    if let converter = ctx.converter {
        let ratio = ctx.outputFormat.sampleRate / ctx.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inNumberFrames) * ratio)
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(
                  pcmFormat: ctx.outputFormat, frameCapacity: max(capacity, 1)
              )
        else { return noErr }
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        if error == nil, converted.frameLength > 0 {
            try? ctx.audioFile.write(from: converted)
        }
    } else {
        try? ctx.audioFile.write(from: pcmBuffer)
    }

    return noErr
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
    private var warmupEngine: AVAudioEngine?
    private var directCaptureAU: AudioUnit?
    private var directCaptureContextRef: Unmanaged<DirectCaptureContext>?

    private static let sampleRate: Double = 44_100
    private static let channels: AVAudioChannelCount = 1
    private static let bitDepth: UInt32 = 16

    var isRecording: Bool {
        stateQueue.sync {
            if simulatedRecordingSourceURL != nil {
                return true
            }
            if directCaptureAU != nil {
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
            let oldUID = selectedDeviceUID
            selectedDeviceUID = (uid?.isEmpty == true) ? nil : uid
            // Discard standby engine — it was warmed with the old device
            standbyEngine = nil
            stopWarmupEngineLocked()
            // Only pre-activate when the selected input is itself Bluetooth.
            // Built-in / wired microphones should not disturb Bluetooth playback.
            if let newUID = selectedDeviceUID,
               newUID != oldUID,
               deviceManager.isBluetoothInputDevice(uid: newUID) {
                preActivateMicLocked()
            }
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

        // Skip standby warmup when a non-default device is selected —
        // the standby engine's format cache would be stale after device switch.
        guard selectedDeviceUID == nil else { return }

        let eng = AVAudioEngine()
        do {
            try withObjCExceptionHandling {
                _ = self.applyDeviceSelectionLocked(to: eng)
            }
        } catch {
            audioLogger.warning("ObjC exception during standby warmup (non-fatal): \(error, privacy: .public)")
            return
        }
        standbyEngine = eng
    }

    /// Briefly starts an engine with the selected device to force Bluetooth
    /// devices to switch from A2DP (playback) to HFP (microphone) codec.
    /// The switch takes ~1-2s; doing it at device-selection time means the
    /// mic is ready by the time the user starts recording.
    private func preActivateMicLocked() {
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        guard !deviceManager.availableInputDevices().isEmpty else { return }

        let eng = AVAudioEngine()
        var fmt: AVAudioFormat?
        do {
            try withObjCExceptionHandling {
                fmt = self.applyDeviceSelectionLocked(to: eng)
            }
        } catch {
            audioLogger.warning("Mic pre-activation device setup failed: \(error, privacy: .public)")
            return
        }

        do {
            var inputNode: AVAudioInputNode?
            try withObjCExceptionHandling {
                inputNode = eng.inputNode
            }
            guard let node = inputNode else { return }

            let tapFormat = fmt ?? node.outputFormat(forBus: 0)
            guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else { return }

            // Install a no-op tap so the engine actually starts I/O on the device
            node.removeTap(onBus: 0)
            try withObjCExceptionHandling {
                node.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { _, _ in }
            }
            try eng.start()
        } catch {
            audioLogger.warning("Mic pre-activation failed (non-fatal): \(error, privacy: .public)")
            return
        }

        warmupEngine = eng
        audioLogger.info("Pre-activating microphone for Bluetooth codec switch")

        // Auto-stop after 3 seconds — the codec switch completes within ~2s
        // and macOS keeps HFP mode briefly after mic use stops.
        stateQueue.asyncAfter(deadline: .now() + 3.0) { [self] in
            stopWarmupEngineLocked()
        }
    }

    private func stopWarmupEngineLocked() {
        guard let eng = warmupEngine else { return }
        do {
            try withObjCExceptionHandling {
                eng.inputNode.removeTap(onBus: 0)
            }
        } catch {
            audioLogger.warning("ObjC exception stopping warmup engine tap: \(error, privacy: .public)")
        }
        eng.stop()
        warmupEngine = nil
    }

    /// Applies the user's selected input device to the engine.
    /// Returns the AudioUnit's actual stream format on success, or `nil` if
    /// no device was applied (default device or failure).
    private func applyDeviceSelectionLocked(to eng: AVAudioEngine) -> AVAudioFormat? {
        guard let uid = selectedDeviceUID else { return nil }
        let devices = deviceManager.availableInputDevices()
        guard let device = devices.first(where: { $0.uid == uid }) else {
            audioLogger.warning("Selected device UID '\(uid, privacy: .public)' not found in available devices, using default")
            return nil
        }

        let inputNode = eng.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            audioLogger.error("inputNode.audioUnit is nil — cannot set device '\(device.name, privacy: .public)'")
            return nil
        }

        // Uninitialize the audio unit before changing the device —
        // CoreAudio rejects device changes on an already-initialized unit.
        AudioUnitUninitialize(audioUnit)

        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            audioLogger.error("AudioUnitSetProperty failed (status \(status)) for device '\(device.name, privacy: .public)'")
            AudioUnitInitialize(audioUnit)
            return nil
        }

        AudioUnitInitialize(audioUnit)

        audioLogger.info("Input device set to '\(device.name, privacy: .public)' (uid: \(uid, privacy: .public))")

        // Query the AudioUnit's stream format (may have a stale sample rate
        // from the previous device — the engine caches it on first inputNode access).
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1, // element 1 = input side
            &asbd,
            &asbdSize
        )

        // Query the device's authoritative nominal sample rate directly from
        // CoreAudio — this is never stale, unlike the AudioUnit's cached format.
        var nominalRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rateStatus = AudioObjectGetPropertyData(
            device.id, &rateAddress, 0, nil, &rateSize, &nominalRate
        )

        guard fmtStatus == noErr, asbd.mSampleRate > 0 else { return nil }

        // If the AudioUnit reports a stale sample rate from the previous device,
        // force it to the device's actual rate. Without this, the engine's graph
        // initialization fails with "formats don't match" (-10868).
        if rateStatus == noErr, nominalRate > 0, asbd.mSampleRate != nominalRate {
            audioLogger.info("Correcting stale AudioUnit rate \(asbd.mSampleRate) → device nominal \(nominalRate)")
            asbd.mSampleRate = nominalRate
            AudioUnitUninitialize(audioUnit)
            let setFmtStatus = AudioUnitSetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &asbd,
                asbdSize
            )
            if setFmtStatus != noErr {
                audioLogger.warning("AudioUnitSetProperty(StreamFormat) failed: \(setFmtStatus)")
            }
            let reinitStatus = AudioUnitInitialize(audioUnit)
            if reinitStatus != noErr {
                audioLogger.warning("AudioUnitInitialize after format correction failed: \(reinitStatus)")
            }
        }

        let fmt = AVAudioFormat(streamDescription: &asbd)
        audioLogger.info("AudioUnit actual format: \(fmt?.description ?? "nil", privacy: .public)")
        return fmt
    }

    /// Starts recording using a raw AUHAL, bypassing AVAudioEngine entirely.
    /// The device is set BEFORE AudioUnitInitialize, so the Bluetooth device
    /// is never touched — preventing the A2DP-to-HFP codec switch.
    private func startDirectCaptureLocked(
        device: AudioInputDevice, audioURL: URL,
        levelHandler: @escaping @Sendable (Double) -> Void
    ) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioClientError.failedToStart(reason: "no HAL output audio component")
        }
        var rawAU: AudioUnit?
        guard AudioComponentInstanceNew(comp, &rawAU) == noErr, let au = rawAU else {
            throw AudioClientError.failedToStart(reason: "failed to create audio unit")
        }

        var success = false
        defer {
            if !success {
                AudioUnitUninitialize(au)
                AudioComponentInstanceDispose(au)
            }
        }

        // Enable input on element 1, disable output on element 0
        var enableIO: UInt32 = 1
        guard AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enableIO, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else {
            throw AudioClientError.failedToStart(reason: "failed to enable audio input")
        }
        var disableIO: UInt32 = 0
        AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disableIO, UInt32(MemoryLayout<UInt32>.size)
        )

        // Set device BEFORE initialization — the AUHAL never touches Bluetooth
        var deviceID = device.id
        guard AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else {
            throw AudioClientError.failedToStart(reason: "failed to set input device")
        }

        guard AudioUnitInitialize(au) == noErr else {
            throw AudioClientError.failedToStart(reason: "failed to initialize audio unit")
        }

        // Query format from the initialized AUHAL
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(
            au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, &asbdSize
        ) == noErr, asbd.mSampleRate > 0,
              let inputFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioClientError.failedToStart(reason: "invalid audio format from device")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
            channels: Self.channels, interleaved: true
        ) else {
            throw AudioClientError.failedToStart(reason: "could not create output format")
        }

        guard let file = try? AVAudioFile(
            forWriting: audioURL, settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16, interleaved: true
        ) else {
            throw AudioClientError.failedToStart(reason: "could not create audio file")
        }

        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard converter != nil || inputFormat == outputFormat else {
            throw AudioClientError.failedToStart(reason: "incompatible audio format")
        }

        let context = DirectCaptureContext(
            audioUnit: au, audioFile: file, converter: converter,
            inputFormat: inputFormat, outputFormat: outputFormat,
            smoother: levelSmoother, levelHandler: levelHandler
        )
        let ref = Unmanaged.passRetained(context)

        var callbackStruct = AURenderCallbackStruct(
            inputProc: directCaptureInputProc,
            inputProcRefCon: ref.toOpaque()
        )
        guard AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr else {
            ref.release()
            throw AudioClientError.failedToStart(reason: "failed to set input callback")
        }

        guard AudioOutputUnitStart(au) == noErr else {
            ref.release()
            throw AudioClientError.failedToStart(reason: "failed to start audio capture")
        }

        success = true
        directCaptureAU = au
        directCaptureContextRef = ref
        audioFile = file
        recordingURL = audioURL

        audioLogger.info("Direct capture started for '\(device.name, privacy: .public)' (bypassing Bluetooth activation)")
    }

    private func startRecordingLocked(levelHandler: @escaping @Sendable (Double) -> Void) throws {
        guard engine == nil, directCaptureAU == nil, simulatedRecordingSourceURL == nil else { return }
        self.levelHandler = levelHandler

        // Stop any mic pre-activation warmup to free the audio device
        stopWarmupEngineLocked()

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

        // If the system default input is Bluetooth but we want a non-Bluetooth
        // device, use direct AUHAL capture to avoid triggering the BT codec switch.
        // AVAudioEngine wraps the default in a CADefaultDeviceAggregate that
        // briefly activates the Bluetooth mic on inputNode access.
        if let uid = selectedDeviceUID {
            let devices = deviceManager.availableInputDevices()
            if let device = devices.first(where: { $0.uid == uid }) {
                let systemDefault = deviceManager.systemDefaultInputDeviceID()
                if systemDefault != 0
                    && systemDefault != device.id
                    && deviceManager.isBluetoothDevice(systemDefault)
                    && !deviceManager.isBluetoothDevice(device.id)
                {
                    try startDirectCaptureLocked(
                        device: device, audioURL: audioURL, levelHandler: levelHandler
                    )
                    return
                }
            }
        }

        // Use pre-warmed standby engine when using the default device,
        // otherwise create fresh to avoid stale format caches.
        let eng: AVAudioEngine
        if selectedDeviceUID == nil, let standby = standbyEngine {
            standbyEngine = nil
            eng = standby
        } else {
            standbyEngine = nil
            eng = AVAudioEngine()
        }

        // Apply device selection and get the AudioUnit's actual format
        // (bypasses AVAudioEngine's stale format cache after device switch).
        var deviceFormat: AVAudioFormat?
        do {
            try withObjCExceptionHandling {
                deviceFormat = self.applyDeviceSelectionLocked(to: eng)
            }
            // If user selected a specific device but it failed, don't silently
            // record from the wrong device — tell them.
            if selectedDeviceUID != nil, deviceFormat == nil {
                throw AudioClientError.failedToStart(reason: "could not switch to the selected microphone — try choosing a different one")
            }
        } catch let error as AudioClientError {
            throw error
        } catch {
            audioLogger.warning("ObjC exception applying device selection, falling back to default: \(error, privacy: .public)")
        }

        let inputNode: AVAudioInputNode
        do {
            var node: AVAudioInputNode?
            try withObjCExceptionHandling {
                node = eng.inputNode
            }
            guard let unwrapped = node else {
                throw AudioClientError.failedToStart(reason: "audio engine has no input node")
            }
            inputNode = unwrapped
        } catch let error as AudioClientError {
            throw error
        } catch {
            audioLogger.error("ObjC exception accessing inputNode: \(error, privacy: .public)")
            throw AudioClientError.failedToStart(reason: "audio input unavailable — \(error)")
        }
        // Prefer the format queried directly from the AudioUnit after device
        // switch — inputNode.outputFormat may return a stale cached value.
        let inputFormat = deviceFormat ?? inputNode.outputFormat(forBus: 0)
        audioLogger.info("Queried input format (pre-tap, may be stale): \(inputFormat.description, privacy: .public)")

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

        // Defensively remove any existing tap before installing a new one
        inputNode.removeTap(onBus: 0)

        do {
            try withObjCExceptionHandling {
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
                // AVAudioConverter's inputBlock is called synchronously during convert(to:error:inputBlock:),
                // so mutation of this local variable is single-threaded. nonisolated(unsafe) suppresses
                // the Swift 6 concurrency warning without introducing an actual data race.
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
                    do {
                        try file.write(from: convertedBuffer)
                    } catch {
                        audioLogger.error("Failed to write converted audio buffer: \(error, privacy: .public)")
                    }
                }
            } else {
                do {
                    try file.write(from: buffer)
                } catch {
                    audioLogger.error("Failed to write audio buffer: \(error, privacy: .public)")
                }
            }
        }
            }
        } catch {
            audioLogger.error("ObjC exception installing audio tap: \(error, privacy: .public)")
            throw AudioClientError.failedToStart(reason: "audio tap failed — \(error)")
        }

        // Retry engine start up to 3 times — Bluetooth devices (e.g. AirPods)
        // may need a moment before the audio I/O subsystem is ready.
        var lastStartError: Error?
        for attempt in 1...3 {
            do {
                try eng.start()
                if attempt > 1 {
                    audioLogger.info("Engine started on attempt \(attempt)")
                }
                lastStartError = nil
                break
            } catch {
                lastStartError = error
                audioLogger.warning("Engine start attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        if let lastStartError {
            inputNode.removeTap(onBus: 0)
            audioLogger.error("AVAudioEngine failed to start after retries: \(lastStartError.localizedDescription, privacy: .public)")
            throw AudioClientError.failedToStart(reason: "audio engine failed to start — \(lastStartError.localizedDescription)")
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

        // Tear down whichever capture path is active
        if let au = directCaptureAU {
            AudioOutputUnitStop(au)
            directCaptureContextRef?.release()
            directCaptureContextRef = nil
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            directCaptureAU = nil
        } else if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        } else {
            throw AudioClientError.notRecording
        }

        guard let url = recordingURL else {
            throw AudioClientError.notRecording
        }

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

        if let au = directCaptureAU {
            AudioOutputUnitStop(au)
            directCaptureContextRef?.release()
            directCaptureContextRef = nil
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            directCaptureAU = nil
        } else if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        } else {
            return
        }

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
