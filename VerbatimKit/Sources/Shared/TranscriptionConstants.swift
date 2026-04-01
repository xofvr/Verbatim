public enum TranscriptionConstants {
    /// Silence amplitude threshold used by the trim stage.
    public static let trimSilenceThreshold: Float = 0.003

    /// Recordings shorter than this are silently discarded without transcription.
    public static let minimumRecordingDuration: Double = 0.1

    /// Returns the playback speed-up multiplier for the speed stage, or nil if the
    /// audio is too short to benefit from acceleration.
    public static func autoSpeedRate(for audioDuration: Double) -> Double? {
        switch audioDuration {
        case ..<45:
            return nil
        case 45..<90:
            return 1.1
        case 90..<180:
            return 1.2
        default:
            return 1.25
        }
    }
}
