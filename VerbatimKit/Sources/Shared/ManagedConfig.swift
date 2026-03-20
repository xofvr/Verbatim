import Foundation

public struct ManagedConfig: Codable, Equatable, Sendable {
    public var vocabulary: VocabularyProfile
    public var defaultLanguage: String
    public var providerPolicy: ProviderPolicy
    public var features: ManagedConfigFeatures
    public var metadata: ManagedConfigMetadata

    public init(
        vocabulary: VocabularyProfile = .defaultProfile,
        defaultLanguage: String = "en",
        providerPolicy: ProviderPolicy = .groqPrimaryLocalFallback,
        features: ManagedConfigFeatures = .init(),
        metadata: ManagedConfigMetadata = .init()
    ) {
        self.vocabulary = vocabulary
        self.defaultLanguage = defaultLanguage
        self.providerPolicy = providerPolicy
        self.features = features
        self.metadata = metadata
    }
}

public struct ManagedConfigFeatures: Codable, Equatable, Sendable {
    public var cloudTranscriptionAllowed: Bool
    public var pasteInPlaceAllowed: Bool
    public var inAppUpdatesEnabled: Bool

    public init(
        cloudTranscriptionAllowed: Bool = true,
        pasteInPlaceAllowed: Bool = true,
        inAppUpdatesEnabled: Bool = true
    ) {
        self.cloudTranscriptionAllowed = cloudTranscriptionAllowed
        self.pasteInPlaceAllowed = pasteInPlaceAllowed
        self.inAppUpdatesEnabled = inAppUpdatesEnabled
    }
}

public struct ManagedConfigMetadata: Codable, Equatable, Sendable {
    public var version: Int
    public var environment: String
    public var fetchedAt: Date?

    public init(
        version: Int = 1,
        environment: String = "production",
        fetchedAt: Date? = nil
    ) {
        self.version = version
        self.environment = environment
        self.fetchedAt = fetchedAt
    }
}
