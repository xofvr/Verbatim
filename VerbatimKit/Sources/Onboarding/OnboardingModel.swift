import Dependencies
import Foundation
import FoundationModelClient
import KeyboardShortcuts
import ModelDownloadFeature
import Observation
import PermissionsClient
import Sauce
import Shared
import AudioClient

@MainActor
@Observable
public final class OnboardingModel {
    public enum Page: Int, CaseIterable, Sendable {
        case welcome
        case consent
        case model
        case shortcut
        case microphone
        case accessibility
        case appleIntelligence
        case historyRetention
        case download
    }

    // MARK: - Navigation

    public var currentPage: Page

    public var pageOrder: [Page] {
        var pages: [Page] = [
            .welcome,
            .consent,
            .shortcut,
            .microphone,
            .accessibility,
            .historyRetention,
            .model,
        ]
        if shouldShowAppleIntelligencePage {
            pages.append(.appleIntelligence)
        }
        if selectedModelOption?.requiresDownload ?? true {
            pages.append(.download)
        }
        return pages
    }

    public var nextPage: Page? {
        guard let currentIndex = pageOrder.firstIndex(of: currentPage),
              pageOrder.indices.contains(currentIndex + 1)
        else { return nil }
        return pageOrder[currentIndex + 1]
    }

    public var previousPage: Page? {
        guard let currentIndex = pageOrder.firstIndex(of: currentPage),
              pageOrder.indices.contains(currentIndex - 1)
        else { return nil }
        return pageOrder[currentIndex - 1]
    }

    public func moveForward() {
        guard let nextPage else { return }
        currentPage = nextPage
        lastPageTransitionDate = Date()
        lastError = nil
        transientMessage = nil
    }

    public func moveBack() {
        guard let previousPage else { return }
        currentPage = previousPage
        lastPageTransitionDate = Date()
        lastError = nil
        transientMessage = nil
    }

    // MARK: - Page Container

    public var showBack: Bool {
        guard previousPage != nil else { return false }
        if currentPage == .download {
            let downloadState = modelDownloadViewModel.state
            if downloadState.isActive || downloadState.isPaused { return false }
        }
        return true
    }

    public var currentPrimaryTitle: String {
        switch currentPage {
        case .model:
            if shouldCompleteAfterModelSelection {
                return "Finish Setup"
            }
            return currentPage.primaryTitle
        case .accessibility:
            return accessibilityAuthorized ? "Continue" : "Enable Accessibility"
        case .microphone:
            return microphoneAuthorized ? "Continue" : "Enable Microphone"
        case .appleIntelligence:
            return nextPage == nil ? "Finish Setup" : "Continue"
        case .download:
            if modelDownloadViewModel.state.isActive { return "Downloading..." }
            if modelDownloadViewModel.state.isDownloaded { return "Finish Setup" }
            return currentPage.primaryTitle
        default:
            return currentPage.primaryTitle
        }
    }

    public var primaryDisabled: Bool {
        switch currentPage {
        case .welcome, .historyRetention, .appleIntelligence:
            return false
        case .consent:
            return !hasAcknowledgedRecordingConsent
        case .model:
            guard selectedModelOption != nil else { return true }
            return requiresGroqAPIKey && !hasUsableGroqAPIKey
        case .shortcut:
            return false
        case .microphone:
            return false
        case .accessibility:
            return false
        case .download:
            return modelDownloadViewModel.state.isActive
        }
    }

    public func primaryActionTapped() {
        if let last = lastPageTransitionDate, Date().timeIntervalSince(last) < 0.35 {
            return
        }

        switch currentPage {
        case .consent:
            if let _ = nextPage {
                moveForward()
            } else {
                completeSetup()
            }
        case .model:
            guard selectedModelOption != nil else { return }
            persistGroqAPIKeyIfNeeded()
            if nextPage != nil {
                moveForward()
            } else {
                completeSetup()
            }
        case .shortcut:
            moveForward()
        case .download:
            if modelDownloadViewModel.state.isDownloaded {
                completeSetup()
            } else {
                Task { await downloadModel() }
            }
        case .microphone:
            if microphoneAuthorized {
                moveForward()
            } else {
                Task { await microphonePermissionButtonTapped() }
            }
        case .accessibility:
            if accessibilityAuthorized {
                moveForward()
            } else {
                accessibilityPermissionButtonTapped()
            }
        case .appleIntelligence:
            if let _ = nextPage {
                moveForward()
            } else {
                completeSetup()
            }
        default:
            moveForward()
        }
    }

