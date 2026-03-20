import Foundation

public struct VocabularyProfile: Codable, Equatable, Sendable {
    public var promptHints: String
    public var terms: [String: String]

    public init(
        promptHints: String = "",
        terms: [String: String] = [:]
    ) {
        self.promptHints = promptHints
        self.terms = terms
    }

    public static let defaultProfile = VocabularyProfile(
        promptHints: "PR, PRs, Git, GitHub, SQL, PostgreSQL, API, APIs, CLI, UI, UX, OAuth, JWT, JSON, YAML, TypeScript, JavaScript, Python, Node.js, Next.js, React, Vercel, AWS, Docker, Kubernetes, Redis, GraphQL",
        terms: [
            "groq": "Groq",
            "postgresql": "PostgreSQL",
        ]
    )

    public func merged(over base: VocabularyProfile) -> VocabularyProfile {
        var mergedTerms = base.terms
        for (key, value) in terms {
            mergedTerms[key] = value
        }

        let mergedHints = [base.promptHints, promptHints]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        return VocabularyProfile(promptHints: mergedHints, terms: mergedTerms)
    }

    public func applying(to text: String) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }

        return terms.reduce(text) { partial, entry in
            partial.replacingOccurrences(
                of: entry.key,
                with: entry.value,
                options: [.caseInsensitive, .regularExpression],
                range: nil
            )
        }
    }
}
