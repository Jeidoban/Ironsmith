import Foundation
import SwiftUI

struct SettingsProviderCardView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    let provider: ProviderConfig
    let onEdit: () -> Void
    @AppStorage(IronsmithPreferenceKeys.appleFoundationModelEnabled)
    private var appleFoundationModelEnabled = false
    @State private var isShowingAllModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ProviderSummaryRowView(provider: provider, logoSize: 32)

                Spacer()

                Text(modelCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.35), in: Capsule())

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit Provider")
                .accessibilityLabel("Edit \(provider.displayName)")
            }

            if let connectionIssue = inferenceStore.connectionIssue(for: provider) {
                providerConnectionIssueView(connectionIssue)
            } else if modelRows.isEmpty {
                Label(SettingsProviderModelEmptyState.message(for: provider), systemImage: "circle.dashed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleModelRows) { row in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(row.isInstalled ? 1 : 0))
                                .accessibilityLabel("Installed")
                                .accessibilityHidden(!row.isInstalled)

                            Text(row.displayName)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }

                    if hiddenModelCount > 0 {
                        Button("+ \(hiddenModelCount) more") {
                            isShowingAllModels = true
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if isShowingAllModels && modelRows.count > 4 {
                        Button("Show fewer") {
                            isShowingAllModels = false
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelRows: [ProviderModelRow] {
        let models = inferenceStore.models(for: provider)
        switch provider.kind {
        case .local:
            let localDisplayModels = inferenceStore.persistedModels
                .filter { $0.providerIdentifier == provider.identifier }
            return localModelRows(localDisplayModels)
        case .ollama:
            return ollamaModelRows(models)
        default:
            return models.map {
                ProviderModelRow(
                    identifier: $0.identifier,
                    displayName: SettingsModelPresentation.displayName(for: $0, provider: provider),
                    isInstalled: true
                )
            }
        }
    }

    private func localModelRows(_ models: [ModelConfig]) -> [ProviderModelRow] {
        let storedRows = models
            .filter { $0.installState == .installed || $0.installState == .builtIn || $0.installState == .downloading }
            .map {
                ProviderModelRow(
                    identifier: $0.identifier,
                    displayName: $0.displayName,
                    isInstalled: isModelInstalledInProviderCard($0)
                )
            }
        let storedIdentifiers = Set(storedRows.map(\.identifier))
        let availableRows = MLXModelCatalog.all
            .filter { !storedIdentifiers.contains($0.identifier) }
            .map {
                ProviderModelRow(
                    identifier: $0.identifier,
                    displayName: $0.displayName,
                    isInstalled: false
                )
            }

        return (storedRows + availableRows)
            .sorted {
                if $0.isInstalled != $1.isInstalled {
                    return $0.isInstalled
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private func isModelInstalledInProviderCard(_ model: ModelConfig) -> Bool {
        if model.source == .appleFoundation {
            return appleFoundationModelEnabled
        }

        return model.installState == .installed || model.installState == .builtIn
    }

    private func ollamaModelRows(_ models: [ModelConfig]) -> [ProviderModelRow] {
        let discoveredRows = models.map {
            ProviderModelRow(
                identifier: $0.identifier,
                displayName: SettingsModelPresentation.displayName(for: $0, provider: provider),
                isInstalled: true
            )
        }
        let discoveredIdentifiers = Set(discoveredRows.map(\.identifier))
        let availableRows = OllamaModelCatalog.all
            .filter { !discoveredIdentifiers.contains($0.identifier) }
            .map {
                ProviderModelRow(
                    identifier: $0.identifier,
                    displayName: $0.displayName,
                    isInstalled: false
                )
            }

        return (discoveredRows + availableRows)
            .sorted {
                if $0.isInstalled != $1.isInstalled {
                    return $0.isInstalled
                }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private var visibleModelRows: [ProviderModelRow] {
        isShowingAllModels ? modelRows : Array(modelRows.prefix(4))
    }

    private var hiddenModelCount: Int {
        max(modelRows.count - visibleModelRows.count, 0)
    }

    private var modelCountText: String {
        modelRows.count == 1 ? "1 Model" : "\(modelRows.count) Models"
    }

    @ViewBuilder
    private func providerConnectionIssueView(_ issue: ProviderConnectionIssue) -> some View {
        HStack(spacing: 10) {
            Label(issue.message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if inferenceStore.canStartOllama(for: provider) {
                Button {
                    inferenceStore.startOllama(for: provider)
                } label: {
                    if inferenceStore.isStartingOllama(provider) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Starting Ollama")
                    } else {
                        Text("Start Ollama")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(inferenceStore.isStartingOllama(provider))
            }
        }
    }
}

private struct ProviderModelRow: Identifiable {
    let identifier: String
    let displayName: String
    let isInstalled: Bool

    var id: String { identifier }
}

extension ProviderConfig {
    var settingsDetailText: String {
        if kind == .local {
            return "On-device"
        }

    if kind == .ironsmith {
        return "ironsmith.app"
    }

        guard let components = URLComponents(string: baseURLString),
              let host = components.host,
              !host.isEmpty
        else {
            return "Remote"
        }

        if let port = components.port {
            return "\(host):\(port)"
        }

        return host
    }
}

@MainActor
private struct SettingsProviderCardPreview: View {
    @State private var inferenceStore = SettingsPreviewState.make()

    var body: some View {
        if let provider = inferenceStore.providers.last {
            SettingsProviderCardView(
                provider: provider,
                onEdit: {}
            )
            .environment(inferenceStore)
            .padding()
            .frame(width: 520)
        }
    }
}

#Preview("Provider Card") {
    SettingsProviderCardPreview()
}
