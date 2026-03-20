import SwiftUI
import UI

struct RecordingConsentPage: View {
    @Bindable var model: OnboardingModel
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingHeader(
                symbol: "checkmark.shield.fill",
                title: "Recording Acknowledgement",
                description: "Before using Verbatim for live recording, confirm that you will handle consent and company policy correctly.",
                layout: .vertical
            )
            .slideIn(active: isAnimating, delay: 0.2)

            VStack(alignment: .leading, spacing: 12) {
                bullet("Obtain permission before recording anyone else.")
                bullet("Use Verbatim only in ways that comply with law, policy, and internal guidance.")
            }
            .padding(20)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
            .slideIn(active: isAnimating, delay: 0.35)

            Toggle(isOn: Binding(
                get: { model.recordingConsentAcknowledged },
                set: { model.setRecordingConsentAcknowledged($0) }
            )) {
                Text("I understand and will obtain any required consent before recording.")
                    .font(.headline)
            }
            .toggleStyle(.checkbox)
            .slideIn(active: isAnimating, delay: 0.5)
        }
        .onAppear { isAnimating = true }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Recording Consent") {
    OnboardingView(model: .makePreview(page: .consent))
}
