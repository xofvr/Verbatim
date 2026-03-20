import Foundation
import Shared

enum ManagedDefaults {
    private static let key = "com.apple.configuration.managed"

    static var values: [String: Any] {
        UserDefaults.standard.dictionary(forKey: key) ?? [:]
    }

    static func string(forKey key: String) -> String? {
        values[key] as? String
    }

    static func bool(forKey key: String) -> Bool? {
        values[key] as? Bool
    }

    static func providerPolicy(forKey key: String) -> ProviderPolicy? {
        guard let rawValue = string(forKey: key) else { return nil }
        return ProviderPolicy(rawValue: rawValue)
    }

    static func effectiveProviderPolicy(
        userValue: ProviderPolicy,
        managedConfig: ManagedConfig?
    ) -> ProviderPolicy {
        providerPolicy(forKey: "provider_policy")
            ?? managedConfig?.providerPolicy
            ?? userValue
    }

    static func effectiveCloudAllowed(managedConfig: ManagedConfig?) -> Bool {
        bool(forKey: "cloud_transcription_allowed")
            ?? managedConfig?.features.cloudTranscriptionAllowed
            ?? true
    }

    static func effectivePasteInPlaceAllowed(managedConfig: ManagedConfig?) -> Bool {
        bool(forKey: "paste_in_place_allowed")
            ?? managedConfig?.features.pasteInPlaceAllowed
            ?? true
    }

    static func effectiveInAppUpdatesEnabled(managedConfig: ManagedConfig?) -> Bool {
        bool(forKey: "in_app_updates_enabled")
            ?? managedConfig?.features.inAppUpdatesEnabled
            ?? true
    }

    static func effectiveManagedConfigURL(userValue: String) -> String {
        string(forKey: "managed_config_url") ?? userValue
    }
}
