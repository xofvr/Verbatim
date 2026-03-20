import Foundation

public enum OutputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard = "clipboard"
    case pasteInPlace = "paste_in_place"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clipboard:
            return "Clipboard"
        case .pasteInPlace:
            return "Paste in Place"
        }
    }
}
