import Testing
@testable import Shared

@Test
func shortAudioDoesNotGetSpedUp() {
    #expect(TranscriptionConstants.autoSpeedRate(for: 10) == nil)
    #expect(TranscriptionConstants.autoSpeedRate(for: 44.9) == nil)
}

@Test
func mediumAudioGetsModerateSpeedup() {
    #expect(TranscriptionConstants.autoSpeedRate(for: 45) == 1.1)
    #expect(TranscriptionConstants.autoSpeedRate(for: 60) == 1.1)
    #expect(TranscriptionConstants.autoSpeedRate(for: 89.9) == 1.1)
}

@Test
func longAudioGetsHigherSpeedup() {
    #expect(TranscriptionConstants.autoSpeedRate(for: 90) == 1.2)
    #expect(TranscriptionConstants.autoSpeedRate(for: 179.9) == 1.2)
}

@Test
func veryLongAudioGetsMaxSpeedup() {
    #expect(TranscriptionConstants.autoSpeedRate(for: 180) == 1.25)
    #expect(TranscriptionConstants.autoSpeedRate(for: 600) == 1.25)
}

@Test
func boundaryValues() {
    // Exact boundaries should fall into the higher bracket
    #expect(TranscriptionConstants.autoSpeedRate(for: 0) == nil)
    #expect(TranscriptionConstants.autoSpeedRate(for: 45) == 1.1)
    #expect(TranscriptionConstants.autoSpeedRate(for: 90) == 1.2)
    #expect(TranscriptionConstants.autoSpeedRate(for: 180) == 1.25)
}

@Test
func minimumRecordingDurationIsPositive() {
    #expect(TranscriptionConstants.minimumRecordingDuration > 0)
}

@Test
func trimSilenceThresholdIsPositive() {
    #expect(TranscriptionConstants.trimSilenceThreshold > 0)
}
