import Foundation
import IdentifiedCollections

public struct TranscriptHistoryDay: Codable, Identifiable, Equatable, Sendable {
    public var day: String
    public var entries: IdentifiedArrayOf<TranscriptHistoryEntry>

    public var id: String { day }

    public init(day: String, entries: IdentifiedArrayOf<TranscriptHistoryEntry> = []) {
        self.day = day
        self.entries = entries
    }
}

public struct TranscriptHistoryVariant: Codable, Identifiable, Equatable, Sendable {
    public var mode: String
    public var transcriptionElapsedSeconds: Double
    public var characterCount: Int
    public var pasteResult: String
    public var outputAction: String?
    public var transcriptRelativePath: String?

    public var id: String { mode }

    public init(
        mode: String,
        transcriptionElapsedSeconds: Double,
        characterCount: Int,
        pasteResult: String,
        outputAction: String? = nil,
        transcriptRelativePath: String? = nil
    ) {
        self.mode = mode
        self.transcriptionElapsedSeconds = transcriptionElapsedSeconds
        self.characterCount = characterCount
        self.pasteResult = pasteResult
        self.outputAction = outputAction
        self.transcriptRelativePath = transcriptRelativePath
    }
}

public struct TranscriptHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var modelID: String
    public var providerID: String?
    public var source: String?
    public var audioDurationSeconds: Double
    public var audioRelativePath: String?
    public var variants: IdentifiedArrayOf<TranscriptHistoryVariant>

    public var preferredVariant: TranscriptHistoryVariant? {
        variants[id: "smart"] ?? variants[id: "verbatim"] ?? variants[id: "original"] ?? variants.first
    }

    public var preferredTranscriptRelativePath: String? {
        preferredVariant?.transcriptRelativePath
    }

    public var preferredCharacterCount: Int {
        preferredVariant?.characterCount ?? 0
    }

    public var modeSummary: String {
        if variants.count <= 1 {
            return preferredVariant?.mode ?? "unknown"
        }
        return variants.map(\.mode).sorted().joined(separator: "+")
    }

    public init(
        id: UUID,
        timestamp: Date,
        modelID: String,
        providerID: String? = nil,
        source: String? = nil,
        audioDurationSeconds: Double,
        audioRelativePath: String? = nil,
        variants: IdentifiedArrayOf<TranscriptHistoryVariant> = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = modelID
        self.providerID = providerID
        self.source = source
        self.audioDurationSeconds = audioDurationSeconds
        self.audioRelativePath = audioRelativePath
        self.variants = variants
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case modelID
        case providerID
        case source
        case audioDurationSeconds
        case audioRelativePath
        case variants

        // Legacy keys (kept for migration of existing history.json)
        case transcriptionMode
        case transcriptionElapsedSeconds
        case characterCount
        case pasteResult
        case transcriptRelativePath
        case transcript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        modelID = try container.decode(String.self, forKey: .modelID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        audioDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .audioDurationSeconds) ?? 0
        audioRelativePath = try container.decodeIfPresent(String.self, forKey: .audioRelativePath)

        if let decodedVariants = try container.decodeIfPresent(IdentifiedArrayOf<TranscriptHistoryVariant>.self, forKey: .variants),
           !decodedVariants.isEmpty
        {
            variants = decodedVariants
            return
        }

        let legacyMode = try container.decodeIfPresent(String.self, forKey: .transcriptionMode) ?? "verbatim"
        let legacyElapsed = try container.decodeIfPresent(Double.self, forKey: .transcriptionElapsedSeconds) ?? 0
        let legacyTranscriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptRelativePath)
        let legacyTranscript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        let legacyCharacterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? legacyTranscript.count
        let legacyPasteResult = try container.decodeIfPresent(String.self, forKey: .pasteResult) ?? "skipped"

        variants = [
            TranscriptHistoryVariant(
                mode: legacyMode,
                transcriptionElapsedSeconds: legacyElapsed,
                characterCount: legacyCharacterCount,
                pasteResult: legacyPasteResult,
                outputAction: legacyPasteResult,
                transcriptRelativePath: legacyTranscriptPath
            )
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(providerID, forKey: .providerID)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(audioDurationSeconds, forKey: .audioDurationSeconds)
        try container.encodeIfPresent(audioRelativePath, forKey: .audioRelativePath)
        try container.encode(variants, forKey: .variants)
    }
}
