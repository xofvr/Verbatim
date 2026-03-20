import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import AudioSpeedClient
import AudioTrimClient
import LogClient
import MLXClient
import Shared
#if canImport(Speech)
import Speech
#endif

@DependencyClient
public struct TranscriptionClient: Sendable {
    public var prepareModelIfNeeded: @Sendable (ModelOption) async throws -> Void
    public var transcribe: @Sendable (URL, ModelOption, TranscriptionMode, String?, ProviderPolicy, String?, VocabularyProfile) async throws -> TranscriptionResult
    public var unloadModel: @Sendable () async -> Void = {}
    public var audioDurationSeconds: @Sendable (URL) -> Double = { _ in 0 }
}

public struct TranscriptionResult: Equatable, Sendable {
    public var text: String
    public var providerID: String
    public var modelID: String
    public var usedFallback: Bool

    public init(text: String, providerID: String, modelID: String, usedFallback: Bool = false) {
        self.text = text
        self.providerID = providerID
        self.modelID = modelID
        self.usedFallback = usedFallback
    }
}

extension TranscriptionClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            prepareModelIfNeeded: { option in
                guard option.requiresDownload else { return }
                @Dependency(\.mlxClient) var mlxClient
                guard let pipelineModel = option.pipelineModel else { return }
                try await mlxClient.prepareModelIfNeeded(pipelineModel)
            },
            transcribe: { audioURL, option, mode, prompt, providerPolicy, language, vocabulary in
                @Dependency(\.mlxClient) var mlxClient
                @Dependency(\.audioTrimClient) var trimClient
                @Dependency(\.audioSpeedClient) var speedClient
                @Dependency(\.logClient) var logClient
                @Dependency(\.groqTranscriptionClient) var groqTranscriptionClient
                if option.requiresDownload, let pipelineModel = option.pipelineModel {
                    try await mlxClient.prepareModelIfNeeded(pipelineModel)
                }

                @Shared(.trimSilenceEnabled) var trimEnabled
                @Shared(.autoSpeedEnabled) var speedEnabled

                let requestID = UUID().uuidString
                let requestStartUptime = ProcessInfo.processInfo.systemUptime
                var workingAudioURL = audioURL
                var generatedAudioURLs = Set<URL>()
                var stage = "setup"
                let inputDuration = audioFileDurationSeconds(audioURL)
                let inputSizeBytes = audioFileSizeBytes(audioURL) ?? 0

                logClient.dumpDebug(
                    "TranscriptionClient",
                    "Transcription request",
                    appDumpString(
                        [
                            "requestID": requestID,
                            "model": option.rawValue,
                            "mode": mode.rawValue,
                            "inputFile": audioURL.lastPathComponent,
                            "inputDuration": formatElapsedSeconds(inputDuration),
                            "inputSizeBytes": "\(inputSizeBytes)",
                            "trimEnabled": "\(trimEnabled)",
                            "autoSpeedEnabled": "\(speedEnabled)"
                        ]
                    )
                )

                if trimEnabled {
                    stage = "trim"
                    let trimStartUptime = ProcessInfo.processInfo.systemUptime
                    let beforeTrimDuration = audioFileDurationSeconds(workingAudioURL)
                    let trimmedURL = try await trimClient.trimSilence(workingAudioURL, Self.trimSilenceThreshold)
                    if trimmedURL != workingAudioURL {
                        generatedAudioURLs.insert(trimmedURL)
                        workingAudioURL = trimmedURL
                    }
                    let trimElapsed = ProcessInfo.processInfo.systemUptime - trimStartUptime
                    let afterTrimDuration = audioFileDurationSeconds(workingAudioURL)
                    logClient.dumpDebug(
                        "TranscriptionClient",
                        "Trim stage",
                        appDumpString(
                            [
                                "requestID": requestID,
                                "changedFile": "\(workingAudioURL != audioURL)",
                                "beforeDuration": formatElapsedSeconds(beforeTrimDuration),
                                "afterDuration": formatElapsedSeconds(afterTrimDuration),
                                "elapsed": formatElapsedSeconds(trimElapsed),
                                "workingFile": workingAudioURL.lastPathComponent
                            ]
                        )
                    )
                } else {
                    logClient.debug(
                        "TranscriptionClient",
                        "Trim stage skipped. requestID=\(requestID), trimEnabled=false"
                    )
                }

                let duration = await audioFileDurationSecondsAsync(workingAudioURL)
                if speedEnabled, let speedRate = Self.autoSpeedRate(for: duration) {
                    stage = "speed"
                    let speedStartUptime = ProcessInfo.processInfo.systemUptime
                    let beforeSpeedDuration = duration
                    let spedUpURL = try await speedClient.speedUp(workingAudioURL, speedRate)
                    if spedUpURL != workingAudioURL {
                        generatedAudioURLs.insert(spedUpURL)
                        workingAudioURL = spedUpURL
                    }
                    let speedElapsed = ProcessInfo.processInfo.systemUptime - speedStartUptime
                    let afterSpeedDuration = audioFileDurationSeconds(workingAudioURL)
                    logClient.dumpDebug(
                        "TranscriptionClient",
                        "Speed stage",
                        appDumpString(
                            [
                                "requestID": requestID,
                                "rate": speedRate.formatted(.number.precision(.fractionLength(2))),
                                "changedFile": "\(workingAudioURL != audioURL)",
                                "beforeDuration": formatElapsedSeconds(beforeSpeedDuration),
                                "afterDuration": formatElapsedSeconds(afterSpeedDuration),
                                "elapsed": formatElapsedSeconds(speedElapsed),
                                "workingFile": workingAudioURL.lastPathComponent
                            ]
                        )
                    )
                } else {
                    let resolvedRate = speedEnabled ? (Self.autoSpeedRate(for: duration) ?? 0) : 0
                    logClient.debug(
                        "TranscriptionClient",
                        "Speed stage skipped. requestID=\(requestID), autoSpeedEnabled=\(speedEnabled), rate=\(resolvedRate)"
                    )
                }

                defer {
                    for generatedURL in generatedAudioURLs {
                        try? FileManager.default.removeItem(at: generatedURL)
                    }
                }

                do {
                    stage = "backend"
                    let backendStartUptime = ProcessInfo.processInfo.systemUptime
                    let transcriptResult = try await resolveTranscriptionResult(
                        groqTranscriptionClient: groqTranscriptionClient,
                        mlxClient: mlxClient,
                        logClient: logClient,
                        audioURL: workingAudioURL,
                        option: option,
                        mode: mode,
                        prompt: prompt,
                        providerPolicy: providerPolicy,
                        language: language,
                        vocabulary: vocabulary
                    )
                    let transcript = transcriptResult.text

                    let backendElapsed = ProcessInfo.processInfo.systemUptime - backendStartUptime
                    let totalElapsed = ProcessInfo.processInfo.systemUptime - requestStartUptime
                    let workingDuration = audioFileDurationSeconds(workingAudioURL)
                    let outputCharacters = transcript.count

                    logClient.dumpDebug(
                        "TranscriptionClient",
                        "Transcription completed",
                        appDumpString(
                            [
                                "requestID": requestID,
                                "provider": transcriptResult.providerID,
                                "model": transcriptResult.modelID,
                                "usedFallback": "\(transcriptResult.usedFallback)",
                                "workingFile": workingAudioURL.lastPathComponent,
                                "workingDuration": formatElapsedSeconds(workingDuration),
                                "backendElapsed": formatElapsedSeconds(backendElapsed),
                                "totalElapsed": formatElapsedSeconds(totalElapsed),
                                "outputCharacters": "\(outputCharacters)"
                            ]
                        )
                    )

                    return transcriptResult
                } catch {
                    let failedElapsed = ProcessInfo.processInfo.systemUptime - requestStartUptime
                    logClient.error(
                        "TranscriptionClient",
                        "Transcription failed. requestID=\(requestID), stage=\(stage), elapsed=\(formatElapsedSeconds(failedElapsed)), model=\(option.rawValue), error=\(error.localizedDescription)"
                    )
                    throw error
                }
            },
            unloadModel: {
                @Dependency(\.mlxClient) var mlxClient
                await mlxClient.unloadModel()
            },
            audioDurationSeconds: { url in
                audioFileDurationSeconds(url)
            }
        )
    }
}

