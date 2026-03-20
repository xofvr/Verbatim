import SwiftUI

struct BatchTranscriptionView: View {
    @Bindable var model: BatchTranscriptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Batch Transcription")
                    .font(.title2.weight(.semibold))
                Text("Drop audio files here or choose files to export transcript and timestamped transcript files next to the originals.")
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary.opacity(0.3))
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 28))
                        Text("Drop audio or QuickTime files")
                        Button("Choose Files") {
                            model.chooseFiles()
                        }
                    }
                }
                .frame(height: 180)
                .dropDestination(for: URL.self) { items, _ in
                    model.addFiles(items)
                    return true
                }

            List(model.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.url.lastPathComponent)
                    Text(item.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)

            if let lastMessage = model.lastMessage {
                Text(lastMessage)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(model.isProcessing ? "Processing…" : "Transcribe") {
                    Task { await model.processAll() }
                }
                .disabled(model.isProcessing || model.items.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}
