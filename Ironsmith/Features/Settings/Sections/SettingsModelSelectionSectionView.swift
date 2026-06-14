import SwiftUI

struct SettingsModelSelectionSectionView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @State private var isShowingModelPicker = false

    private var selectedModel: ModelConfig? {
        inferenceStore.selectedModel
    }

    private var selectedProvider: ProviderConfig? {
        guard let selectedModel else { return nil }
        return inferenceStore.provider(for: selectedModel)
    }

    var body: some View {
        Section {
            selectedModelRow

            // GenerationSettingsView()
        } header: {
            Text("AI Model")
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheetView()
        }
    }

    @ViewBuilder
    private var selectedModelRow: some View {
        if let selectedModel {
            HStack(alignment: .center, spacing: 12) {
                Text("Selected Model")
                    .frame(width: 128, alignment: .leading)

                Spacer()

                ModelLogoView(model: selectedModel, provider: selectedProvider, size: 28)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(SettingsModelPresentation.displayName(for: selectedModel, provider: selectedProvider))
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Text("\(selectedModel.providerLabel(provider: selectedProvider)) · \(selectedModel.sourceLabel(provider: selectedProvider))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button("Choose...") {
                    isShowingModelPicker = true
                }
                .controlSize(.small)
            }
        } else {
            HStack(alignment: .center) {
                Text("Selected Model")
                    .frame(width: 128, alignment: .leading)
                Spacer()
                Button("Choose AI model...") {
                    isShowingModelPicker = true
                }
            }
        }
    }
}

private struct ModelPickerSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var providersWithModels: [(provider: ProviderConfig, models: [ModelConfig])] {
        inferenceStore.providers.compactMap { provider in
            let models = inferenceStore.availableModels
                .filter { $0.providerIdentifier == provider.identifier }
                .filter(matchesSearch)
                .sorted {
                    SettingsModelPresentation.displayName(for: $0, provider: provider)
                        .localizedStandardCompare(SettingsModelPresentation.displayName(for: $1, provider: provider)) == .orderedAscending
                }

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
                        description: Text(searchText.isEmpty ? "No AI models are available." : "No AI models match your search.")
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
                                            isSelected: model.selectionIdentifier == inferenceStore.selectedModelID
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
        .frame(minWidth: 560, minHeight: 520)
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
        guard provider.kind == .ironsmith,
              let estimatedToolCredits = model.estimatedToolCredits
        else {
            return nil
        }

        return estimatedToolCredits == 1
            ? "~1 credit/app"
            : "~\(estimatedToolCredits.formatted()) credits/app"
    }
}

private extension ModelConfig {
    func providerLabel(provider: ProviderConfig?) -> String {
        source == .appleFoundation ? "Apple Foundation" : (provider?.displayName ?? "Unknown Provider")
    }

    func sourceLabel(provider: ProviderConfig?) -> String {
        switch source {
        case .appleFoundation: "Local"
        case .mlx: "MLX"
        case .remote: provider?.kind == .ollama ? "Local" : "Remote"
        }
    }

}

@MainActor
private struct SettingsModelSelectionSectionPreview: View {
    @State private var inferenceStore = SettingsPreviewState.make(selectedModel: .remote)

    var body: some View {
        Form {
            SettingsModelSelectionSectionView()
        }
        .formStyle(.grouped)
        .environment(inferenceStore)
        .padding(20)
        .frame(width: 620, height: 680)
    }
}

#Preview("AI Model Section") {
    SettingsModelSelectionSectionPreview()
}
