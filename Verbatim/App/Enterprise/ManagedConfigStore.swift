import Foundation
import Shared

actor ManagedConfigStore {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func fetch(urlString: String) async throws -> ManagedConfig? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try loadCached()
        }

        guard let url = URL(string: trimmed) else {
            return try loadCached()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return try loadCached()
            }

            var config = try decoder.decode(ManagedConfig.self, from: data)
            config.metadata.fetchedAt = Date()
            try persist(config)
            return config
        } catch {
            return try loadCached()
        }
    }

    func loadCached() throws -> ManagedConfig? {
        let url = try cacheURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ManagedConfig.self, from: data)
    }

    func persist(_ config: ManagedConfig) throws {
        let url = try cacheURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    private func cacheURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        return applicationSupport
            .appending(path: "Verbatim", directoryHint: .isDirectory)
            .appending(path: "managed-config.json")
    }
}