extension TranscriptionClient: TestDependencyKey {
    public static var testValue: Self {
        Self(
            prepareModelIfNeeded: { _ in },
            transcribe: { _, option, _, _, _, _, _ in
                TranscriptionResult(
                    text: "Test transcription",
                    providerID: option.providerDisplayName,
                    modelID: option.rawValue
                )
            },
            unloadModel: {},
            audioDurationSeconds: { _ in 1.0 }
        )
    }
}

public extension DependencyValues {
    var transcriptionClient: TranscriptionClient {
        get { self[TranscriptionClient.self] }
        set { self[TranscriptionClient.self] = newValue }
    }
}

private func audioFileDurationSeconds(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    let sampleRate = file.fileFormat.sampleRate
    guard sampleRate > 0 else { return 0 }
    return Double(file.length) / sampleRate
}

private func audioFileDurationSecondsAsync(_ url: URL) async -> Double {
    await Task.detached(priority: .utility) {
        audioFileDurationSeconds(url)
    }.value
}

private extension TranscriptionClient {
    static let defaultSmartPrompt = "Clean up filler words and repeated phrases. Return a polished version of what was said."
    static let trimSilenceThreshold: Float = 0.003

    static func autoSpeedRate(for audioDuration: Double) -> Double? {
        switch audioDuration {
        case ..<45:
            return nil
        case 45..<90:
            return 1.1
        case 90..<180:
            return 1.2
        default:
            return 1.25
        }
    }
}

