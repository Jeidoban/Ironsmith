import AuthenticationServices
import SwiftData
import SwiftUI

struct ToolLibraryPopoverView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @Environment(MenuBarPopoverPresentationStore.self) private var menuBarPopoverPresentationStore
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Query(sort: \Tool.updatedAt, order: .reverse) private var tools: [Tool]
    @AppStorage(IronsmithPreferenceKeys.showSandboxOverride) private var showSandboxOverride = false
    #if DEBUG
    @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowWelcomeOnboarding)
    private var debugAlwaysShowWelcomeOnboarding = false
    @AppStorage(IronsmithPreferenceKeys.debugPopoverEmptyStateMode)
    private var debugPopoverEmptyStateModeRawValue = ToolLibraryDebugPopoverEmptyStateMode.off.rawValue
    #endif
    let appUpdateStore: AppUpdateStore
    private let welcomeOnboardingStore: WelcomeOnboardingStore
    @State private var toolLibraryStore = ToolLibraryStore()
    @State private var toolPendingDeletion: Tool?
    @State private var toolPendingRename: Tool?
    @State private var pendingRenameName = ""
    @State private var hasCheckedWelcomeOnboarding = false
    @State private var isShowingWelcomeOnboarding = false
    @State private var isShowingModelPicker = false
    @State private var isSigningInToIronsmith = false
    @FocusState private var isPromptFocused: Bool

    @MainActor
    init() {
        appUpdateStore = AppUpdateStore()
        welcomeOnboardingStore = WelcomeOnboardingStore()
    }

    init(
        appUpdateStore: AppUpdateStore,
        welcomeOnboardingStore: WelcomeOnboardingStore = WelcomeOnboardingStore()
    ) {
        self.appUpdateStore = appUpdateStore
        self.welcomeOnboardingStore = welcomeOnboardingStore
    }

    var body: some View {
        // The menu bar popover stays intentionally small: tool list first, prompt last.
        VStack(spacing: 14) {
            ToolLibraryPopoverHeaderView(
                appUpdateStore: appUpdateStore,
                isLoadingModels: !inferenceStore.hasLoadedModels && !shouldForceNoModels,
                selectedModelStatusText: selectedModelStatusText,
                selectedIronsmithCreditWarningText: selectedIronsmithCreditWarningText,
                onOpenStore: {
                    routeStore.open(.store(.root))
                },
                onOpenSettings: {
                    routeStore.open(.settings(.root))
                }
            )

            ScrollView {
                LazyVStack(spacing: 10) {
                    if shouldShowEmptyState {
                        ToolLibraryEmptyStateView(
                            showsNoModelActions: shouldShowNoModelsEmptyState,
                            isSigningInToIronsmith: isSigningInToIronsmith,
                            onSignInToIronsmith: signInToIronsmith
                        )
                    } else {
                        ForEach(tools) { tool in
                            // Clicking the row selects edit mode; the context menu
                            // keeps secondary actions out of the main flow.
                            ToolRowView(
                                tool: tool,
                                isSelected: toolLibraryStore.isSelected(tool),
                                isRunning: toolLibraryStore.runningToolID == tool.id,
                                isExporting: toolLibraryStore.exportingToolID == tool.id,
                                isRebuilding: toolLibraryStore.rebuildingToolID == tool.id,
                                isRestoring: toolLibraryStore.restoringToolID == tool.id,
                                canRevert: toolLibraryStore.canRestorePreviousVersion(tool),
                                onSelect: {
                                    toolLibraryStore.toggleSelection(
                                        for: tool,
                                        defaultSettings: defaultGenerationSettings
                                    )
                                },
                                onEdit: {
                                    selectToolForEditing(tool)
                                },
                                onRun: {
                                    Task {
                                        await toolLibraryStore.run(tool)
                                    }
                                },
                                onRename: {
                                    beginRenaming(tool)
                                },
                                onRebuild: {
                                    Task {
                                        await toolLibraryStore.rebuild(tool, in: modelContext)
                                    }
                                },
                                onPublishToStore: {
                                    routeStore.open(.store(.publishTool(tool.id)))
                                },
                                onRevert: {
                                    Task {
                                        await toolLibraryStore.restorePreviousVersion(tool, in: modelContext)
                                    }
                                },
                                onExport: {
                                    Task {
                                        await toolLibraryStore.export(tool)
                                    }
                                },
                                onShowInFinder: {
                                    Task {
                                        await toolLibraryStore.showInFinder(tool)
                                    }
                                },
                                onViewSource: {
                                    Task {
                                        await toolLibraryStore.viewSource(tool)
                                    }
                                },
                                onContinue: {
                                    toolLibraryStore.continueGeneration(
                                        tool,
                                        modelContext: modelContext,
                                        inferenceStore: inferenceStore
                                    )
                                },
                                onDiscard: {
                                    toolLibraryStore.discardGeneration(tool, in: modelContext)
                                },
                                onStop: {
                                    toolLibraryStore.cancelGeneration()
                                },
                                onDelete: {
                                    toolPendingDeletion = tool
                                }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 14)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
            .task(id: restoreAvailabilityRefreshID) {
                await toolLibraryStore.refreshRestoreAvailability(for: tools)
            }

            PromptComposerView(
                prompt: $toolLibraryStore.prompt,
                sandboxEnabled: sandboxEnabledBinding,
                appKind: appKindBinding,
                sandboxPermissions: sandboxPermissionsBinding,
                resourcePermissions: resourcePermissionsBinding,
                placeholder: toolLibraryStore.promptPlaceholder,
                showsSandboxControl: showSandboxOverride,
                modelPickerTitle: composerModelPickerTitle,
                isModelPickerEnabled: isComposerModelPickerEnabled,
                isSubmitEnabled: canSubmitPrompt,
                isSubmitting: toolLibraryStore.isGenerating,
                isPromptFocused: $isPromptFocused,
                onChooseModel: {
                    isShowingModelPicker = true
                },
                onSubmit: {
                    guard inferenceStore.selectedModel != nil, !shouldForceNoModels else { return }
                    if !showSandboxOverride {
                        toolLibraryStore.sandboxEnabled = true
                    }
                    toolLibraryStore.startPromptSubmission(
                        modelContext: modelContext,
                        inferenceStore: inferenceStore
                    )
                },
                onCancel: {
                    toolLibraryStore.cancelGeneration()
                }
            )
        }
        .padding(16)
        .frame(width: 340, height: 520)
        .accessibilityIdentifier("tool-library-root")
        .onAppear {
            toolLibraryStore.initializeNextGenerationSettingsIfNeeded(defaultGenerationSettings)
            presentWelcomeOnboardingIfNeeded()
            applyPendingToolLibraryRoute()
        }
        .onDisappear {
            pauseWelcomeOnboardingPresentation()
        }
        .onChange(of: menuBarPopoverPresentationStore.showCount) { _, _ in
            if shouldAlwaysShowWelcomeOnboarding {
                hasCheckedWelcomeOnboarding = false
            }
            presentWelcomeOnboardingIfNeeded()
            applyPendingToolLibraryRoute()
        }
        .onChange(of: menuBarPopoverPresentationStore.closeCount) { _, _ in
            pauseWelcomeOnboardingPresentation()
        }
        .task(id: selectedIronsmithRefreshID) {
            guard selectedIronsmithRefreshID != nil else { return }
            await inferenceStore.refreshIronsmithAccountSummary()
        }
        .task(id: inferenceStore.hasLoadedModels) {
            presentWelcomeOnboardingIfNeeded()
        }
        .onChange(of: tools.map(\.id)) { _, _ in
            toolLibraryStore.syncSelection(with: tools, defaultSettings: defaultGenerationSettings)
            applyPendingToolLibraryRoute()
        }
        .onChange(of: defaultGenerationSettings) { _, settings in
            toolLibraryStore.initializeNextGenerationSettingsIfNeeded(settings)
        }
        .onChange(of: showSandboxOverride) { _, isEnabled in
            if !isEnabled {
                toolLibraryStore.sandboxEnabled = true
                toolLibraryStore.rememberCurrentGenerationSettingsForNextGeneration()
            }
        }
        .alert(
            "Ironsmith couldn’t finish",
            isPresented: Binding(
                get: { toolLibraryStore.presentedErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        toolLibraryStore.clearPresentedError()
                    }
                }
            )
        ) {
            if toolLibraryStore.presentedErrorAction == .buyIronsmithCredits {
                Button("Buy Credits") {
                    openIronsmithCreditPurchase()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(toolLibraryStore.presentedErrorMessage ?? "")
        }
        .alert(
            "AI Model Unavailable",
            isPresented: Binding(
                get: { inferenceStore.selectedModelFallbackMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        inferenceStore.clearSelectedModelFallbackMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inferenceStore.selectedModelFallbackMessage ?? "")
        }
        .alert(
            "Sign In Failed",
            isPresented: Binding(
                get: { inferenceStore.presentedErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        inferenceStore.clearPresentedError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inferenceStore.presentedErrorMessage ?? "")
        }
        .confirmationDialog(
            "Delete App?",
            isPresented: deleteConfirmationBinding
        ) {
            Button("Delete App", role: .destructive) {
                if let toolPendingDeletion {
                    toolLibraryStore.delete(toolPendingDeletion, in: modelContext)
                }
                toolPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                toolPendingDeletion = nil
            }
        } message: {
            Text(toolPendingDeletion.map { "Delete \($0.name)? This can't be undone." } ?? "Delete this app? This can't be undone.")
        }
        .alert(
            "Rename App",
            isPresented: renameAlertBinding
        ) {
            TextField("App Name", text: $pendingRenameName)
            Button("Cancel", role: .cancel) {
                clearPendingRename()
            }
            Button("Save") {
                commitPendingRename()
            }
            .disabled(pendingRenameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new display name for this app.")
        }
        .sheet(
            isPresented: $isShowingWelcomeOnboarding,
            onDismiss: dismissWelcomeOnboardingPresentation
        ) {
            IronsmithWelcomeOnboardingSheetView(
                onComplete: completeWelcomeOnboarding
            )
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheetView(size: .popover)
        }
    }

    private var restoreAvailabilityRefreshID: [String] {
        tools.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSinceReferenceDate)" }
    }

    private var canSubmitPrompt: Bool {
        toolLibraryStore.canSubmitPrompt && inferenceStore.selectedModel != nil && !shouldForceNoModels
    }

    private var composerModelPickerTitle: String {
        if shouldForceNoModels {
            return "No model"
        }

        guard inferenceStore.hasLoadedModels else {
            return "Loading model..."
        }

        if let selectedModelDisplayName {
            return selectedModelDisplayName
        }

        if inferenceStore.availableModels.isEmpty {
            return "No model"
        }

        return "Choose model"
    }

    private var isComposerModelPickerEnabled: Bool {
        inferenceStore.hasLoadedModels && !shouldForceNoModels
    }

    private var selectedModelStatusText: String? {
        guard !shouldForceNoModels else {
            return nil
        }

        return selectedIronsmithCreditsText
    }

    private var selectedModelDisplayName: String? {
        guard let selectedModel = inferenceStore.selectedModel else {
            return nil
        }

        return SettingsModelPresentation.displayName(
            for: selectedModel,
            provider: selectedProvider
        )
    }

    private var selectedProvider: ProviderConfig? {
        guard let selectedModel = inferenceStore.selectedModel else {
            return nil
        }

        return inferenceStore.provider(for: selectedModel)
    }

    private var selectedIronsmithCreditsText: String? {
        guard selectedProvider?.kind == .ironsmith else {
            return nil
        }

        if let credits = inferenceStore.ironsmithAccountSummary?.credits.balanceCredits {
            return credits == 1 ? "1 credit" : "\(credits) credits"
        }

        if inferenceStore.isRefreshingIronsmithAccount {
            return "Refreshing credits"
        }

        if inferenceStore.ironsmithSession == nil {
            return "Sign in required"
        }

        return "Credits unavailable"
    }

    private var selectedIronsmithCreditWarningText: String? {
        guard !shouldForceNoModels else {
            return nil
        }

        return ToolLibraryCreditWarning.message(
            model: inferenceStore.selectedModel,
            provider: selectedProvider,
            balanceCredits: inferenceStore.ironsmithAccountSummary?.credits.balanceCredits
        )
    }

    private var selectedIronsmithRefreshID: String? {
        guard selectedProvider?.kind == .ironsmith else {
            return nil
        }

        return inferenceStore.selectedModelID
    }

    private var defaultGenerationSettings: ToolGenerationSettings {
        ToolLibraryStore.defaultGenerationSettings(from: inferenceStore.generationPreferences)
    }

    private var sandboxEnabledBinding: Binding<Bool> {
        Binding(
            get: { toolLibraryStore.sandboxEnabled },
            set: { newValue in
                toolLibraryStore.sandboxEnabled = newValue
                toolLibraryStore.rememberCurrentGenerationSettingsForNextGeneration()
            }
        )
    }

    private var appKindBinding: Binding<ToolAppKind> {
        Binding(
            get: { toolLibraryStore.appKind },
            set: { newValue in
                toolLibraryStore.appKind = newValue
                toolLibraryStore.rememberCurrentGenerationSettingsForNextGeneration()
            }
        )
    }

    private var sandboxPermissionsBinding: Binding<GeneratedAppSandboxPermissions> {
        Binding(
            get: { toolLibraryStore.sandboxPermissions },
            set: { newValue in
                toolLibraryStore.sandboxPermissions = newValue
                toolLibraryStore.rememberCurrentGenerationSettingsForNextGeneration()
            }
        )
    }

    private var resourcePermissionsBinding: Binding<GeneratedAppResourcePermissions> {
        Binding(
            get: { toolLibraryStore.resourcePermissions },
            set: { newValue in
                toolLibraryStore.resourcePermissions = newValue
                toolLibraryStore.rememberCurrentGenerationSettingsForNextGeneration()
            }
        )
    }

    private func openIronsmithCreditPurchase() {
        toolLibraryStore.clearPresentedError()
        routeStore.open(.settings(.buyIronsmithCredits))
    }

    private func signInToIronsmith() {
        guard !isSigningInToIronsmith else { return }
        isSigningInToIronsmith = true

        Task {
            let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { @MainActor url in
                try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: IronsmithOAuthRedirect.appCallbackScheme
                )
            }

            await MainActor.run {
                isSigningInToIronsmith = false
                guard didSignIn else { return }
                inferenceStore.selectIronsmithModel(
                    identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier
                )
            }
        }
    }

    private func selectToolForEditing(_ tool: Tool) {
        guard tool.isGenerationReady else { return }
        toolLibraryStore.selectForEditing(tool, defaultSettings: defaultGenerationSettings)
        isPromptFocused = true
    }

    private func applyPendingToolLibraryRoute() {
        guard let route = routeStore.consumeToolLibraryRoute() else { return }
        switch route {
        case .selectTool(let id, let focusPrompt):
            guard let tool = tools.first(where: { $0.id == id }) else { return }
            toolLibraryStore.selectForEditing(tool, defaultSettings: defaultGenerationSettings)
            isPromptFocused = focusPrompt
        }
    }

    private func beginRenaming(_ tool: Tool) {
        toolPendingRename = tool
        pendingRenameName = tool.name
    }

    private func commitPendingRename() {
        guard let toolPendingRename else { return }
        toolLibraryStore.rename(toolPendingRename, to: pendingRenameName, in: modelContext)
        clearPendingRename()
    }

    private func clearPendingRename() {
        toolPendingRename = nil
        pendingRenameName = ""
    }

    private var shouldShowEmptyState: Bool {
        shouldForceNoApps || tools.isEmpty
    }

    private var shouldShowNoModelsEmptyState: Bool {
        shouldForceNoModels || (inferenceStore.hasLoadedModels && inferenceStore.availableModels.isEmpty)
    }

    private var shouldForceNoApps: Bool {
        #if DEBUG
        debugPopoverEmptyStateMode.forcesNoApps
        #else
        false
        #endif
    }

    private var shouldForceNoModels: Bool {
        #if DEBUG
        debugPopoverEmptyStateMode.forcesNoModels
        #else
        false
        #endif
    }

    #if DEBUG
    private var debugPopoverEmptyStateMode: ToolLibraryDebugPopoverEmptyStateMode {
        ToolLibraryDebugPopoverEmptyStateMode(rawValue: debugPopoverEmptyStateModeRawValue) ?? .off
    }
    #endif

    private func presentWelcomeOnboardingIfNeeded() {
        guard inferenceStore.hasLoadedModels else { return }
        guard !hasCheckedWelcomeOnboarding else { return }
        guard !isShowingWelcomeOnboarding else { return }

        hasCheckedWelcomeOnboarding = true
        guard shouldAlwaysShowWelcomeOnboarding || !welcomeOnboardingStore.hasCompleted else { return }

        isShowingWelcomeOnboarding = true
    }

    private var shouldAlwaysShowWelcomeOnboarding: Bool {
        #if DEBUG
        debugAlwaysShowWelcomeOnboarding
        #else
        false
        #endif
    }

    private func completeWelcomeOnboarding() {
        welcomeOnboardingStore.complete()
        isShowingWelcomeOnboarding = false
    }

    private func dismissWelcomeOnboardingPresentation() {
        isShowingWelcomeOnboarding = false
        if !welcomeOnboardingStore.hasCompleted {
            hasCheckedWelcomeOnboarding = false
        }
    }

    private func pauseWelcomeOnboardingPresentation() {
        guard isShowingWelcomeOnboarding else { return }
        dismissWelcomeOnboardingPresentation()
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { toolPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    toolPendingDeletion = nil
                }
            }
        )
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { toolPendingRename != nil },
            set: { isPresented in
                if !isPresented {
                    clearPendingRename()
                }
            }
        )
    }
}

#Preview("Tool Library") {
    let container = try! IronsmithModelContainerFactory.make(isRunningTests: true)
    let menuBarPopoverPresentationStore = MenuBarPopoverPresentationStore()
    return ToolLibraryPopoverView()
        .modelContainer(container)
        .environment(InferenceStore())
        .environment(IronsmithRouteStore(openSettingsWindow: {}))
        .environment(menuBarPopoverPresentationStore)
}
