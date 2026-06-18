import SwiftData
import SwiftUI

struct ToolLibraryPopoverView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @Environment(MenuBarPopoverPresentationStore.self) private var menuBarPopoverPresentationStore
    @Query(sort: \Tool.updatedAt, order: .reverse) private var tools: [Tool]
    @AppStorage(IronsmithPreferenceKeys.showSandboxOverride) private var showSandboxOverride = false
    #if DEBUG
    @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowWelcomeOnboarding)
    private var debugAlwaysShowWelcomeOnboarding = false
    #endif
    let appUpdateStore: AppUpdateStore
    private let welcomeOnboardingStore: WelcomeOnboardingStore
    @State private var toolLibraryStore = ToolLibraryStore()
    @State private var toolPendingDeletion: Tool?
    @State private var hasCheckedWelcomeOnboarding = false
    @State private var isShowingWelcomeOnboarding = false

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
                isLoadingModels: !inferenceStore.hasLoadedModels,
                shouldShowNoModelMessage: shouldShowNoModelMessage,
                selectedModelStatusText: selectedModelStatusText,
                selectedIronsmithCreditWarningText: selectedIronsmithCreditWarningText,
                onOpenSettings: {
                    routeStore.open(.settings(.root))
                }
            )

            ScrollView {
                LazyVStack(spacing: 10) {
                    if tools.isEmpty {
                        ToolLibraryEmptyStateView()
                    } else {
                        ForEach(tools) { tool in
                            // Clicking the row selects edit mode; the context menu
                            // keeps secondary actions out of the main flow.
                            ToolRowView(
                                tool: tool,
                                isSelected: toolLibraryStore.isSelected(tool),
                                isRunning: toolLibraryStore.runningToolID == tool.id,
                                isExporting: toolLibraryStore.exportingToolID == tool.id,
                                canRevert: toolLibraryStore.canRestorePreviousVersion(tool),
                                onSelect: {
                                    toolLibraryStore.toggleSelection(for: tool)
                                },
                                onRun: {
                                    Task {
                                        await toolLibraryStore.run(tool)
                                    }
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
                sandboxEnabled: $toolLibraryStore.sandboxEnabled,
                placeholder: toolLibraryStore.promptPlaceholder,
                showsSandboxToggle: showSandboxOverride,
                isSubmitEnabled: canSubmitPrompt,
                isSubmitting: toolLibraryStore.isGenerating,
                onSubmit: {
                    guard inferenceStore.selectedModel != nil else { return }
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
            presentWelcomeOnboardingIfNeeded()
        }
        .onDisappear {
            pauseWelcomeOnboardingPresentation()
        }
        .onChange(of: menuBarPopoverPresentationStore.showCount) { _, _ in
            if shouldAlwaysShowWelcomeOnboarding {
                hasCheckedWelcomeOnboarding = false
            }
            presentWelcomeOnboardingIfNeeded()
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
            toolLibraryStore.syncSelection(with: tools)
        }
        .onChange(of: showSandboxOverride) { _, isEnabled in
            if !isEnabled {
                toolLibraryStore.sandboxEnabled = true
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
        .sheet(
            isPresented: $isShowingWelcomeOnboarding,
            onDismiss: dismissWelcomeOnboardingPresentation
        ) {
            IronsmithWelcomeOnboardingSheetView(
                onComplete: completeWelcomeOnboarding
            )
        }
    }

    private var restoreAvailabilityRefreshID: [String] {
        tools.map { "\($0.id.uuidString)-\($0.updatedAt.timeIntervalSinceReferenceDate)" }
    }

    private var canSubmitPrompt: Bool {
        toolLibraryStore.canSubmitPrompt && inferenceStore.selectedModel != nil
    }

    private var selectedModelStatusText: String? {
        guard let selectedModelDisplayName else {
            return nil
        }

        if let selectedIronsmithCreditsText {
            return "Using \(selectedModelDisplayName) - \(selectedIronsmithCreditsText)"
        }

        return "Using \(selectedModelDisplayName)"
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
        ToolLibraryCreditWarning.message(
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

    private func openIronsmithCreditPurchase() {
        toolLibraryStore.clearPresentedError()
        routeStore.open(.settings(.buyIronsmithCredits))
    }

    private var shouldShowNoModelMessage: Bool {
        inferenceStore.hasLoadedModels && inferenceStore.selectedModel == nil
    }

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
