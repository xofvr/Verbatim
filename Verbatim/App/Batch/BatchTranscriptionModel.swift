import AppKit
import AVFoundation
import Dependencies
import Foundation
import Observation
import Shared
import TranscriptionClient
import UniformTypeIdentifiers

@MainActor
@Observable
final class BatchTranscriptionModel {
    struct BatchItem: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var status: String
    }

    @ObservationIgnored @Shared(.preferredLanguage) private var preferredLanguage = "en"
    @ObservationIgnored @Shared(.vocabularyProfileJSON) private var vocabularyProfileJSON = ""
    @ObservationIgnored @Dependency(\.groqTranscriptionClient) private var groqTranscriptionClient

    var items: [BatchItem] = []
    var isProcessing = false
    var lastMessage: String?

    var effectiveVocabulary: VocabularyProfile {
        (try? JSONDecoder().decode(VocabularyProfile.self, from: Data(vocabularyProfileJSON.utf8))) ?? .defaultProfile
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(BatchItem(url: url, status: "Queued"))
        }
    }

    func processAll() async {
        guard !isProcessing, !items.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }

        for index in items.indices {
            items[index].status = "Transcribing"
            do {
                let sourceURL = try await normalizedAudioURL(for: items[index].url)
                defer {
                    if sourceURL != items[index].url {
                        try? FileManager.default.removeItem(at: sourceURL)
                    }
                }

                let result = try await groqTranscriptionClient.transcribe(
                    sourceURL,
                    preferredLanguage,
                    .verboseJSON,
                    effectiveVocabulary.promptHints
                )
                let cleanedText = effectiveVocabulary.applying(to: result.text)
                try writeOutputs(for: items[index].url, text: cleanedText, segments: result.segments)
                items[index].status = "Done"
            } catch {
                items[index].status = "Failed: \(error.localizedDescription)"
            }
        }

        lastMessage = "Batch transcription completed."
    }

    private func writeOutputs(
        for originalURL: URL,
        text: String,
        segments: [GroqTranscriptionSegment]
    ) throws {
        let basePath = originalURL.deletingPathExtension().path
        let plainTextURL = URL(fileURLWithPath: basePath + "_transcript.txt")
        let timestampedURL = URL(fileURLWithPath: basePath + "_transcript_timestamped.txt")

        try text.write(to: plainTextURL, atomically: true, encoding: .utf8)

        let lines = segments.map { segment -> String in
            let startMinutes = Int(segment.start / 60)
            let startSeconds = segment.start.truncatingRemainder(dividingBy: 60)
            let endMinutes = Int(segment.end / 60)
            let endSeconds = segment.end.truncatingRemainder(dividingBy: 60)
            return String(
                format: "[%02d:%05.2f -> %02d:%05.2f] %@",
                startMinutes,
                startSeconds,
                endMinutes,
                endSeconds,
                effectiveVocabulary.applying(to: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        try lines.joined(separator: "\n").write(to: timestampedURL, atomically: true, encoding: .utf8)
    }

    private func normalizedAudioURL(for url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if ["wav", "m4a", "mp3", "aiff", "aif"].contains(ext) {
            return url
        }

        let asset = AVURLAsset(url: url)
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "verbatim-batch-\(UUID().uuidString).m4a")
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return url
        }
        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
