import SwiftUI

struct LocalModelManagementView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    let provider: ProviderConfig
    @AppStorage(IronsmithPreferenceKeys.appleFoundationModelEnabled)
    private var appleFoundationModelEnabled = false
    @State private var modelPendingDeletion: ModelConfig?

    @MainActor
    private var rows: [LocalModelRow] {
        let localModels = inferenceStore.models(for: provider)
        let modelRows =
            localModels
            .filter {
                $0.installState == .installed || $0.installState == .builtIn
                    || $0.installState == .downloading
            }
            .map(LocalModelRow.init(model:))

        let knownIdentifiers = Set(modelRows.map(\.identifier))
        let catalogRows = MLXModelCatalog.all
            .filter { !knownIdentifiers.contains($0.identifier) }
            .map(LocalModelRow.init(entry:))

        return (modelRows + catalogRows)
            .sorted {
                if $0.isInstalled != $1.isInstalled {
                    return $0.isInstalled
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable Apple Foundation Model", isOn: appleFoundationModelEnabledBinding)
                .help("Allows Ironsmith to use Apple's built-in local model for simple requests.")
                .padding(.bottom, 2)

            ForEach(rows, id: \.id) { row in
                HStack(spacing: 10) {
                    ModelLogoView(
                        identifier: row.identifier,
                        displayName: row.displayName,
                        fallbackProviderKind: provider.kind,
                        size: 30
                    )

                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(row.isInstalled ? 1 : 0))
                        .accessibilityLabel("Installed")
                        .accessibilityHidden(!row.isInstalled)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .lineLimit(1)

                        Text(row.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    switch row.state {
                    case .builtIn:
                        Text("Built in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .installed(let model):
                        Button("Delete", role: .destructive) {
                            modelPendingDeletion = model
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                    case .downloading(let progress):
                        ProgressView(value: progress)
                            .frame(width: 92)
                            .accessibilityLabel("Downloading \(row.displayName)")
                    case .available(let entry):
                        Button("Download") {
                            inferenceStore.downloadFromCatalog(entry)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }

            if rows.isEmpty {
                Text(SettingsProviderModelEmptyState.message(for: provider))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "More directly downloadable local AI models are coming soon. For now, use Ollama and the recommended AI models."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
        .confirmationDialog(
            "Delete Local AI Model?",
            isPresented: deleteConfirmationBinding
        ) {
            Button("Delete AI Model", role: .destructive) {
                if let modelPendingDeletion {
                    inferenceStore.deleteLocalModel(modelPendingDeletion)
                }
                modelPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                modelPendingDeletion = nil
            }
        } message: {
            Text(
                modelPendingDeletion?.displayName
                    ?? "This AI model will be removed from local storage.")
        }
    }

    private var appleFoundationModelEnabledBinding: Binding<Bool> {
        Binding(
            get: { appleFoundationModelEnabled },
            set: { isEnabled in
                appleFoundationModelEnabled = isEnabled
                inferenceStore.setAppleFoundationModelEnabled(isEnabled)
            }
        )
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { modelPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    modelPendingDeletion = nil
                }
            }
        )
    }
}

private struct LocalModelRow: Identifiable {
    let identifier: String
    let displayName: String
    let detailText: String
    let state: State

    var id: String { identifier }

    var isInstalled: Bool {
        switch state {
        case .builtIn, .installed:
            true
        case .downloading, .available:
            false
        }
    }

    init(model: ModelConfig) {
        identifier = model.identifier
        displayName = model.displayName
        detailText = model.source == .appleFoundation ? "Apple Foundation Model" : model.identifier

        switch model.installState {
        case .builtIn:
            state = .builtIn
        case .installed:
            state = model.source == .mlx ? .installed(model) : .builtIn
        case .downloading:
            state = .downloading(model.downloadProgress ?? 0)
        case .downloadable, .failed:
            state = .builtIn
        }
    }

    init(entry: MLXModelCatalog.Entry) {
        identifier = entry.identifier
        displayName = entry.displayName
        detailText = entry.identifier
        state = .available(entry)
    }

    enum State {
        case builtIn
        case installed(ModelConfig)
        case downloading(Double)
        case available(MLXModelCatalog.Entry)
    }
}
