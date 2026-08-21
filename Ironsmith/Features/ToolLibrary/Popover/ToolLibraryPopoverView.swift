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
    @AppStorage(IronsmithPreferenceKeys.generatesIdentityForNewRemixes) private
        var generatesIdentityForNewRemixes = true
    @AppStorage(IronsmithPreferenceKeys.hasPresentedRemixIdentityNotice) private
        var hasPresentedRemixIdentityNotice = false
    #if DEBUG
        @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowWelcomeOnboarding)
        private var debugAlwaysShowWelcomeOnboarding = false
        @AppStorage(IronsmithPreferenceKeys.debugPopoverEmptyStateMode)
        private var debugPopoverEmptyStateModeRawValue = ToolLibraryDebugPopoverEmptyStateMode.off
            .rawValue
    #endif
    let appUpdateStore: AppUpdateStore
    private let welcomeOnboardingStore: WelcomeOnboardingStore
    private let remixMetadataClient: ToolGenerationPlanningClient
    @State private var toolLibraryStore = ToolLibraryStore()
    @State private var storePublisher: ToolLibraryStorePublisher
    @State private var detailsEditor: ToolAppDetailsEditorStore
    @State private var toolPendingDeletion: Tool?
    @State private var hasCheckedWelcomeOnboarding = false
    @State private var isShowingWelcomeOnboarding = false
    @State private var isShowingModelPicker = false
    @State private var isSigningInToIronsmith = false
    @State private var isSearchPresented = false
    @State private var isPromptExpanded = false
    @State private var searchText = ""
    @State private var detailsEditorToolIDPendingPresentation: UUID?
    @State private var detailsEditorPublishOriginToolID: UUID?
    @State private var publishToolIDPendingDetailsReturn: UUID?
    @State private var remixIdentityNoticeToolID: UUID?
    @State private var remixIdentityHandledToolIDs: Set<UUID> = []
    @State private var remixIdentityGeneratingToolID: UUID?
    @State private var remixIdentityGenerationOperationID: UUID?
    @State private var remixIdentityGenerationTask: Task<Void, Never>?
    @FocusState private var isPromptFocused: Bool

    @MainActor
    init() {
        appUpdateStore = AppUpdateStore()
        welcomeOnboardingStore = WelcomeOnboardingStore()
        remixMetadataClient = .live()
        _storePublisher = State(initialValue: ToolLibraryStorePublisher())
        _detailsEditor = State(initialValue: ToolAppDetailsEditorStore())
    }

    @MainActor
    init(
        appUpdateStore: AppUpdateStore,
        welcomeOnboardingStore: WelcomeOnboardingStore? = nil,
        storeClient: IronsmithStoreClient? = nil,
        iconClient: ToolIconClient = .cachedOnly(),
        iconEditingClient: ToolIconEditingClient? = nil,
        iconBuildClient: ToolBuildClient? = nil,
        remixMetadataClient: ToolGenerationPlanningClient? = nil
    ) {
        self.appUpdateStore = appUpdateStore
        self.welcomeOnboardingStore = welcomeOnboardingStore ?? WelcomeOnboardingStore()
        self.remixMetadataClient = remixMetadataClient ?? .live()
        let buildClient = iconBuildClient ?? .live()
        _storePublisher = State(
            initialValue: ToolLibraryStorePublisher(
                storeClient: storeClient ?? .live,
                iconClient: iconClient,
                buildClient: buildClient
            )
        )
        _detailsEditor = State(
            initialValue: ToolAppDetailsEditorStore(
                iconClient: iconEditingClient,
                buildClient: buildClient
            )
        )
    }

    var body: some View {
        sheetContent
    }

    private var lifecycleContent: some View {
        popoverLayout
        .padding(16)
        .frame(width: 340, height: 500)
        .accessibilityIdentifier("tool-library-root")
        .task(id: restoreAvailabilityRefreshID) {
            await toolLibraryStore.refreshRestoreAvailability(for: tools)
        }
        .task(id: storeSourceChangesRefreshID) {
            guard isStoreFeatureEnabled else { return }
            await storePublisher.refreshStoreSourceChanges(for: tools)
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
        .task(id: runningApplicationsRefreshID) {
            await toolLibraryStore.refreshRunningApplications(for: tools)
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
    }

    private var alertContent: some View {
        lifecycleContent
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
            "Ironsmith Store",
            isPresented: storeErrorPresentedBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storePublisher.errorMessage ?? "")
        }
        .alert(
            "Sign in to Publish",
            isPresented: storeSignInRequiredBinding
        ) {
            Button("Cancel", role: .cancel) {
                storePublisher.pendingSignInToolID = nil
            }
            Button("Sign In") {
                let toolID = storePublisher.pendingSignInToolID
                storePublisher.pendingSignInToolID = nil
                signInToIronsmith(resumePublishingToolID: toolID)
            }
        } message: {
            Text("Sign in with Ironsmith to publish this app to the Ironsmith Store.")
        }
        .alert(
            "Create a Unique Remix?",
            isPresented: remixIdentityNoticeBinding
        ) {
            Button("Skip Name & Icon", role: .cancel) {
                continuePendingRemixEdit(generateIdentity: false)
            }
            Button("Continue") {
                continuePendingRemixEdit(generateIdentity: true)
            }
        } message: {
            Text(
                "Ironsmith will generate a new name and icon so this remix has its own identity. "
                    + "It will do the same for future remixes. You can turn this off anytime in Settings."
            )
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
    }

    private var sheetContent: some View {
        @Bindable var storePublisher = storePublisher
        @Bindable var detailsEditor = detailsEditor

        return alertContent
        .sheet(
            isPresented: $isShowingWelcomeOnboarding,
            onDismiss: dismissWelcomeOnboardingPresentation
        ) {
            IronsmithWelcomeOnboardingSheetView(
                onComplete: completeWelcomeOnboarding
            )
        }
        .sheet(
            isPresented: $storePublisher.isShowingPublishSheet,
            onDismiss: handlePublishSheetDismissed
        ) {
            storePublishSheet
        }
        .sheet(isPresented: $storePublisher.isShowingCreatorProfileSheet) {
            ToolLibraryCreatorProfileSheetView(
                displayName: $storePublisher.creatorDisplayName,
                handle: $storePublisher.creatorHandle,
                errorMessage: $storePublisher.errorMessage,
                isSaving: storePublisher.isSavingCreatorProfile,
                isClaimingHandle:
                    inferenceStore.ironsmithAccountSummary?.profile?.handle == nil,
                onCancel: {
                    storePublisher.isShowingCreatorProfileSheet = false
                    storePublisher.pendingCreatorProfileToolID = nil
                },
                onSave: {
                    Task {
                        await storePublisher.saveCreatorProfile(
                            inferenceStore: inferenceStore,
                            tools: tools
                        )
                    }
                }
            )
        }
        .sheet(
            isPresented: $detailsEditor.isShowingSheet,
            onDismiss: handleDetailsEditorDismissed
        ) {
            detailsEditorSheet
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheetView()
        }
    }

    // The menu bar popover stays intentionally small: tool list first, prompt last.
    private var popoverLayout: some View {
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

            if !isPromptExpanded {
                ScrollView {
                    toolCollectionContent
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 14)
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
                .transition(.opacity)
            }

            PromptComposerView(
                prompt: $toolLibraryStore.prompt,
                isExpanded: $isPromptExpanded,
                sandboxEnabled: sandboxEnabledBinding,
                appKindPreference: appKindPreferenceBinding,
                sandboxPermissions: sandboxPermissionsBinding,
                resourcePermissions: resourcePermissionsBinding,
                codingAgentPreference: codingAgentPreferenceBinding,
                reasoningEffort: reasoningEffortBinding,
                placeholder: toolLibraryStore.promptPlaceholder,
                showsSandboxControl: showSandboxOverride,
                showsPermissionControls: !inferenceStore.generationPreferences
                    .automaticallySelectGeneratedAppPermissions,
                modelPickerTitle: composerModelPickerTitle,
                isModelPickerEnabled: isComposerModelPickerEnabled,
                isSubmitEnabled: canSubmitPrompt,
                isSubmitting: toolLibraryStore.isGenerating || remixIdentityGeneratingToolID != nil,
                isCodexAgentSupported: inferenceStore.selectedModelSupportsCodingAgentPreference(.codex),
                showsAttachmentControls: selectedModelCanUseCodexAttachments,
                supportsAttachments: selectedModelSupportsAttachments,
                attachments: toolLibraryStore.attachments,
                supportedReasoningEfforts: inferenceStore.selectedModelSupportedReasoningEfforts,
                isPromptFocused: $isPromptFocused,
                onChooseModel: {
                    isShowingModelPicker = true
                },
                onSubmit: {
                    requestPromptSubmission()
                },
                onCancel: {
                    if remixIdentityGeneratingToolID != nil {
                        cancelRemixIdentityGeneration()
                    } else {
                        toolLibraryStore.cancelGeneration()
                    }
                },
                onAddAttachments: { urls in
                    guard toolLibraryStore.addAttachments(from: urls) else { return }
                    inferenceStore.generationPreferences.codingAgentPreference =
                        ToolAttachmentSupport.preferenceAfterAddingAttachments(
                            inferenceStore.generationPreferences.codingAgentPreference
                        )
                },
                onRemoveAttachment: { id in
                    toolLibraryStore.removeAttachment(id: id)
                }
            )
            .frame(maxHeight: isPromptExpanded ? .infinity : nil)
        }
    }

    @ViewBuilder
    private var toolCollectionContent: some View {
        if shouldShowEmptyState {
            ToolLibraryEmptyStateView(
                showsNoModelActions: shouldShowNoModelsEmptyState,
                isSigningInToIronsmith: isSigningInToIronsmith,
                onSignInToIronsmith: {
                    signInToIronsmith()
                }
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

    private func collapsePromptIfNeeded() {
        guard isPromptExpanded else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            isPromptExpanded = false
        }
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
            isRunning: toolLibraryStore.isRunning(tool),
            isLaunching: toolLibraryStore.launchingToolID == tool.id,
            isExporting: toolLibraryStore.exportingToolID == tool.id,
            isRebuilding: toolLibraryStore.rebuildingToolID == tool.id,
            isRestoring: toolLibraryStore.restoringToolID == tool.id,
            isEditingDetails: detailsEditor.isWorking && detailsEditor.editingToolID == tool.id,
            isPreparingGeneration: remixIdentityGeneratingToolID == tool.id,
            canRevert: toolLibraryStore.canRestorePreviousVersion(tool),
            showsStoreActions: isStoreFeatureEnabled,
            canUpdateStoreVersion: canUpdateStoreVersion(for: tool),
            hasStoreSourceChanges: storePublisher.hasStoreSourceChanges(for: tool),
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
            onQuit: {
                Task {
                    await toolLibraryStore.quit(tool)
                }
            },
            onEditDetails: {
                detailsEditor.beginEditing(tool)
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
                if remixIdentityGeneratingToolID == tool.id {
                    cancelRemixIdentityGeneration()
                } else {
                    toolLibraryStore.cancelGeneration()
                }
            },
            onDelete: {
                toolPendingDeletion = tool
            }
        )
    }

    @ViewBuilder
    private var detailsEditorSheet: some View {
        @Bindable var detailsEditor = detailsEditor

        if let tool = tools.first(where: { $0.id == detailsEditor.editingToolID }) {
            ToolAppDetailsEditorSheetView(
                previewData: detailsEditor.previewData,
                name: $detailsEditor.name,
                prompt: $detailsEditor.prompt,
                imageProvider: inferenceStore.effectiveImageGenerationProvider,
                canSave: detailsEditor.canSave(tool),
                isGenerating: detailsEditor.isGenerating,
                isSaving: detailsEditor.isSaving,
                errorMessage: detailsEditor.errorMessage,
                onChooseImage: { url in
                    detailsEditor.importIcon(from: url)
                },
                onGenerate: {
                    let provider = inferenceStore.effectiveImageGenerationProvider
                    Task {
                        await detailsEditor.generate(for: tool, provider: provider)
                        if provider == .ironsmith {
                            await inferenceStore.refreshIronsmithAccountSummary()
                        }
                    }
                },
                onOpenSettings: {
                    routeStore.open(.settings(.root))
                },
                onCancel: {
                    detailsEditorPublishOriginToolID = nil
                    publishToolIDPendingDetailsReturn = nil
                    detailsEditor.cancel()
                },
                onSave: {
                    Task {
                        let shouldReturnToPublishing =
                            detailsEditorPublishOriginToolID == tool.id
                        if shouldReturnToPublishing {
                            publishToolIDPendingDetailsReturn = tool.id
                        }
                        let didSave = await detailsEditor.save(
                            tool,
                            in: modelContext,
                            rename: { renameTool(tool, to: $0) }
                        )
                        if didSave, tool.storeRemixedFromVersionId != nil {
                            remixIdentityHandledToolIDs.insert(tool.id)
                        }
                        if !didSave, shouldReturnToPublishing {
                            publishToolIDPendingDetailsReturn = nil
                        }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var storePublishSheet: some View {
        @Bindable var storePublisher = storePublisher

        if let tool = tools.first(where: { $0.id == storePublisher.publishingToolID }) {
            ToolLibraryStorePublishSheetView(
                tool: tool,
                isUpdatingPublishedListing: storePublisher.isUpdatingPublishedListing,
                publishShortDescription: $storePublisher.publishShortDescription,
                publishDescription: $storePublisher.publishDescription,
                publishCategory: $storePublisher.publishCategory,
                publishLicense: $storePublisher.publishLicense,
                publishScreenshotName: storePublisher.publishScreenshotName,
                publishIconPreviewData: storePublisher.publishIconPreviewData,
                creatorHandle: inferenceStore.ironsmithAccountSummary?.profile?.handle ?? "",
                inheritedLegalAttributions: storePublisher.publishInheritedLegalAttributions,
                publishNameMatchesOriginal: storePublisher.publishNameMatchesOriginal(
                    for: tool
                ),
                isUsingOriginalRemixIcon: storePublisher.isUsingOriginalRemixIcon,
                isPublishing: storePublisher.isPublishing,
                errorMessage: $storePublisher.errorMessage,
                onChooseScreenshot: { url in
                    storePublisher.importScreenshot(from: url)
                },
                onCancel: {
                    storePublisher.isShowingPublishSheet = false
                },
                onEditDetails: {
                    detailsEditorToolIDPendingPresentation = tool.id
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

    private func handlePublishSheetDismissed() {
        guard let toolID = detailsEditorToolIDPendingPresentation else { return }
        detailsEditorToolIDPendingPresentation = nil
        guard storePublisher.publishingToolID == toolID,
            let tool = tools.first(where: { $0.id == toolID })
        else { return }
        detailsEditorPublishOriginToolID = toolID
        detailsEditor.beginEditing(tool)
        if !detailsEditor.isShowingSheet {
            detailsEditorPublishOriginToolID = nil
        }
    }

    private func handleDetailsEditorDismissed() {
        defer {
            detailsEditorPublishOriginToolID = nil
            publishToolIDPendingDetailsReturn = nil
        }
        guard let toolID = publishToolIDPendingDetailsReturn,
            storePublisher.publishingToolID == toolID,
            let tool = tools.first(where: { $0.id == toolID })
        else { return }
        storePublisher.refreshPublishIdentity(for: tool)
        storePublisher.isShowingPublishSheet = true
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

    private var runningApplicationsRefreshID: String {
        let toolIDs = tools.map(\.id.uuidString).sorted().joined(separator: "|")
        return "\(menuBarPopoverPresentationStore.showCount)|\(toolIDs)"
    }

    private var storeSourceChangesRefreshID: [String] {
        [isStoreFeatureEnabled ? "store-on" : "store-off"]
            + tools.map {
                "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSinceReferenceDate)-\($0.storeSourceSha256 ?? "")"
            }
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
            && (toolLibraryStore.attachments.isEmpty || selectedModelSupportsAttachments)
    }

    private var attachmentResolutionContext: ToolCodingAgentResolutionContext {
        toolLibraryStore.currentCodingAgentResolutionContext(in: modelContext)
    }

    private var selectedModelSupportsAttachments: Bool {
        inferenceStore.selectedModelSupportsAttachments(
            resolutionContext: attachmentResolutionContext
        )
    }

    private var selectedModelCanUseCodexAttachments: Bool {
        inferenceStore.selectedModelCanUseCodexAttachments()
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

    private var appKindPreferenceBinding: Binding<ToolAppKindPreference> {
        Binding(
            get: { toolLibraryStore.appKindPreference },
            set: { toolLibraryStore.setAppKindPreference($0) }
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

    private func signInToIronsmith(resumePublishingToolID: UUID? = nil) {
        guard !isSigningInToIronsmith else { return }
        isSigningInToIronsmith = true

        Task {
            let didFinishProviderSetup = await inferenceStore.signInToIronsmithWithAppleOAuth { @MainActor url in
                try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: IronsmithOAuthRedirect.appCallbackScheme
                )
            }

            await MainActor.run {
                isSigningInToIronsmith = false
                guard didFinishProviderSetup else { return }
                inferenceStore.selectIronsmithModel(
                    identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier
                )
            }
            guard let resumePublishingToolID,
                inferenceStore.ironsmithSession != nil,
                let tool = tools.first(where: { $0.id == resumePublishingToolID })
            else { return }
            await storePublisher.beginPublishing(
                tool,
                inferenceStore: inferenceStore,
                tools: tools
            )
        }
    }

    private func continuePendingRemixEdit(generateIdentity: Bool) {
        let toolID = remixIdentityNoticeToolID
        remixIdentityNoticeToolID = nil
        hasPresentedRemixIdentityNotice = true
        generatesIdentityForNewRemixes = generateIdentity
        guard let toolID,
            let tool = tools.first(where: { $0.id == toolID })
        else { return }
        if generateIdentity {
            startRemixIdentityGeneration(for: tool)
        } else {
            submitCurrentPrompt()
        }
    }

    private func requestPromptSubmission() {
        guard inferenceStore.selectedModel != nil, !shouldForceNoModels else { return }
        guard let selectedToolID = toolLibraryStore.selectedToolID,
            let tool = tools.first(where: { $0.id == selectedToolID })
        else {
            submitCurrentPrompt()
            return
        }
        if remixIdentityHandledToolIDs.contains(tool.id) {
            submitCurrentPrompt()
            return
        }
        switch toolLibraryStore.remixIdentitySubmissionAction(
            for: tool,
            generatesIdentity: generatesIdentityForNewRemixes,
            hasPresentedNotice: hasPresentedRemixIdentityNotice
        ) {
        case .submit:
            submitCurrentPrompt()
        case .presentNotice:
            remixIdentityNoticeToolID = tool.id
        case .generateIdentity:
            startRemixIdentityGeneration(for: tool)
        }
    }

    private func startRemixIdentityGeneration(for tool: Tool) {
        guard remixIdentityGenerationTask == nil else { return }
        let operationID = UUID()
        remixIdentityGeneratingToolID = tool.id
        remixIdentityGenerationOperationID = operationID
        remixIdentityGenerationTask = Task {
            let didGenerate = await generateRemixIdentity(tool)
            let wasCancelled = Task.isCancelled
            finishRemixIdentityGeneration(operationID: operationID)
            guard didGenerate, !wasCancelled else { return }
            submitCurrentPrompt()
        }
    }

    private func cancelRemixIdentityGeneration() {
        remixIdentityGenerationTask?.cancel()
        remixIdentityGenerationTask = nil
        remixIdentityGeneratingToolID = nil
        remixIdentityGenerationOperationID = nil
    }

    private func finishRemixIdentityGeneration(operationID: UUID) {
        guard remixIdentityGenerationOperationID == operationID else { return }
        remixIdentityGenerationTask = nil
        remixIdentityGeneratingToolID = nil
        remixIdentityGenerationOperationID = nil
    }

    private func submitCurrentPrompt() {
        collapsePromptIfNeeded()
        if !showSandboxOverride {
            toolLibraryStore.sandboxEnabled = true
        }
        toolLibraryStore.startPromptSubmission(
            modelContext: modelContext,
            inferenceStore: inferenceStore
        )
    }

    private func generateRemixIdentity(_ tool: Tool) async -> Bool {
        do {
            try await inferenceStore.prepareSelectedModelForGeneration()
            let languageModelContext = try await inferenceStore.makeSelectedAgentLanguageModelContext(
                resolutionContext: ToolCodingAgentResolutionContext(
                    generationMode: .edit,
                    existingSourceLineCount: nil
                )
            )
            let sourceURL = try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let suggestion = await remixMetadataClient.planCreation(
                userPrompt: Self.remixIdentityPrompt(for: tool, source: source),
                imageGenerationProvider: inferenceStore.effectiveImageGenerationProvider,
                invoker: languageModelContext.languageModelInvoker
            )
            guard !Task.isCancelled else { return false }
            let generatedName = Self.distinctRemixName(
                suggestion.displayName,
                originalName: tool.name
            )
            let didSave = await detailsEditor.generateAndSaveRemixIdentity(
                for: tool,
                name: generatedName,
                iconPrompt: suggestion.iconPrompt,
                provider: inferenceStore.effectiveImageGenerationProvider,
                in: modelContext,
                rename: { renameTool(tool, to: $0) }
            )
            if inferenceStore.effectiveImageGenerationProvider == .ironsmith {
                await inferenceStore.refreshIronsmithAccountSummary()
            }
            if didSave {
                remixIdentityHandledToolIDs.insert(tool.id)
            }
            return didSave
        } catch {
            toolLibraryStore.presentedErrorMessage = IronsmithErrorPresentation.message(for: error)
            return false
        }
    }

    private func renameTool(_ tool: Tool, to proposedName: String) -> String? {
        guard toolLibraryStore.rename(tool, to: proposedName, in: modelContext) else {
            let message =
                toolLibraryStore.presentedErrorMessage
                ?? "Ironsmith could not rename this app."
            toolLibraryStore.clearPresentedError()
            return message
        }
        return nil
    }

    private static func remixIdentityPrompt(for tool: Tool, source: String) -> String {
        let sourceExcerpt = String(source.prefix(6_000))
        return """
            Create a fresh, distinctive identity for a remixed macOS app.
            Do not reuse the original name “\(tool.name)”. Suggest a different concise app name and a new icon concept that reflects what the app does.

            Category: \(tool.category.rawValue)
            Existing source:
            \(sourceExcerpt)
            """
    }

    private static func distinctRemixName(_ proposedName: String, originalName: String) -> String {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
            !StoreAppNameComparison.matches(trimmedName, originalName)
        else {
            return "Fresh \(originalName)"
        }
        return trimmedName
    }

    private func selectToolForEditing(_ tool: Tool, focusPrompt: Bool = true) {
        toolLibraryStore.selectForEditing(tool, defaultSettings: defaultGenerationSettings)
        isPromptFocused = focusPrompt
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
            get: {
                storePublisher.errorMessage != nil
                    && !storePublisher.isShowingPublishSheet
                    && !storePublisher.isShowingCreatorProfileSheet
            },
            set: { isPresented in
                if !isPresented {
                    storePublisher.errorMessage = nil
                }
            }
        )
    }

    private var storeSignInRequiredBinding: Binding<Bool> {
        Binding(
            get: { storePublisher.pendingSignInToolID != nil },
            set: { isPresented in
                if !isPresented {
                    storePublisher.pendingSignInToolID = nil
                }
            }
        )
    }

    private var remixIdentityNoticeBinding: Binding<Bool> {
        Binding(
            get: { remixIdentityNoticeToolID != nil },
            set: { isPresented in
                if !isPresented {
                    remixIdentityNoticeToolID = nil
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
