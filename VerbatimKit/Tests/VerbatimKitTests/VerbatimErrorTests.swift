import Testing
@testable import Shared

@Test
func everyErrorCaseHasDescription() {
    let cases: [VerbatimError] = [
        .pipelineUnavailable,
        .recordingTooShort,
        .microphoneDenied,
        .recordingFailed(""),
        .recordingFailed("detail"),
        .transcriptionFailed(""),
        .transcriptionFailed("detail"),
    ]
    for error in cases {
        #expect(error.errorDescription != nil, "Missing description for \(error)")
        #expect(!error.errorDescription!.isEmpty, "Empty description for \(error)")
    }
}

@Test
func recordingTooShortHasNoRecoverySuggestion() {
    #expect(VerbatimError.recordingTooShort.recoverySuggestion == nil)
}

@Test
func otherErrorsHaveRecoverySuggestion() {
    let cases: [VerbatimError] = [
        .pipelineUnavailable,
        .microphoneDenied,
        .recordingFailed(""),
        .recordingFailed("detail"),
        .transcriptionFailed(""),
        .transcriptionFailed("detail"),
    ]
    for error in cases {
        #expect(error.recoverySuggestion != nil, "Missing recovery for \(error)")
        #expect(!error.recoverySuggestion!.isEmpty, "Empty recovery for \(error)")
    }
}

@Test
func fullMessageCombinesDescriptionAndSuggestion() {
    let error = VerbatimError.microphoneDenied
    let full = error.fullMessage
    #expect(full.contains(error.errorDescription!))
    #expect(full.contains(error.recoverySuggestion!))
}

@Test
func fullMessageFallsBackToDescriptionOnly() {
    let error = VerbatimError.recordingTooShort
    #expect(error.fullMessage == error.errorDescription)
}

@Test
func recordingFailedIncludesDetailInRecovery() {
    let error = VerbatimError.recordingFailed("Device busy")
    #expect(error.recoverySuggestion!.contains("Device busy"))
}

@Test
func transcriptionFailedIncludesDetailInRecovery() {
    let error = VerbatimError.transcriptionFailed("Timeout")
    #expect(error.recoverySuggestion!.contains("Timeout"))
}
