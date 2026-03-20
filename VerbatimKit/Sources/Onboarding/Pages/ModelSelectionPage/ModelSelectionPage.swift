import Shared
import SwiftUI
import UI

struct ModelSelectionPage: View {
    @Bindable var model: OnboardingModel
    @State private var isAnimating = false

    private var selectedModelOption: ModelOption? {
        ModelOption(rawValue: model.selectedModelID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingHeader(
                    symbol: "externaldrive.fill",
                    title: "Choose a Model",
                    description: "Choose between local models and Groq cloud transcription. Groq needs an API key; local models run on-device.",
                    layout: .vertical
                )
                .slideIn(active: isAnimating, delay: 0.25)

                VStack(spacing: 10) {
                    ForEach(ModelOption.allCases) { option in
                        ModelOptionCard(
                            option: option,
                            isSelected: option.rawValue == model.selectedModelID
                        ) {
                            model.selectedModelID = option.rawValue
                        }
                    }
                }
                .slideIn(active: isAnimating, delay: 0.5)

                if selectedModelOption == .groqWhisperLargeV3Turbo {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Groq API Key")
                            .font(.headline)

                        SecureField("Paste your Groq API key", text: Binding(
                            get: { model.groqAPIKeyDraft },
                            set: { model.groqAPIKeyDraft = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            model.persistGroqAPIKeyIfNeeded()
                        }

                        HStack(spacing: 12) {
                            Button("Save API Key") {
                                model.persistGroqAPIKeyIfNeeded()
                            }
                            .disabled(!model.hasPendingGroqAPIKeyDraft)

                            if model.hasGroqAPIKeyStored {
                                Button("Clear Saved Key", role: .destructive) {
                                    model.clearStoredGroqAPIKey()
                                }
                            }
                        }

                        Text(model.hasGroqAPIKeyStored
                             ? "A Groq key is already saved. Paste a new one only if you want to replace it."
                             : "Paste your Groq key once. Verbatim saves it locally and does not need to read it back into this field.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.08))
                    )
                    .slideIn(active: isAnimating, delay: 0.65)
                }
            }
        }
        .scrollIndicators(.hidden)
        .onAppear { isAnimating = true }
    }
}

#Preview("Model Selection") {
    OnboardingView(model: .makePreview(page: .model))
}
