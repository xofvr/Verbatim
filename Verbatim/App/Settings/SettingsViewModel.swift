import AppKit
import UniformTypeIdentifiers
import Dependencies
import FoundationModelClient
import HistoryClient
import KeyboardShortcuts
import LogClient
import ModelDownloadFeature
import Observation
import PermissionsClient
import Shared
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    @ObservationIgnored @Shared(.trimSilenceEnabled) var trimSilenceEnabled = false
    @ObservationIgnored @Shared(.autoSpeedEnabled) var autoSpeedEnabled = false
    @ObservationIgnored @Shared(.transcriptionMode) var transcriptionMode: TranscriptionMode = .verbatim
    @ObservationIgnored @Shared(.smartPrompt) var smartPrompt = "Clean up filler words and repeated phrases. Return a polished version of what was said."
    @ObservationIgnored @Shared(.historyRetentionMode) var historyRetentionMode: HistoryRetentionMode = .both
    @ObservationIgnored @Shared(.compressHistoryAudio) var compressHistoryAudio = false
    @ObservationIgnored @Shared(.appleIntelligenceEnabled) var appleIntelligenceEnabled = false
    @ObservationIgnored @Shared(.logsEnabled) var logsEnabled = false
    @ObservationIgnored @Shared(.restoreClipboardAfterPaste) var restoreClipboardAfterPaste = true
    @ObservationIgnored @Shared(.pushToTalkThreshold) var pushToTalkThreshold: PushToTalkThreshold = .long
    @ObservationIgnored @Shared(.shortcutTriggerMode) var shortcutTriggerMode: ShortcutTriggerMode = .doubleTap
    @ObservationIgnored @Shared(.doubleTapKey) var doubleTapKey: DoubleTapKey = .leftCommand
    @ObservationIgnored @Shared(.doubleTapInterval) var doubleTapInterval: Double = 0.4
    @ObservationIgnored @Shared(.providerPolicy) var providerPolicy: ProviderPolicy = .groqPrimaryLocalFallback
    @ObservationIgnored @Shared(.outputMode) var outputMode: OutputMode = .clipboard
    @ObservationIgnored @Shared(.preferredLanguage) var preferredLanguage = "en"
    @ObservationIgnored @Shared(.vocabularyProfileJSON) var vocabularyProfileJSON = ""
    @ObservationIgnored @Shared(.managedConfigURL) var managedConfigURL = ""
    @ObservationIgnored @Shared(.groqAPIKey) var storedGroqAPIKey = ""
    @ObservationIgnored @Shared(.groqAPIBaseURL) var groqAPIBaseURL = "https://api.groq.com/openai/v1/audio/transcriptions"
    @ObservationIgnored @Shared(.hideFromScreenShare) var hideFromScreenShare = true
    @ObservationIgnored @Shared(.transcriptHistoryDays) private var transcriptHistoryDays: [TranscriptHistoryDay] = []

    var microphoneAuthorized = false
    var accessibilityAuthorized = false
    var permissionMessage: String?
    var managedConfigStatus = "Disabled"

    var selectedModelID: String {
        get { downloadModel.selectedModelID }
        set {
            appModel.selectedModelID = newValue
        }
    }

    var isWarmingModel: Bool { appModel.isWarmingModel }
    var effectiveProviderPolicy: ProviderPolicy { appModel.effectiveProviderPolicy }
    var effectiveOutputMode: OutputMode { appModel.effectiveOutputMode }
    var groqAPIKeyDraft = ""
    var hasGroqAPIKeyStored: Bool {
        !storedGroqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var historyDirectoryPath: String {
        historyClient.historyDirectoryPath()
    }

    var availableModelOptions: [ModelOption] {
        ModelOption.allCases
    }

    var vocabularyPromptHints: String {
        get { vocabularyProfile.promptHints }
        set { updateVocabularyProfile { $0.promptHints = newValue } }
    }

    var vocabularyTermsText: String {
        get {
            vocabularyProfile.terms
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        }
        set {
            updateVocabularyProfile { profile in
                var parsed: [String: String] = [:]
                for line in newValue.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        parsed[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                profile.terms = parsed
            }
        }
    }

    var recentHistoryEntries: [TranscriptHistoryEntry] {
        transcriptHistoryDays.flatMap(\.entries)
            .filter { transcriptText(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(3)
            .map { $0 }
    }

    var canExportLogs: Bool {
        logClient.logFileURL() != nil
    }

    var doubleTapRecorderBinding: Binding<DoubleTapRecorder.DoubleTapKey> {
        Binding(
            get: { [weak self] in
                guard let self, self.doubleTapKey.isConfigured else { return .unconfigured }
                return .configured(
                    keyCode: self.doubleTapKey.keyCode,
                    isModifier: self.doubleTapKey.isModifier,
                    displayName: self.doubleTapKey.displayName
                )
            },
            set: { [weak self] newValue in
                guard let self else { return }
                switch newValue {
                case .unconfigured:
                    self.$doubleTapKey.withLock { $0 = .unconfigured }
                case let .configured(keyCode, isModifier, _):
                    self.$doubleTapKey.withLock { $0 = DoubleTapKey(keyCode: keyCode, isModifier: isModifier) }
                }
                self.appModel.registerShortcutHandlers()
            }
        )
    }

    var appleIntelligenceAvailable: Bool {
        foundationModelClient.isAvailable()
    }

    /// Whether smart mode should be available for the currently selected model.
    var smartModeAvailable: Bool {
        downloadModel.selectedModelOption?.supportsSmartTranscription == true
            || appleIntelligenceEnabled
    }

    let downloadModel: ModelDownloadModel
    private let appModel: AppModel
    @ObservationIgnored @Dependency(\.permissionsClient) private var permissionsClient
    @ObservationIgnored @Dependency(\.historyClient) private var historyClient
    @ObservationIgnored @Dependency(\.foundationModelClient) private var foundationModelClient
    @ObservationIgnored @Dependency(\.logClient) private var logClient

    init(appModel: AppModel) {
        self.downloadModel = appModel.modelDownloadViewModel
        self.appModel = appModel
        updateManagedConfigStatus()
    }

    private var vocabularyProfile: VocabularyProfile {
        (try? JSONDecoder().decode(VocabularyProfile.self, from: Data(vocabularyProfileJSON.utf8))) ?? .defaultProfile
    }

    private func updateVocabularyProfile(_ mutate: (inout VocabularyProfile) -> Void) {
        var profile = vocabularyProfile
        mutate(&profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(profile),
           let json = String(data: data, encoding: .utf8) {
            $vocabularyProfileJSON.withLock { $0 = json }
        }
    }

    func refreshPermissions() async {
        microphoneAuthorized = await permissionsClient.microphonePermissionState() == .authorized
        accessibilityAuthorized = await permissionsClient.hasAccessibilityPermission()
        updateManagedConfigStatus()
    }

    func grantMicrophonePermissionButtonTapped() async {
        let granted = await permissionsClient.requestMicrophonePermission()
        microphoneAuthorized = granted
        if !granted {
            permissionMessage = "Open System Settings to grant microphone access."
            await permissionsClient.openMicrophonePrivacySettings()
        }
    }

    func grantAccessibilityPermissionButtonTapped() async {
        await permissionsClient.promptForAccessibilityPermission()
        try? await Task.sleep(for: .milliseconds(500))
        accessibilityAuthorized = await permissionsClient.hasAccessibilityPermission()
        if !accessibilityAuthorized {
            permissionMessage = "Open System Settings to grant accessibility access."
        }
    }

    func downloadButtonTapped() async {
        await downloadModel.downloadButtonTapped()
    }

    func pauseButtonTapped() {
        downloadModel.pauseButtonTapped()
    }

    func resumeButtonTapped() async {
        await downloadModel.resumeButtonTapped()
    }

    func cancelButtonTapped() {
        downloadModel.cancelButtonTapped()
    }

    func deleteModelButtonTapped() async {
        await downloadModel.deleteModelButtonTapped()
    }

    func historyRetentionModeChanged(_ mode: HistoryRetentionMode) {
        $historyRetentionMode.withLock { $0 = mode }
        let applied = historyClient.applyRetention(mode, transcriptHistoryDays)
        $transcriptHistoryDays.withLock { $0 = applied }
    }

    func openHistoryInFinder() {
        _ = historyClient.openHistoryFolder(historyRetentionMode)
    }

    func copyHistoryEntry(_ entry: TranscriptHistoryEntry) {
        let transcript = transcriptText(for: entry)
        guard transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func transcriptText(for entry: TranscriptHistoryEntry) -> String {
        historyClient.transcriptText(entry.preferredTranscriptRelativePath) ?? ""
    }

    func deleteAllHistory() {
        let cleared = historyClient.applyRetention(.none, transcriptHistoryDays)
        $transcriptHistoryDays.withLock { $0 = cleared }
    }

    func deleteMediaOnly() {
        let updated = historyClient.deleteMediaOnly(transcriptHistoryDays)
        $transcriptHistoryDays.withLock { $0 = updated }
    }

    func triggerModeChanged(_ mode: ShortcutTriggerMode) {
        $shortcutTriggerMode.withLock { $0 = mode }
        appModel.registerShortcutHandlers()
    }

    func exportLogs() {
        guard let logURL = logClient.logFileURL() else { return }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = logURL.lastPathComponent
        savePanel.allowedContentTypes = [.plainText]
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }
        try? FileManager.default.copyItem(at: logURL, to: destination)
    }

    func refreshManagedConfig() {
        Task {
            await appModel.refreshManagedConfig()
            updateManagedConfigStatus()
        }
    }

    func saveGroqAPIKeyDraft() {
        let trimmed = groqAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        $storedGroqAPIKey.withLock { $0 = trimmed }
        groqAPIKeyDraft = ""
    }

    func clearGroqAPIKey() {
        $storedGroqAPIKey.withLock { $0 = "" }
        groqAPIKeyDraft = ""
    }

    func applyPrivacySettings() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    private func updateManagedConfigStatus() {
        if let fetchedAt = appModel.managedConfig?.metadata.fetchedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            managedConfigStatus = "Loaded \(formatter.string(from: fetchedAt))"
        } else {
            managedConfigStatus = managedConfigURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Disabled"
                : "Using cached or remote config"
        }
    }
}
