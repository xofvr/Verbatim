import AppKit

extension WindowConfig {
    public static let about = WindowConfig(
        id: "VerbatimAboutWindow",
        title: "About Verbatim",
        style: .chromeless(.init(
            hidesCloseButton: false,
            hidesMiniaturizeButton: true,
            hidesZoomButton: true,
            isFloating: true
        )),
        size: CGSize(width: 280, height: 500)
    )

    public static let settings = WindowConfig(
        id: "VerbatimSettingsWindow",
        title: "Verbatim Settings",
        style: .chromeless(.init(
            hidesCloseButton: false,
            hidesMiniaturizeButton: true,
            hidesZoomButton: true,
            isFloating: true
        )),
        size: CGSize(width: 500, height: 800)
    )

    public static let onboarding = WindowConfig(
        id: "VerbatimOnboardingWindow",
        title: "Verbatim Onboarding",
        style: .titled(.init(
            showsCloseButton: true,
            toolbarStyle: .unifiedCompact
        )),
        size: CGSize(width: 820, height: 512),
        animationBehavior: .utilityWindow
    )

    public static let miniDownload = WindowConfig(
        id: "VerbatimMiniDownloadWindow",
        title: "Downloading",
        style: .chromeless(.init(
            hidesCloseButton: true,
            hidesMiniaturizeButton: true,
            hidesZoomButton: true,
            isFloating: true,
            visualEffect: VisualEffectConfig(material: .hudWindow, blendingMode: .behindWindow)
        )),
        size: CGSize(width: 120, height: 120),
        animationBehavior: .utilityWindow,
        collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]
    )

    public static let batch = WindowConfig(
        id: "VerbatimBatchWindow",
        title: "Verbatim Batch Transcription",
        style: .titled(.init(showsCloseButton: true, toolbarStyle: .unifiedCompact)),
        size: CGSize(width: 620, height: 560),
        animationBehavior: .utilityWindow
    )

    public static let consent = WindowConfig(
        id: "VerbatimConsentWindow",
        title: "Recording Consent",
        style: .titled(.init(
            showsCloseButton: true,
            toolbarStyle: .unifiedCompact
        )),
        size: CGSize(width: 500, height: 280),
        animationBehavior: .utilityWindow
    )
}
