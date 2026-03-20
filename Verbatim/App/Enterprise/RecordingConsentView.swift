import Shared
import SwiftUI

struct RecordingConsentView: View {
    let onCancel: () -> Void
    let onAccept: () -> Void
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Consent Required Before Recording")
                        .font(.system(size: 18, weight: .semibold))

                    Text("Before you use Verbatim to record or transcribe live audio, make sure you have any consent required by law or company policy.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                consentBullet("You are responsible for obtaining permission before recording others.")
                consentBullet("Use Verbatim only in ways that comply with applicable law and policy.")
            }

            Toggle(isOn: $acknowledged) {
                Text("I understand and will obtain any required consent")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Not Now", role: .cancel) {
                    onCancel()
                }

                Spacer()

                Button("Continue") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acknowledged)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func consentBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
