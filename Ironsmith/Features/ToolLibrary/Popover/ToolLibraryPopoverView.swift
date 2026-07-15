import AuthenticationServices
import Foundation
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
    @AppStorage(IronsmithPreferenceKeys.featureStoreEnabled) private var isStoreFeatureEnabled =
        false
    @AppStorage(IronsmithPreferenceKeys.toolLibraryViewMode) private var viewModeRawValue =
        ToolLibraryViewMode.list.rawValue
    @AppStorage(IronsmithPreferenceKeys.toolLibrarySortOrder) private var sortOrderRawValue =
        ToolLibrarySortOrder.latest.rawValue
    #if DEBUG
        @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowWelcomeOnboarding)
        private var debugAlwaysShowWelcomeOnboarding = false
        @AppStorage(IronsmithPreferenceKeys.debugPopoverEmptyStateMode)
        private var debugPopoverEmptyStateModeRawValue = ToolLibraryDebugPopoverEmptyStateMode.off
            .rawValue
    #endif
    let appUpdateStore: AppUpdateStore
    private let welcomeOnboardingStore: WelcomeOnboardingStore
    @State private var toolLibraryStore = ToolLibraryStore()
    @State private var storePublisher: ToolLibraryStorePublisher
    @State private var toolPendingDeletion: Tool?
    @State private var toolPendingRename: Tool?
    @State private var pendingRenameName = ""
    @State private var hasCheckedWelcomeOnboarding = false
    @State private var isShowingWelcomeOnboarding = false
    @State private var isShowingModelPicker = false
    @State private var isSigningInToIronsmith = false
    @State private var isSearchPresented = false
    @State private var searchText = ""
    @FocusState private var isPromptFocused: Bool

    @MainActor
    init() {
        appUpdateStore = AppUpdateStore()
        welcomeOnboardingStore = WelcomeOnboardingStore()
        _storePublisher = State(initialValue: ToolLibraryStorePublisher())
    }

    @MainActor
    init(
        appUpdateStore: AppUpdateStore,
        welcomeOnboardingStore: WelcomeOnboardingStore? = nil,
        storeClient: IronsmithStoreClient? = nil,
        iconClient: ToolIconClient = .noOp
    ) {
        self.appUpdateStore = appUpdateStore
        self.welcomeOnboardingStore = welcomeOnboardingStore ?? WelcomeOnboardingStore()
        _storePublisher = State(
            initialValue: ToolLibraryStorePublisher(
                storeClient: storeClient ?? .live,
                iconClient: iconClient
            )
        )
    }

    var body: some View {
        @Bindable var storePublisher = storePublisher

        // The menu bar popover stays intentionally small: tool list first, prompt last.
        VStack(spacing: 14) {
            ToolLibraryPopoverHeaderView(
                isSearchPresented: $isSearchPresented,
                searchText: $searchText,
                viewMode: viewModeBinding,
                sortOrder: sortOrderBinding,
                appUpdateStore: appUpdateStore,
                isLoadingModels: !inferenceStore.hasLoadedModels && !shouldForceNoModels,
                selectedModelStatusText: selectedModelStatusText,
                selectedIronsmithCreditWarningText: selectedIronsmithCreditWarningText,
                isStoreEnabled: isStoreFeatureEnabled,
                onOpenStore: {
                    routeStore.open(.store(.root))
                },
                onOpenSettings: {
                    routeStore.open(.settings(.root))
                }
            )

            ScrollView {
                toolCollectionContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 14)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
            .task(id: restoreAvailabilityRefreshID) {
                await toolLibraryStore.refreshRestoreAvailability(for: tools)
            }
            .task(id: publishedStoreLinkRefreshID) {
                guard isStoreFeatureEnabled else {
                    await storePublisher.refreshPublishedStoreApps(
                        isSignedIn: false,
                        tools: tools
                    )
                    return
                }
                await storePublisher.refreshPublishedStoreApps(
                    isSignedIn: inferenceStore.ironsmithSession != nil,
                    tools: tools
                )
            }

            PromptComposerView(
                prompt: $toolLibraryStore.prompt,
                sandboxEnabled: sandboxEnabledBinding,
                appKind: appKindBinding,
                sandboxPermissions: sandboxPermissionsBinding,
                resourcePermissions: resourcePermissionsBinding,
                codingAgentPreference: codingAgentPreferenceBinding,
                reasoningEffort: reasoningEffortBinding,
                placeholder: toolLibraryStore.promptPlaceholder,
                showsSandboxControl: showSandboxOverride,
                modelPickerTitle: composerModelPickerTitle,
                isModelPickerEnabled: isComposerModelPickerEnabled,
                isSubmitEnabled: canSubmitPrompt,
                isSubmitting: toolLibraryStore.isGenerating,
                isCodexAgentSupported: inferenceStore.selectedModelSupportsCodingAgentPreference(.codex),
                supportedReasoningEfforts: inferenceStore.selectedModelSupportedReasoningEfforts,
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
        .frame(width: 340, height: 500)
        .accessibilityIdentifier("tool-library-root")
        .onAppear {
            handlePopoverAppear()
        }
        .onDisappear {
            handlePopoverClose()
        }
        .onChange(of: menuBarPopoverPresentationStore.showCount) { _, _ in
            handlePopoverShow()
        }
        .onChange(of: menuBarPopoverPresentationStore.closeCount) { _, _ in
            handlePopoverClose()
        }
        .task(id: selectedIronsmithRefreshID) {
            await refreshSelectedIronsmithAccountIfNeeded()
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
            isPresented: toolLibraryErrorPresentedBinding
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
            isPresented: modelFallbackPresentedBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inferenceStore.selectedModelFallbackMessage ?? "")
        }
        .alert(
            "Sign In Failed",
            isPresented: signInErrorPresentedBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inferenceStore.presentedErrorMessage ?? "")
        }
        .alert(
            "App Store",
            isPresented: storeErrorPresentedBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storePublisher.errorMessage ?? "")
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
            Text(
                toolPendingDeletion.map { "Delete \($0.name)? This can't be undone." }
                    ?? "Delete this app? This can't be undone.")
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
        .sheet(isPresented: $storePublisher.isShowingPublishSheet) {
            storePublishSheet
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheetView(size: .popover)
        }
    }

    @ViewBuilder
    private var toolCollectionContent: some View {
        if shouldShowEmptyState {
            ToolLibraryEmptyStateView(
                showsNoModelActions: shouldShowNoModelsEmptyState,
                isSigningInToIronsmith: isSigningInToIronsmith,
                onSignInToIronsmith: signInToIronsmith
            )
        } else if visibleTools.isEmpty {
            ContentUnavailableView {
                Label("No Apps Found", systemImage: "magnifyingglass")
            } description: {
                Text("Try searching for a different app name.")
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .accessibilityIdentifier("tool-search-empty-state")
        } else {
            switch viewMode {
            case .list:
                LazyVStack(spacing: 10) {
                    ForEach(visibleTools) { tool in
                        ToolRowView(
                            tool: tool,
                            state: itemState(for: tool),
                            actions: itemActions(for: tool)
                        )
                    }
                }
            case .icons:
                LazyVGrid(columns: iconGridColumns, spacing: 14) {
                    ForEach(visibleTools) { tool in
                        ToolGridItemView(
                            tool: tool,
                            state: itemState(for: tool),
                            actions: itemActions(for: tool)
                        )
                    }
                }
            }
        }
    }

    private var iconGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    private var viewMode: ToolLibraryViewMode {
        ToolLibraryViewMode.resolved(viewModeRawValue)
    }

    private var sortOrder: ToolLibrarySortOrder {
        ToolLibrarySortOrder.resolved(sortOrderRawValue)
    }

    private var visibleTools: [Tool] {
        ToolLibraryPresentation.visibleTools(
            from: tools,
            searchText: searchText,
            sortOrder: sortOrder
        )
    }

    private var viewModeBinding: Binding<ToolLibraryViewMode> {
        Binding(
            get: { viewMode },
            set: { viewModeRawValue = $0.rawValue }
        )
    }

    private var sortOrderBinding: Binding<ToolLibrarySortOrder> {
        Binding(
            get: { sortOrder },
            set: { sortOrderRawValue = $0.rawValue }
        )
    }

    private func itemState(for tool: Tool) -> ToolItemPresentationState {
        ToolItemPresentationState(
            isSelected: toolLibraryStore.isSelected(tool),
            isRunning: toolLibraryStore.runningToolID == tool.id,
            isExporting: toolLibraryStore.exportingToolID == tool.id,
            isRebuilding: toolLibraryStore.rebuildingToolID == tool.id,
            isRestoring: toolLibraryStore.restoringToolID == tool.id,
            canRevert: toolLibraryStore.canRestorePreviousVersion(tool),
            showsStoreActions: isStoreFeatureEnabled,
            canUpdateStoreVersion: canUpdateStoreVersion(for: tool),
            activeCodingAgent: toolLibraryStore.activeCodingAgent(for: tool),
            canShowAgentOutput: toolLibraryStore.canShowAgentOutput(for: tool)
        )
    }

    private func itemActions(for tool: Tool) -> ToolItemActions {
        ToolItemActions(
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
                routeStore.open(.toolLibrary(.publishTool(tool.id)))
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
            onShowAgentOutput: {
                routeStore.open(.agentOutput(tool.id))
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

    @ViewBuilder
    private var storePublishSheet: some View {
        @Bindable var storePublisher = storePublisher

        if let tool = tools.first(where: { $0.id == storePublisher.publishingToolID }) {
            ToolLibraryStorePublishSheetView(
                tool: tool,
                isUpdatingPublishedListing: canUpdateStoreVersion(for: tool),
                publishName: $storePublisher.publishName,
                publishShortDescription: $storePublisher.publishShortDescription,
                publishDescription: $storePublisher.publishDescription,
                publishCategory: $storePublisher.publishCategory,
                publishDisplayName: $storePublisher.publishDisplayName,
                publishScreenshotName: storePublisher.publishScreenshotName,
                needsDisplayName: storePublisher.needsDisplayName(inferenceStore: inferenceStore),
                isPublishing: storePublisher.isPublishing,
                onSaveDisplayName: {
                    Task { await storePublisher.saveDisplayName(inferenceStore: inferenceStore) }
                },
                onChooseScreenshot: { url in
                    storePublisher.importScreenshot(from: url)
                },
                onCancel: {
                    storePublisher.isShowingPublishSheet = false
                },
                onPublish: {
                    Task {
                        await storePublisher.publish(
                            tool,
                            modelContext: modelContext,
                            inferenceStore: inferenceStore,
                            defaultSettings: defaultGenerationSettings,
                            routeStore: routeStore
                        )
                    }
                }
            )
        }
    }

    private func refreshSelectedIronsmithAccountIfNeeded() async {
        guard selectedIronsmithRefreshID != nil else { return }
        await inferenceStore.refreshIronsmithAccountSummary()
    }

    private func handlePopoverAppear() {
        toolLibraryStore.setPopoverVisible(menuBarPopoverPresentationStore.isShown)
        toolLibraryStore.initializeNextGenerationSettingsIfNeeded(defaultGenerationSettings)
        presentWelcomeOnboardingIfNeeded()
        applyPendingToolLibraryRoute()
    }

    private func handlePopoverShow() {
        toolLibraryStore.setPopoverVisible(true)
        if shouldAlwaysShowWelcomeOnboarding {
            hasCheckedWelcomeOnboarding = false
        }
        presentWelcomeOnboardingIfNeeded()
        applyPendingToolLibraryRoute()
    }

    private func handlePopoverClose() {
        toolLibraryStore.setPopoverVisible(false)
        pauseWelcomeOnboardingPresentation()
    }

    private var restoreAvailabilityRefreshID: [String] {
        tools.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSinceReferenceDate)" }
    }

    private var publishedStoreLinkRefreshID: String {
        let session = inferenceStore.ironsmithSession == nil ? "signed-out" : "signed-in"
        let storeFeature = isStoreFeatureEnabled ? "store-on" : "store-off"
        let links =
            tools
            .compactMap { tool -> String? in
                guard let storeId = tool.storeId,
                    let storeAppId = tool.storeAppId
                else { return nil }
                return "\(storeId):\(storeAppId)"
            }
            .sorted()
            .joined(separator: "|")
        return "\(storeFeature)|\(session)|\(links)"
    }

    private func canUpdateStoreVersion(for tool: Tool) -> Bool {
        storePublisher.canUpdateStoreVersion(for: tool)
    }

    private var canSubmitPrompt: Bool {
        toolLibraryStore.canSubmitPrompt && inferenceStore.selectedModel != nil
            && !shouldForceNoModels
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

    private var codingAgentPreferenceBinding: Binding<ToolCodingAgentPreference> {
        Binding(
            get: { inferenceStore.generationPreferences.codingAgentPreference },
            set: { newValue in
                inferenceStore.generationPreferences.codingAgentPreference = newValue
            }
        )
    }

    private var reasoningEffortBinding: Binding<ToolReasoningEffort> {
        Binding(
            get: { inferenceStore.generationPreferences.reasoningEffort },
            set: { inferenceStore.generationPreferences.reasoningEffort = $0 }
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
        case .publishTool(let id):
            guard isStoreFeatureEnabled else { return }
            guard let tool = tools.first(where: { $0.id == id }) else { return }
            Task {
                await storePublisher.beginPublishing(
                    tool,
                    inferenceStore: inferenceStore,
                    tools: tools
                )
            }
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
        shouldForceNoModels
            || (inferenceStore.hasLoadedModels && inferenceStore.availableModels.isEmpty)
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
            ToolLibraryDebugPopoverEmptyStateMode(rawValue: debugPopoverEmptyStateModeRawValue)
                ?? .off
        }
    #endif

    private func presentWelcomeOnboardingIfNeeded() {
        guard inferenceStore.hasLoadedModels else { return }
        guard !hasCheckedWelcomeOnboarding else { return }
        guard !isShowingWelcomeOnboarding else { return }

        hasCheckedWelcomeOnboarding = true
        guard shouldAlwaysShowWelcomeOnboarding || !welcomeOnboardingStore.hasCompleted else {
            return
        }

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

    private var toolLibraryErrorPresentedBinding: Binding<Bool> {
        Binding(
            get: { toolLibraryStore.presentedErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    toolLibraryStore.clearPresentedError()
                }
            }
        )
    }

    private var modelFallbackPresentedBinding: Binding<Bool> {
        Binding(
            get: { inferenceStore.selectedModelFallbackMessage != nil },
            set: { isPresented in
                if !isPresented {
                    inferenceStore.clearSelectedModelFallbackMessage()
                }
            }
        )
    }

    private var signInErrorPresentedBinding: Binding<Bool> {
        Binding(
            get: { inferenceStore.presentedErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    inferenceStore.clearPresentedError()
                }
            }
        )
    }

    private var storeErrorPresentedBinding: Binding<Bool> {
        Binding(
            get: { storePublisher.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    storePublisher.errorMessage = nil
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
