import SwiftUI

struct SettingsProvidersSectionView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    let onAddProvider: () -> Void
    let onEditProvider: (ProviderConfig) -> Void

    var body: some View {
        Section {
            VStack(spacing: 10) {
                ForEach(inferenceStore.providers) { provider in
                    SettingsProviderCardView(
                        provider: provider,
                        onEdit: { onEditProvider(provider) }
                    )
                }
            }
        } header: {
            HStack {
                Text("Providers")
                Spacer()
                Button {
                    onAddProvider()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add Provider")
                .accessibilityLabel("Add provider")
            }
        }
    }
}

@MainActor
private struct SettingsProvidersSectionPreview: View {
    @State private var inferenceStore = SettingsPreviewState.make()

    var body: some View {
        SettingsProvidersSectionView(
            onAddProvider: {},
            onEditProvider: { _ in }
        )
            .environment(inferenceStore)
            .padding()
            .frame(width: 560)
    }
}

#Preview("Providers Section") {
    SettingsProvidersSectionPreview()
}
