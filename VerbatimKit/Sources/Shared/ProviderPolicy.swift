import Foundation

public enum ProviderPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case groqPrimaryLocalFallback = "groq_primary_local_fallback"
    case localOnly = "local_only"
    case groqOnly = "groq_only"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groqPrimaryLocalFallback:
            return "Groq Primary"
        case .localOnly:
            return "Local Only"
        case .groqOnly:
            return "Groq Only"
        }
    }

    public var description: String {
        switch self {
        case .groqPrimaryLocalFallback:
            return "Use Groq first and fall back to the selected local model if the cloud path fails."
        case .localOnly:
            return "Keep transcription fully on-device."
        case .groqOnly:
            return "Use Groq only. Recording fails if Groq is unavailable."
        }
    }
}
