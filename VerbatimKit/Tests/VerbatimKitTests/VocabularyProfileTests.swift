import Foundation
import Testing
@testable import Shared

@Test
func emptyProfileMergedOverBasePreservesBase() {
    let base = VocabularyProfile(promptHints: "hint", terms: ["a": "A"])
    let empty = VocabularyProfile()
    let merged = empty.merged(over: base)
    #expect(merged.promptHints == "hint")
    #expect(merged.terms == ["a": "A"])
}

@Test
func localTermsOverrideBaseTerms() {
    let base = VocabularyProfile(terms: ["api": "API", "sql": "SQL"])
    let local = VocabularyProfile(terms: ["api": "Api"])
    let merged = local.merged(over: base)
    #expect(merged.terms["api"] == "Api")
    #expect(merged.terms["sql"] == "SQL")
}

@Test
func promptHintsAreConcatenatedWithComma() {
    let base = VocabularyProfile(promptHints: "Git, GitHub")
    let local = VocabularyProfile(promptHints: "Groq, Verbatim")
    let merged = local.merged(over: base)
    #expect(merged.promptHints == "Git, GitHub, Groq, Verbatim")
}

@Test
func mergedOverEmptyBaseReturnsLocal() {
    let local = VocabularyProfile(promptHints: "hint", terms: ["x": "X"])
    let merged = local.merged(over: VocabularyProfile())
    #expect(merged.promptHints == "hint")
    #expect(merged.terms == ["x": "X"])
}

@Test
func applyingReplacesTermsCaseInsensitively() {
    let profile = VocabularyProfile(terms: ["groq": "Groq", "api": "API"])
    let result = profile.applying(to: "groq api is fast")
    #expect(result.contains("Groq"))
    #expect(result.contains("API"))
}

@Test
func applyingOnEmptyTextReturnsEmpty() {
    let profile = VocabularyProfile(terms: ["a": "A"])
    #expect(profile.applying(to: "") == "")
}

@Test
func applyingWithNoTermsReturnsOriginal() {
    let profile = VocabularyProfile()
    let text = "Hello world"
    #expect(profile.applying(to: text) == text)
}

@Test
func defaultProfileIsNotEmpty() {
    let profile = VocabularyProfile.defaultProfile
    #expect(!profile.promptHints.isEmpty)
    #expect(!profile.terms.isEmpty)
}

@Test
func emptyProfileEncodesAndDecodes() throws {
    let profile = VocabularyProfile()
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(VocabularyProfile.self, from: data)
    #expect(decoded == profile)
}

@Test
func profileWithTermsRoundTrips() throws {
    let profile = VocabularyProfile(
        promptHints: "React, Next.js",
        terms: ["nextjs": "Next.js", "react": "React"]
    )
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(VocabularyProfile.self, from: data)
    #expect(decoded == profile)
}
