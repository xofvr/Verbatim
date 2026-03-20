import SwiftUI
import UI

struct ShortcutPage: View {
    @Bindable var model: OnboardingModel
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 28) {
            OnboardingHeader(
                symbol: "keyboard",
                title: "Your Shortcut",
                description: "Double-tap the left ⌘ Command key to start recording. Tap again to stop, or hold and release.",
                layout: .vertical
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .slideIn(active: isAnimating, delay: 0.25)

            Spacer()

            Text("⌘ ⌘")
                .font(.system(size: 48, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .slideIn(active: isAnimating, delay: 0.5)

            Text("Double-tap Left Command")
                .font(.headline)
                .foregroundStyle(.tertiary)
                .slideIn(active: isAnimating, delay: 0.6)

            Spacer()
        }
        .onAppear { isAnimating = true }
    }
}

#Preview("Shortcut") {
    OnboardingView(model: .makePreview(page: .shortcut))
}