private func formatElapsedSeconds(_ seconds: Double) -> String {
    String(format: "%.3fs", seconds)
}

private func audioFileSizeBytes(_ url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values?.fileSize else { return nil }
    return Int64(size)
}

private extension ModelOption {
    var pipelineModel: MLXPipelineModel? {
        switch self {
        case .groqWhisperLargeV3Turbo, .appleSpeech:
            return nil
        case .qwen3ASR06B4bit:
            return .qwen3ASR06B4bit
        case .parakeetTDT06BV3:
            return .parakeetTDT06BV3
        case .whisperLargeV3Turbo:
            return .whisperLargeV3Turbo
        case .whisperTiny:
            return .whisperTiny
        case .mini3b:
            return .mini3b
        case .mini3b8bit:
            return .mini3b8bit
        }
    }
}

private func resolveTranscriptionResult(
    groqTranscriptionClient: GroqTranscriptionClient,
    mlxClient: MLXClient,
    logClient: LogClient,
    audioURL: URL,
    option: ModelOption,
    mode: TranscriptionMode,
    prompt: String?,
    providerPolicy: ProviderPolicy,
    language: String?,
    vocabulary: VocabularyProfile
) async throws -> TranscriptionResult {
    logClient.debug("TranscriptionClient", "Provider routing: policy=\(providerPolicy.rawValue)")

    switch providerPolicy {
    case .localOnly:
        logClient.debug("TranscriptionClient", "Using local transcription: model=\(option.rawValue)")
        let transcript = try await localTranscription(
            mlxClient: mlxClient,
            audioURL: audioURL,
            option: option,
            mode: mode,
            prompt: prompt
        )
        return TranscriptionResult(
            text: transcript,
            providerID: option.providerDisplayName,
            modelID: option.rawValue
        )

    case .groqOnly:
        logClient.debug("TranscriptionClient", "Using Groq (no fallback)")
        let transcript = try await groqTranscriptionClient.transcribe(
            audioURL,
            language,
            .text,
            vocabulary.promptHints
        )
        return TranscriptionResult(
            text: transcript.text,
            providerID: ModelProvider.groq.rawValue,
            modelID: transcript.model
        )

    case .groqPrimaryLocalFallback:
        do {
            logClient.debug("TranscriptionClient", "Attempting Groq transcription (with local fallback)")
            let transcript = try await groqTranscriptionClient.transcribe(
                audioURL,
                language,
                .text,
                vocabulary.promptHints
            )
            logClient.debug("TranscriptionClient", "Groq transcription succeeded")
            return TranscriptionResult(
                text: transcript.text,
                providerID: ModelProvider.groq.rawValue,
                modelID: transcript.model
            )
        } catch {
            logClient.error("TranscriptionClient", "Groq failed, falling back to local: \(error.localizedDescription)")
            let localTranscript = try await localTranscription(
                mlxClient: mlxClient,
                audioURL: audioURL,
                option: option,
                mode: mode,
                prompt: prompt
            )
            return TranscriptionResult(
                text: localTranscript,
                providerID: option.providerDisplayName,
                modelID: option.rawValue,
                usedFallback: true
            )
        }
    }
}

