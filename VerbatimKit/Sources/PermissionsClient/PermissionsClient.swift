@preconcurrency import ApplicationServices
import AppKit
import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation

public enum MicrophonePermissionState: Sendable {
    case notDetermined
    case denied
    case authorized
}

@DependencyClient
public struct PermissionsClient: Sendable {
    public var microphonePermissionState: @Sendable () async -> MicrophonePermissionState = { .notDetermined }
    public var requestMicrophonePermission: @Sendable () async -> Bool = { false }
    public var hasAccessibilityPermission: @Sendable () async -> Bool = { false }
    public var promptForAccessibilityPermission: @Sendable () async -> Void = {}
    public var hasInputMonitoringPermission: @Sendable () async -> Bool = { false }
    public var promptForInputMonitoringPermission: @Sendable () async -> Bool = { false }
    public var openMicrophonePrivacySettings: @Sendable () async -> Void = {}
    public var openAccessibilityPrivacySettings: @Sendable () async -> Void = {}
    public var openInputMonitoringPrivacySettings: @Sendable () async -> Void = {}
    public var observeAccessibilityPermissionChanges: @Sendable () -> AsyncStream<Bool> = { AsyncStream { $0.finish() } }
}

extension PermissionsClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            microphonePermissionState: {
                await MainActor.run { microphonePermissionStateLive() }
            },
            requestMicrophonePermission: {
                await requestMicrophonePermissionLive()
            },
            hasAccessibilityPermission: {
                await MainActor.run { accessibilityPermissionGrantedLive() }
            },
            promptForAccessibilityPermission: {
                await MainActor.run { promptForAccessibilityPermissionLive() }
            },
            hasInputMonitoringPermission: {
                await MainActor.run { inputMonitoringPermissionGrantedLive() }
            },
            promptForInputMonitoringPermission: {
                await MainActor.run { promptForInputMonitoringPermissionLive() }
            },
            openMicrophonePrivacySettings: {
                await MainActor.run { openMicrophonePrivacySettingsLive() }
            },
            openAccessibilityPrivacySettings: {
                await MainActor.run { openAccessibilityPrivacySettingsLive() }
            },
            openInputMonitoringPrivacySettings: {
                await MainActor.run { openInputMonitoringPrivacySettingsLive() }
            },
            observeAccessibilityPermissionChanges: {
                observeAccessibilityPermissionChangesLive()
            }
        )
    }
}

extension PermissionsClient: TestDependencyKey {
    public static var testValue: Self {
        Self(
            microphonePermissionState: { .authorized },
            requestMicrophonePermission: { true },
            hasAccessibilityPermission: { true },
            promptForAccessibilityPermission: {},
            hasInputMonitoringPermission: { true },
            promptForInputMonitoringPermission: { true },
            openMicrophonePrivacySettings: {},
            openAccessibilityPrivacySettings: {},
            openInputMonitoringPrivacySettings: {},
            observeAccessibilityPermissionChanges: { AsyncStream { $0.yield(true); $0.finish() } }
        )
    }
}

public extension DependencyValues {
    var permissionsClient: PermissionsClient {
        get { self[PermissionsClient.self] }
        set { self[PermissionsClient.self] = newValue }
    }
}

@MainActor
private func microphonePermissionStateLive() -> MicrophonePermissionState {
    let captureState = microphonePermissionStateFromCaptureDevice()

    if #available(macOS 14.0, *) {
        let audioApplicationState: MicrophonePermissionState
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            audioApplicationState = .authorized
        case .undetermined:
            audioApplicationState = .notDetermined
        case .denied:
            audioApplicationState = .denied
        @unknown default:
            audioApplicationState = .denied
        }

        if captureState == .authorized || audioApplicationState == .authorized {
            return .authorized
        }

        if captureState == .notDetermined || audioApplicationState == .notDetermined {
            return .notDetermined
        }

        return .denied
    }

    return captureState
}

private func requestMicrophonePermissionLive() async -> Bool {
    if await MainActor.run(body: { microphonePermissionStateLive() == .authorized }) {
        return true
    }

    if #available(macOS 14.0, *) {
        let appPermissionGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { isGranted in
                continuation.resume(returning: isGranted)
            }
        }

        if appPermissionGranted {
            return true
        }
    }

    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
        return true
    }

    let capturePermissionGranted = await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { isGranted in
            continuation.resume(returning: isGranted)
        }
    }

    if capturePermissionGranted {
        return true
    }

    return await MainActor.run(body: { microphonePermissionStateLive() == .authorized })
}

@MainActor
private func promptForAccessibilityPermissionLive() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

@MainActor
private func accessibilityPermissionGrantedLive() -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: false] as CFDictionary
    return AXIsProcessTrustedWithOptions(options) || AXIsProcessTrusted()
}

@MainActor
private func openMicrophonePrivacySettingsLive() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
        return
    }

    NSWorkspace.shared.open(url)
}

@MainActor
private func openAccessibilityPrivacySettingsLive() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
        return
    }

    NSWorkspace.shared.open(url)
}

@MainActor
private func inputMonitoringPermissionGrantedLive() -> Bool {
    CGPreflightListenEventAccess()
}

@MainActor
private func promptForInputMonitoringPermissionLive() -> Bool {
    CGRequestListenEventAccess()
}

@MainActor
private func openInputMonitoringPrivacySettingsLive() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
        return
    }

    NSWorkspace.shared.open(url)
}

@MainActor
private func microphonePermissionStateFromCaptureDevice() -> MicrophonePermissionState {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
        return .notDetermined
    case .restricted, .denied:
        return .denied
    case .authorized:
        return .authorized
    @unknown default:
        return .denied
    }
}

private func observeAccessibilityPermissionChangesLive() -> AsyncStream<Bool> {
    AsyncStream { continuation in
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            let granted = AXIsProcessTrusted()
            continuation.yield(granted)
        }

        continuation.onTermination = { _ in
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
