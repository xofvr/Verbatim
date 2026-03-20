import Dependencies
import DependenciesMacros
import Foundation
import Shared

public struct GroqTranscriptionSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct GroqTranscriptionResult: Equatable, Sendable {
    public var text: String
    public var segments: [GroqTranscriptionSegment]
    public var model: String

    public init(text: String, segments: [GroqTranscriptionSegment] = [], model: String = "whisper-large-v3-turbo") {
        self.text = text
        self.segments = segments
        self.model = model
    }
}

public enum GroqResponseFormat: String, Sendable {
    case text
    case verboseJSON = "verbose_json"
}

enum GroqTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Groq API key is missing."
        case .invalidResponse:
            return "Groq returned an invalid transcription response."
        case let .httpError(code, body):
            if body.isEmpty {
                return "Groq request failed with HTTP \(code)."
            }
            return "Groq request failed with HTTP \(code): \(body)"
        }
    }
}

@DependencyClient
public struct GroqTranscriptionClient: Sendable {
    public var transcribe: @Sendable (
        _ audioURL: URL,
        _ language: String?,
        _ responseFormat: GroqResponseFormat,
        _ promptHints: String?
    ) async throws -> GroqTranscriptionResult
}

extension GroqTranscriptionClient: DependencyKey {
    public static var liveValue: Self {
        Self(
            transcribe: { audioURL, language, responseFormat, promptHints in
                let apiKey = UserDefaults.standard.string(forKey: "groq_api_key")?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !apiKey.isEmpty else {
                    throw GroqTranscriptionError.missingAPIKey
                }

                let configuredURL = UserDefaults.standard.string(forKey: "groq_api_base_url")
                let endpoint = URL(string: configuredURL ?? "")
                    ?? URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
                let boundary = "Boundary-\(UUID().uuidString)"
                let body = try makeMultipartBody(
                    audioURL: audioURL,
                    boundary: boundary,
                    language: language,
                    responseFormat: responseFormat,
                    promptHints: promptHints
                )

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = 30
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GroqTranscriptionError.invalidResponse
                }

                guard (200 ..< 300).contains(httpResponse.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw GroqTranscriptionError.httpError(httpResponse.statusCode, body)
                }

                switch responseFormat {
                case .text:
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return GroqTranscriptionResult(text: text)
                case .verboseJSON:
                    return try decodeVerboseJSON(data)
                }
            }
        )
    }
}

extension GroqTranscriptionClient: TestDependencyKey {
    public static var testValue: Self {
        Self(
            transcribe: { _, _, _, _ in
                GroqTranscriptionResult(text: "Test transcript")
            }
        )
    }
}

public extension DependencyValues {
    var groqTranscriptionClient: GroqTranscriptionClient {
        get { self[GroqTranscriptionClient.self] }
        set { self[GroqTranscriptionClient.self] = newValue }
    }
}

private struct GroqVerboseJSONEnvelope: Decodable {
    var text: String
    var segments: [GroqVerboseJSONSegment]?
    var model: String?
}

private struct GroqVerboseJSONSegment: Decodable {
    var start: Double
    var end: Double
    var text: String
}

private func decodeVerboseJSON(_ data: Data) throws -> GroqTranscriptionResult {
    let decoder = JSONDecoder()
    let envelope = try decoder.decode(GroqVerboseJSONEnvelope.self, from: data)
    let segments = envelope.segments?.map {
        GroqTranscriptionSegment(start: $0.start, end: $0.end, text: $0.text)
    } ?? []
    return GroqTranscriptionResult(
        text: envelope.text.trimmingCharacters(in: .whitespacesAndNewlines),
        segments: segments,
        model: envelope.model ?? "whisper-large-v3-turbo"
    )
}

private func makeMultipartBody(
    audioURL: URL,
    boundary: String,
    language: String?,
    responseFormat: GroqResponseFormat,
    promptHints: String?
) throws -> Data {
    var body = Data()
    let lineBreak = "\r\n"

    func appendField(name: String, value: String) {
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append("\(value)\(lineBreak)".data(using: .utf8)!)
    }

    appendField(name: "model", value: "whisper-large-v3-turbo")
    appendField(name: "response_format", value: responseFormat.rawValue)
    appendField(name: "temperature", value: "0")
    if let language, !language.isEmpty {
        appendField(name: "language", value: language)
    }
    if let promptHints, !promptHints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        appendField(name: "prompt", value: promptHints)
    }

    let fileData = try Data(contentsOf: audioURL)
    let mimeType = mimeTypeForAudioURL(audioURL)
    body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\(lineBreak)".data(using: .utf8)!)
    body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
    body.append(fileData)
    body.append(lineBreak.data(using: .utf8)!)
    body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)

    return body
}

private func mimeTypeForAudioURL(_ url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "wav":
        return "audio/wav"
    case "m4a":
        return "audio/m4a"
    case "mp3":
        return "audio/mpeg"
    case "aiff", "aif":
        return "audio/aiff"
    default:
        return "application/octet-stream"
    }
}
