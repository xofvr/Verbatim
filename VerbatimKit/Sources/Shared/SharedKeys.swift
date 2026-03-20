import Foundation
import Sharing

public extension SharedKey where Self == AppStorageKey<Bool>.Default {
    static var hasCompletedSetup: Self {
        Self[.appStorage("has_completed_setup"), default: false]
    }

    static var trimSilenceEnabled: Self {
        Self[.appStorage("trim_silence_enabled"), default: false]
    }

    static var autoSpeedEnabled: Self {
        Self[.appStorage("auto_speed_enabled"), default: false]
    }

    static var compressHistoryAudio: Self {
        Self[.appStorage("compress_history_audio"), default: false]
    }

    static var appleIntelligenceEnabled: Self {
        Self[.appStorage("apple_intelligence_enabled"), default: false]
    }

    static var logsEnabled: Self {
        Self[.appStorage("logs_enabled"), default: false]
    }

    static var restoreClipboardAfterPaste: Self {
        Self[.appStorage("restore_clipboard_after_paste"), default: true]
    }

    static var hasAcknowledgedRecordingConsent: Self {
        Self[.appStorage("has_acknowledged_recording_consent"), default: false]
    }

    static var hideFromScreenShare: Self {
        Self[.appStorage("hide_from_screen_share"), default: true]
    }

    static var hasGroqAPIKeyStored: Self {
        Self[.appStorage("has_groq_api_key_stored"), default: false]
    }
}

public extension SharedKey where Self == AppStorageKey<String>.Default {
    static var selectedModelID: Self {
        Self[.appStorage("selected_model_id"), default: ModelOption.defaultOption.rawValue]
    }
    static var smartPrompt: Self {
        Self[.appStorage("smart_prompt"), default: "Clean up filler words and repeated phrases. Return a polished version of what was said."]
    }

    static var preferredLanguage: Self {
        Self[.appStorage("preferred_language"), default: "en"]
    }

    static var vocabularyProfileJSON: Self {
        Self[.appStorage("vocabulary_profile_json"), default: "{\"promptHints\":\"\(VocabularyProfile.defaultProfile.promptHints)\",\"terms\":{\"groq\":\"Groq\",\"postgresql\":\"PostgreSQL\"}}"]
    }

    static var managedConfigURL: Self {
        Self[.appStorage("managed_config_url"), default: ""]
    }

    static var selectedAudioInputDeviceUID: Self {
        Self[.appStorage("selected_audio_input_device_uid"), default: ""]
    }

    static var groqAPIKey: Self {
        Self[.appStorage("groq_api_key"), default: ""]
    }

    static var groqAPIBaseURL: Self {
        Self[.appStorage("groq_api_base_url"), default: "https://api.groq.com/openai/v1/audio/transcriptions"]
    }
}

public extension SharedKey where Self == AppStorageKey<TranscriptionMode>.Default {
    static var transcriptionMode: Self {
        Self[.appStorage("transcription_mode"), default: .verbatim]
    }
}

public extension SharedKey where Self == AppStorageKey<PushToTalkThreshold>.Default {
    static var pushToTalkThreshold: Self {
        Self[.appStorage("push_to_talk_threshold"), default: .long]
    }
}

public extension SharedKey where Self == AppStorageKey<HistoryRetentionMode>.Default {
    static var historyRetentionMode: Self {
        Self[.appStorage("history_retention_mode"), default: .both]
    }
}

public extension SharedKey where Self == AppStorageKey<ShortcutTriggerMode>.Default {
    static var shortcutTriggerMode: Self {
        Self[.appStorage("shortcut_trigger_mode"), default: .doubleTap]
    }
}

public extension SharedKey where Self == AppStorageKey<Double>.Default {
    static var doubleTapInterval: Self {
        Self[.appStorage("double_tap_interval"), default: 0.4]
    }
}

public extension SharedKey where Self == AppStorageKey<DoubleTapKey>.Default {
    static var doubleTapKey: Self {
        Self[.appStorage("double_tap_key"), default: DoubleTapKey.leftCommand]
    }
}

public extension SharedKey where Self == AppStorageKey<ProviderPolicy>.Default {
    static var providerPolicy: Self {
        Self[.appStorage("provider_policy"), default: .groqPrimaryLocalFallback]
    }
}

public extension SharedKey where Self == AppStorageKey<OutputMode>.Default {
    static var outputMode: Self {
        Self[.appStorage("output_mode"), default: .clipboard]
    }
}

public extension SharedKey where Self == FileStorageKey<[TranscriptHistoryDay]>.Default {
    static var transcriptHistoryDays: Self {
        Self[
            .fileStorage(
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appending(component: "Verbatim")
                    .appending(component: "history")
                    .appending(component: "history.json")
            ),
            default: []
        ]
    }
}
