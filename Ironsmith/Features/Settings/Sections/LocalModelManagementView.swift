import SwiftUI

struct LocalModelManagementView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    let provider: ProviderConfig
    @AppStorage(IronsmithPreferenceKeys.appleFoundationModelEnabled)
    private var appleFoundationModelEnabled = false
    @AppStorage(IronsmithPreferenceKeys.hasPresentedAppleFoundationModelWarning)
    private var hasPresentedAppleFoundationModelWarning = false
    #if DEBUG
        @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowAppleFoundationModelWarning)
        private var debugAlwaysShowAppleFoundationModelWarning = false
    #endif
    @State private var modelPendingDeletion: ModelConfig?
    @State private var isShowingAppleFoundationModelWarning = false

    @MainActor
    private var rows: [LocalModelRow] {
        let localModels = inferenceStore.persistedModels
            .filter { $0.providerIdentifier == provider.identifier }
        let modelRows =
            localModels
            .filter {
                $0.installState == .installed || $0.installState == .builtIn
                    || $0.installState == .downloading
            }
            .map { LocalModelRow(model: $0, isAppleFoundationEnabled: appleFoundationModelEnabled) }

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
                    case .appleFoundation:
                        Toggle(
                            "Enable Apple Foundation Model",
                            isOn: appleFoundationModelEnabledBinding
                        )
                        .labelsHidden()
                        .help(
                            "Allows Ironsmith to use Apple's built-in local model for simple requests."
                        )
                        .accessibilityLabel("Enable Apple Foundation Model")
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
        .alert(
            "Foundation Model Information",
            isPresented: $isShowingAppleFoundationModelWarning
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "The Apple Foundation Model is only useful for very simple apps and demos. It's recommended to use a more capable AI model."
            )
        }
    }

    private var appleFoundationModelEnabledBinding: Binding<Bool> {
        Binding(
            get: { appleFoundationModelEnabled },
            set: { isEnabled in
                let wasEnabled = appleFoundationModelEnabled
                appleFoundationModelEnabled = isEnabled
                inferenceStore.setAppleFoundationModelEnabled(isEnabled)
                if isEnabled && !wasEnabled {
                    presentAppleFoundationModelWarningIfNeeded()
                }
            }
        )
    }

    private func presentAppleFoundationModelWarningIfNeeded() {
        guard shouldShowAppleFoundationModelWarning else { return }

        hasPresentedAppleFoundationModelWarning = true
        isShowingAppleFoundationModelWarning = true
    }

    private var shouldShowAppleFoundationModelWarning: Bool {
        #if DEBUG
            if debugAlwaysShowAppleFoundationModelWarning {
                return true
            }
        #endif

        return !hasPresentedAppleFoundationModelWarning
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
        case .appleFoundation(let isEnabled):
            isEnabled
        case .builtIn, .installed:
            true
        case .downloading, .available:
            false
        }
    }

    init(model: ModelConfig, isAppleFoundationEnabled: Bool) {
        identifier = model.identifier
        displayName = model.displayName
        detailText = model.source == .appleFoundation ? "Apple Foundation Model" : model.identifier

        if model.source == .appleFoundation {
            state = .appleFoundation(isEnabled: isAppleFoundationEnabled)
            return
        }

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
        case appleFoundation(isEnabled: Bool)
        case builtIn
        case installed(ModelConfig)
        case downloading(Double)
        case available(MLXModelCatalog.Entry)
    }
}