    // MARK: - Model Download

    public let modelDownloadViewModel: ModelDownloadModel

    public var selectedModelID: String {
        get { modelDownloadViewModel.selectedModelID }
        set { modelDownloadViewModel.$selectedModelID.withLock { $0 = newValue } }
    }

    public var groqAPIKeyDraft = ""

    public var microphonePermissionState: MicrophonePermissionState = .notDetermined
    public var microphoneAuthorized = false
    public var accessibilityAuthorized = false
    @ObservationIgnored @Shared(.hasAcknowledgedRecordingConsent) public var hasAcknowledgedRecordingConsent = false
    @ObservationIgnored @Shared(.groqAPIKey) public var storedGroqAPIKey = ""
    @ObservationIgnored @Shared(.historyRetentionMode) public var historyRetentionMode: HistoryRetentionMode = .both
    @ObservationIgnored @Shared(.appleIntelligenceEnabled) public var appleIntelligenceEnabled = false

    public var lastError: String?
    public var transientMessage: String?

    public var onCompleted: (@MainActor () -> Void)?
    public var onMinimize: (@MainActor () -> Void)?

    @ObservationIgnored @Dependency(\.permissionsClient) private var permissionsClient
    @ObservationIgnored @Dependency(\.foundationModelClient) private var foundationModelClient
    @ObservationIgnored @Dependency(\.audioClient) private var audioClient
    @ObservationIgnored @Dependency(\.continuousClock) private var clock

    @ObservationIgnored @Shared(.hasCompletedSetup) private var hasCompletedSetup = false

    @ObservationIgnored private var permissionMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var accessibilityObserverTask: Task<Void, Never>?
    @ObservationIgnored private var lastPageTransitionDate: Date?
    @ObservationIgnored private let isPreviewMode: Bool

    public init(initialPage: Page = .welcome, downloadViewModel: ModelDownloadModel? = nil, isPreviewMode: Bool = false) {
        self.currentPage = initialPage
        self.isPreviewMode = isPreviewMode
        modelDownloadViewModel = downloadViewModel ?? ModelDownloadModel(isPreviewMode: isPreviewMode)

        if isPreviewMode {
            $historyRetentionMode.withLock { $0 = .both }
            microphonePermissionState = .authorized
            microphoneAuthorized = true
            accessibilityAuthorized = true
            return
        }

        startPermissionMonitoring()
        startAccessibilityObserver()
    }

    // MARK: - Computed

    public var selectedModelOption: ModelOption? {
        modelDownloadViewModel.selectedModelOption
    }

    private var shouldShowAppleIntelligencePage: Bool {
        guard foundationModelClient.isAvailable() else { return false }
        guard let selectedModelOption else { return false }
        if selectedModelOption.provider == .voxtralCore {
            return false
        }
        return !selectedModelOption.supportsSmartTranscription
    }

    private var shouldCompleteAfterModelSelection: Bool {
        guard selectedModelOption != nil else { return false }
        return nextPage == nil
    }

    private var requiresGroqAPIKey: Bool {
        selectedModelOption == .groqWhisperLargeV3Turbo
    }

    public var hasConfiguredShortcut: Bool {
        KeyboardShortcuts.getShortcut(for: .pushToTalk) != nil
    }

    public var recordingConsentAcknowledged: Bool {
        hasAcknowledgedRecordingConsent
    }

    public func setRecordingConsentAcknowledged(_ acknowledged: Bool) {
        $hasAcknowledgedRecordingConsent.withLock { $0 = acknowledged }
    }

    // MARK: - Actions

    public func windowAppeared() {
        if isPreviewMode { return }
        refreshPermissionStatus()
    }

    public func selectedModelChanged() {
        modelDownloadViewModel.selectedModelChanged()
        transientMessage = nil
        lastError = nil
    }

