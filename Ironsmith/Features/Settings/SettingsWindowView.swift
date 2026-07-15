import SwiftData
import SwiftUI

struct SettingsWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @AppStorage(IronsmithPreferenceKeys.hasPresentedOllamaModelDownloadNudge)
    private var hasPresentedOllamaModelDownloadNudge = false
    #if DEBUG
    @AppStorage(IronsmithPreferenceKeys.debugAlwaysOpenOllamaEditorAfterAdd)
    private var debugAlwaysOpenOllamaEditorAfterAdd = false
    #endif
    @State private var presentedSheet: SettingsPresentedSheet?
    @State private var pendingProviderEditorIdentifierAfterSheetDismissal: String?
    @State private var hasPreparedSettings = false

    var body: some View {
        Form {
            SettingsProvidersSectionView(
                onAddProvider: { presentedSheet = .addProvider(initialKind: nil) },
                onEditProvider: { presentedSheet = .editProvider($0, showsCreditPacks: false) }
            )
            SettingsPreferencesSectionView()
            #if DEBUG
            SettingsDebugSectionView()
            #endif
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 680, minHeight: 720)
        .task {
            await inferenceStore.prepareSettings(modelContext: modelContext)
            hasPreparedSettings = true
            consumePendingSettingsRoute()
        }
        .onChange(of: routeStore.pendingSettingsRoute) {
            guard hasPreparedSettings else { return }
            consumePendingSettingsRoute()
        }
        .sheet(
            item: $presentedSheet,
            onDismiss: presentPendingProviderEditorIfNeeded
        ) { sheet in
            switch sheet {
            case .addProvider(let initialKind):
                AddProviderSheetView(
                    initialKind: initialKind,
                    onProviderAdded: handleProviderAdded
                )
            case .editProvider(let provider, let showsCreditPacks):
                ProviderEditorSheetView(
                    provider: provider,
                    showsCreditPacksOnAppear: showsCreditPacks
                )
            }
        }
        .alert(
            "Settings Error",
            isPresented: errorAlertBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inferenceStore.presentedErrorMessage ?? "")
        }
    }

    private func consumePendingSettingsRoute() {
        guard let route = routeStore.consumeSettingsRoute() else {
            return
        }
        apply(route)
    }

    private func apply(_ route: IronsmithSettingsRoute) {
        switch route {
        case .root, .modelSelection:
            presentedSheet = nil
        case .addProvider(let initialKind):
            presentedSheet = .addProvider(initialKind: initialKind)
        case .editProvider(let identifier):
            presentedSheet = inferenceStore.providers
                .first { $0.identifier == identifier }
                .map { SettingsPresentedSheet.editProvider($0, showsCreditPacks: false) }
        case .buyIronsmithCredits:
            presentedSheet = inferenceStore.providers
                .first { $0.kind == .ironsmith }
                .map { SettingsPresentedSheet.editProvider($0, showsCreditPacks: true) }
        }
    }

    private func handleProviderAdded(_ providerKind: ProviderKind) {
        guard providerKind == .ollama else { return }
        #if DEBUG
        if debugAlwaysOpenOllamaEditorAfterAdd {
            pendingProviderEditorIdentifierAfterSheetDismissal = ProviderKind.ollama.rawValue
            return
        }
        #endif
        guard !hasPresentedOllamaModelDownloadNudge else { return }
        hasPresentedOllamaModelDownloadNudge = true
        pendingProviderEditorIdentifierAfterSheetDismissal = ProviderKind.ollama.rawValue
    }

    private func presentPendingProviderEditorIfNeeded() {
        guard let identifier = pendingProviderEditorIdentifierAfterSheetDismissal else {
            return
        }
        pendingProviderEditorIdentifierAfterSheetDismissal = nil

        presentedSheet = inferenceStore.providers
            .first { $0.identifier == identifier }
            .map { SettingsPresentedSheet.editProvider($0, showsCreditPacks: false) }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { inferenceStore.presentedErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    inferenceStore.clearPresentedError()
                }
            }
        )
    }
}

private enum SettingsPresentedSheet: Identifiable {
    case addProvider(initialKind: ProviderKind?)
    case editProvider(ProviderConfig, showsCreditPacks: Bool)

    var id: String {
        switch self {
        case .addProvider(let initialKind):
            "addProvider.\(initialKind?.rawValue ?? "default")"
        case .editProvider(let provider, let showsCreditPacks):
            "editProvider.\(provider.id.uuidString).credits.\(showsCreditPacks)"
        }
    }
}

#Preview("Settings") {
    let container = try! IronsmithModelContainerFactory.make(isRunningTests: true)
    return SettingsWindowView()
        .modelContainer(container)
        .environment(InferenceStore())
        .environment(IronsmithRouteStore(openSettingsWindow: {}))
        .frame(width: 680, height: 720)
}
