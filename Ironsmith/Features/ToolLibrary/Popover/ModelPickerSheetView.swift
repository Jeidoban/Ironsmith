import SwiftUI

struct ModelPickerSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var providersWithModels: [(provider: ProviderConfig, models: [ModelConfig])] {
        inferenceStore.providers.compactMap { provider in
            let models = inferenceStore.models(for: provider)
                .filter(matchesSearch)

            guard !models.isEmpty else { return nil }
            return (provider, models)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if providersWithModels.isEmpty {
                    ContentUnavailableView(
                        "No AI Models",
                        systemImage: "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "No AI models are available." : "No AI models match your search.")
                    )
                } else {
                    List {
                        ForEach(providersWithModels, id: \.provider.id) { item in
                            Section {
                                ForEach(item.models) { model in
                                    Button {
                                        inferenceStore.selectModel(model.selectionIdentifier)
                                        dismiss()
                                    } label: {
                                        ModelPickerRowView(
                                            model: model,
                                            provider: item.provider,
                                            isSelected: model.selectionIdentifier
                                                == inferenceStore.selectedModelID
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(item.provider.displayName)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .searchable(text: $searchText, prompt: "Search AI models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 380, height: 480)
    }

    private func matchesSearch(_ model: ModelConfig) -> Bool {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else { return true }
        let provider = inferenceStore.provider(for: model)
        return SettingsModelPresentation.displayName(for: model, provider: provider)
            .localizedCaseInsensitiveContains(trimmedSearch)
            || model.identifier.localizedCaseInsensitiveContains(trimmedSearch)
    }
}

private struct ModelPickerRowView: View {
    let model: ModelConfig
    let provider: ProviderConfig
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ModelLogoView(model: model, provider: provider, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsModelPresentation.displayName(for: model, provider: provider))
                    .lineLimit(1)

                Text(model.identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let estimatedCreditsText {
                    Text(estimatedCreditsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(model.sourceLabel(provider: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            }
        }
        .padding(8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
    }

    private var estimatedCreditsText: String? {
        guard let estimatedToolCredits = ToolLibraryCreditEstimate.creditsRange(
            model: model,
            provider: provider
        )
        else {
            return nil
        }

        return "\(estimatedToolCredits.lowerBound.formatted())-\(estimatedToolCredits.upperBound.formatted()) credits/app"
    }
}

extension ModelConfig {
    fileprivate func sourceLabel(provider: ProviderConfig?) -> String {
        switch source {
        case .appleFoundation: "Local"
        case .mlx: "Unsupported"
        case .remote: provider?.kind == .ollama ? "Local" : "Remote"
        }
    }

}

@MainActor
private struct ModelPickerSheetPreview: View {
    @State private var inferenceStore = SettingsPreviewState.make(selectedModel: .remote)

    var body: some View {
        ModelPickerSheetView()
            .environment(inferenceStore)
    }
}

#Preview("Model Picker") {
    ModelPickerSheetPreview()
}
