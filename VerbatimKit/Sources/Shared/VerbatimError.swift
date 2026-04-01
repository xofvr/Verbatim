import Foundation

/// User-facing errors surfaced through the menu bar and floating capsule.
///
/// Every case provides both a plain `errorDescription` (what went wrong) and a
/// `recoverySuggestion` (what the user should do next). This ensures errors are
/// consistently actionable across the app.
public enum VerbatimError: LocalizedError {
    /// The transcription model or provider is not ready to process audio.
    case pipelineUnavailable
    /// The recording was too short to contain usable speech.
    case recordingTooShort
    /// Microphone permission has been denied or not yet granted.
    case microphoneDenied
    /// The audio engine failed to start recording.
    case recordingFailed(String)
    /// The transcription pipeline threw an unexpected error.
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pipelineUnavailable:
            return "Transcription pipeline is not available."
        case .recordingTooShort:
            return "Recording was too short to transcribe."
        case .microphoneDenied:
            return "Microphone access is required to record."
        case .recordingFailed:
            return "Verbatim could not start recording."
        case .transcriptionFailed:
            return "Transcription did not complete."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pipelineUnavailable:
            return "Select a model in Settings and wait for it to finish loading."
        case .recordingTooShort:
            return nil
        case .microphoneDenied:
            return "Open System Settings → Privacy & Security → Microphone and turn on Verbatim."
        case .recordingFailed(let detail):
            return detail.isEmpty
                ? "Check that your microphone is connected and not in use by another app."
                : "\(detail). Check that your microphone is connected and not in use by another app."
        case .transcriptionFailed(let detail):
            return detail.isEmpty
                ? "Try again. If using Groq, verify your API key and internet connection."
                : "\(detail). If using Groq, verify your API key and internet connection."
        }
    }

    /// A combined user-visible description including the recovery suggestion when available.
    public var fullMessage: String {
        if let description = errorDescription, let suggestion = recoverySuggestion {
            return "\(description) \(suggestion)"
        }
        return errorDescription ?? "An unknown error occurred."
    }
}