private func localTranscription(
    mlxClient: MLXClient,
    audioURL: URL,
    option: ModelOption,
    mode: TranscriptionMode,
    prompt: String?
) async throws -> String {
    if option == .appleSpeech {
        return try await TranscriptionClient.transcribeWithAppleSpeech(audioURL)
    }

    if option == .groqWhisperLargeV3Turbo {
        throw GroqTranscriptionError.missingAPIKey
    }

    return try await mlxClient.transcribe(
        audioURL,
        mode == .verbatim
            ? .verbatim
            : .smart(prompt: prompt ?? "Clean up filler words and repeated phrases. Return a polished version of what was said.")
    )
}

private extension TranscriptionClient {
    static func transcribeWithAppleSpeech(_ audioURL: URL) async throws -> String {
        #if canImport(Speech)
        if #available(macOS 26, *) {
            return try await AppleSpeechRuntime.transcribe(audioURL: audioURL)
        }
        #endif
        throw AppleSpeechError.unavailable
    }
}

#if canImport(Speech)
@available(macOS 26, *)
private enum AppleSpeechRuntime {
    static func transcribe(audioURL: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechError.unavailable
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales

        let supportedIDs = Set(supportedLocales.map(normalizedLocaleIdentifier))
        let installedSupportedLocales = installedLocales.filter { locale in
            supportedIDs.contains(normalizedLocaleIdentifier(locale))
        }

        guard !installedSupportedLocales.isEmpty else {
            throw AppleSpeechError.noInstalledLocale
        }

        let locale = preferredLocale(from: installedSupportedLocales)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript = AttributedString()
        for try await result in transcriber.results {
            transcript += result.text
        }

        let text = String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppleSpeechError.emptyTranscript
        }
        return text
    }

    private static func preferredLocale(from locales: [Locale]) -> Locale {
        let current = normalizedLocaleIdentifier(Locale.current)
        if let exactMatch = locales.first(where: { normalizedLocaleIdentifier($0) == current }) {
            return exactMatch
        }

        if let currentLanguage = Locale.current.language.languageCode?.identifier.lowercased(),
           let languageMatch = locales.first(where: {
               $0.language.languageCode?.identifier.lowercased() == currentLanguage
           })
        {
            return languageMatch
        }

        return locales[0]
    }

    private static func normalizedLocaleIdentifier(_ locale: Locale) -> String {
        locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }
}
#endif

private enum AppleSpeechError: LocalizedError {
    case unavailable
    case noInstalledLocale
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Speech is not available on this Mac."
        case .noInstalledLocale:
            return "No installed Apple Speech locale is available. Add a dictation language in System Settings."
        case .emptyTranscript:
            return "No speech detected."
        }
    }
}
