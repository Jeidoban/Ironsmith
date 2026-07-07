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
    @State private var isShowingAppleFoundationModelWarning = false

    @MainActor
    private var rows: [LocalModelRow] {
        let localModels = inferenceStore.persistedModels
            .filter { $0.providerIdentifier == provider.identifier }
        return
            localModels
            .filter {
                $0.installState == .installed || $0.installState == .builtIn
            }
            .map { LocalModelRow(model: $0, isAppleFoundationEnabled: appleFoundationModelEnabled) }
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
                "For local open-weight models, use Ollama and the recommended AI models."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
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
        case .builtIn:
            true
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
        case .builtIn, .installed, .downloading, .downloadable, .failed:
            state = .builtIn
        }
    }

    enum State {
        case appleFoundation(isEnabled: Bool)
        case builtIn
    }
}
