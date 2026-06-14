import SwiftUI

struct OllamaModelManagementView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    let provider: ProviderConfig
    @State private var entryPendingDeletion: OllamaModelCatalog.Entry?

    @MainActor
    private var sectionRows: [OllamaModelSection] {
        let installedIdentifiers = Set(inferenceStore.models(for: provider).map(\.identifier))
        return OllamaModelCatalog.sections.map { section in
            OllamaModelSection(
                title: section.title,
                subtitle: section.subtitle,
                rows: section.entries.map {
                    row(for: $0, installedIdentifiers: installedIdentifiers)
                }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sectionRows) { section in
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))

                        Text(section.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(section.rows) { row in
                        modelRow(row)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Ollama AI Model?",
            isPresented: deleteConfirmationBinding
        ) {
            Button("Delete AI Model", role: .destructive) {
                if let entryPendingDeletion {
                    inferenceStore.deleteOllamaRecommendedModel(entryPendingDeletion, provider: provider)
                }
                entryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text(entryPendingDeletion?.displayName ?? "This AI model will be removed from Ollama.")
        }
    }

    @MainActor
    private func row(
        for entry: OllamaModelCatalog.Entry,
        installedIdentifiers: Set<String>
    ) -> OllamaModelRow {
        let key = inferenceStore.ollamaModelTransferKey(provider: provider, modelIdentifier: entry.identifier)
        if let pullState = inferenceStore.ollamaPullStates[key] {
            return OllamaModelRow(entry: entry, state: .pulling(pullState))
        }
        if inferenceStore.ollamaDeletingModelKeys.contains(key) {
            return OllamaModelRow(entry: entry, state: .deleting)
        }
        if installedIdentifiers.contains(entry.identifier) {
            return OllamaModelRow(entry: entry, state: .installed)
        }
        return OllamaModelRow(entry: entry, state: .available)
    }

    @ViewBuilder
    private func modelRow(_ row: OllamaModelRow) -> some View {
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
            case .installed:
                Button("Delete", role: .destructive) {
                    entryPendingDeletion = row.entry
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            case .pulling(let state):
                HStack(spacing: 8) {
                    if let progress = state.progress {
                        ProgressView(value: progress, total: 1)
                            .frame(width: 92)
                            .accessibilityLabel("Downloading \(row.displayName)")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 92)
                            .accessibilityLabel("Downloading \(row.displayName)")
                    }
                    Text(state.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
            case .deleting:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Deleting \(row.displayName)")
            case .available:
                Button("Download") {
                    inferenceStore.pullOllamaRecommendedModel(row.entry, provider: provider)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    entryPendingDeletion = nil
                }
            }
        )
    }
}

private struct OllamaModelSection: Identifiable {
    let title: String
    let subtitle: String
    let rows: [OllamaModelRow]

    var id: String { title }
}

private struct OllamaModelRow: Identifiable {
    let entry: OllamaModelCatalog.Entry
    let state: State

    var id: String { entry.identifier }
    var identifier: String { entry.identifier }
    var displayName: String { entry.displayName }
    var detailText: String { entry.identifier }

    var isInstalled: Bool {
        if case .installed = state {
            return true
        }
        return false
    }

    enum State {
        case installed
        case pulling(OllamaModelTransferState)
        case deleting
        case available
    }
}