    public var hasPendingGroqAPIKeyDraft: Bool {
        !groqAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasUsableGroqAPIKey: Bool {
        hasPendingGroqAPIKeyDraft || !storedGroqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasGroqAPIKeyStored: Bool {
        !storedGroqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func persistGroqAPIKeyIfNeeded() {
        let trimmed = groqAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        $storedGroqAPIKey.withLock { $0 = trimmed }
        groqAPIKeyDraft = ""
    }

    public func clearStoredGroqAPIKey() {
        $storedGroqAPIKey.withLock { $0 = "" }
        groqAPIKeyDraft = ""
    }

    public func microphonePermissionButtonTapped() async {
        if isPreviewMode {
            microphonePermissionState = .authorized
            microphoneAuthorized = true
            lastError = nil
            return
        }

        let granted = await permissionsClient.requestMicrophonePermission()
        await refreshPermissionStatusAsync()

        if granted || microphoneAuthorized {
            audioClient.warmup()
            lastError = nil
            return
        }

        if microphonePermissionState == .denied {
            await permissionsClient.openMicrophonePrivacySettings()
            lastError = "Turn on microphone access in System Settings, then return to Verbatim."
            return
        }

        lastError = "Microphone access is required to record audio."
    }

    public func accessibilityPermissionButtonTapped() {
        if isPreviewMode {
            accessibilityAuthorized = true
            transientMessage = nil
            return
        }

        Task {
            await ensureAccessibilityPermission()
        }
    }

    public func downloadModel() async {
        await modelDownloadViewModel.downloadModel()
        transientMessage = modelDownloadViewModel.transientMessage
        lastError = modelDownloadViewModel.lastError
    }

    public func minimizeToMiniWindow() {
        onMinimize?()
    }

    public func completeSetup() {
        $hasAcknowledgedRecordingConsent.withLock { $0 = true }
        $hasCompletedSetup.withLock { $0 = true }
        permissionMonitorTask?.cancel()
        accessibilityObserverTask?.cancel()
        audioClient.warmup()
        onCompleted?()
    }

    // MARK: - Private

    private func ensureAccessibilityPermission() async {
        if isPreviewMode {
            accessibilityAuthorized = true
            transientMessage = nil
            lastError = nil
            return
        }

        await permissionsClient.promptForAccessibilityPermission()
        await refreshPermissionStatusAsync()

        if accessibilityAuthorized {
            lastError = nil
            transientMessage = nil
            return
        }

        await permissionsClient.openAccessibilityPrivacySettings()
        lastError = "Accessibility access is required to continue."
        transientMessage = "Turn on Accessibility in System Settings, then return to Verbatim."
    }

    private func refreshPermissionStatus() {
        if isPreviewMode { return }
        Task { await refreshPermissionStatusAsync() }
    }

    private func refreshPermissionStatusAsync() async {
        if isPreviewMode { return }
        microphonePermissionState = await permissionsClient.microphonePermissionState()
        let previousMicrophoneAuthorized = microphoneAuthorized
        microphoneAuthorized = microphonePermissionState == .authorized
        accessibilityAuthorized = await permissionsClient.hasAccessibilityPermission()
        if microphoneAuthorized && !previousMicrophoneAuthorized {
            audioClient.warmup()
        }
    }

    private func startPermissionMonitoring() {
        permissionMonitorTask?.cancel()
        permissionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshPermissionStatusAsync()
                try? await self.clock.sleep(for: .seconds(1))
            }
        }
    }

    private func startAccessibilityObserver() {
        accessibilityObserverTask?.cancel()
        accessibilityObserverTask = Task { [weak self] in
            guard let self else { return }
            for await granted in self.permissionsClient.observeAccessibilityPermissionChanges() {
                guard !Task.isCancelled else { return }
                self.accessibilityAuthorized = granted
            }
        }
    }

    deinit {
        permissionMonitorTask?.cancel()
        accessibilityObserverTask?.cancel()
    }
}

// MARK: - Page Metadata

extension OnboardingModel.Page {
    public var primaryTitle: String {
        switch self {
        case .welcome, .consent, .model, .shortcut, .microphone, .accessibility, .appleIntelligence, .historyRetention: "Continue"
        case .download: "Download Model"
        }
    }

    public var primaryActionDelay: CGFloat {
        switch self {
        case .welcome: 1.5
        default: 0.1
        }
    }
}

// MARK: - Preview Support

extension OnboardingModel {
    public static func makePreview(
        page: Page = .welcome,
        configure: (OnboardingModel) -> Void = { _ in }
    ) -> OnboardingModel {
        let model = OnboardingModel(initialPage: page, isPreviewMode: true)
        configure(model)
        return model
    }
}
