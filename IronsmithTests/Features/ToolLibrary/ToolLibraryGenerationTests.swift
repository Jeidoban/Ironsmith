import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func toolLibraryStoreSuppressesGenerationCancellationErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw CancellationError()
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a cancellable tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreSuppressesCancelledURLSessionGenerationErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorCancelled,
                        userInfo: [NSLocalizedDescriptionKey: "cancelled"]
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a cancellable tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreKeepsLateCanceledSuccessfulCreateReady() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("LateCreate", isDirectory: true)
        let gate = LateGenerationCompletionGate()
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Late Create",
                            executableName: "LateCreate",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "LateCreate"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    await gate.startAndWaitForRelease()
                    return ToolGenerationResult(
                        toolName: "Late Create",
                        executableName: "LateCreate",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )
        store.prompt = "Build a late finishing create"
        store.startPromptSubmission(modelContext: context, inferenceStore: inferenceStore)

        await gate.waitForStart()
        store.cancelGeneration()
        await gate.release()
        await Self.waitForIdle(store)

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        #expect(tool.generationState == .ready)
        #expect(tool.generationPhase == .completed)
        #expect(tool.generationMode == nil)
        #expect(tool.pendingPrompt == nil)
        #expect(store.presentedErrorMessage == nil)
        #expect(await notificationCapture.recorded().isEmpty)
    }

    @MainActor
    @Test
    func toolLibraryStoreKeepsLateCanceledSuccessfulResumeReady() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("LateResume", isDirectory: true)
        let tool = StoredTool(
            name: "Late Resume",
            executableName: "LateResume",
            packageRootPath: packageRoot.path,
            generationState: .stopped,
            generationPhase: .generatingSource,
            generationMode: .create,
            pendingPrompt: "Resume a late finishing app"
        )
        context.insert(tool)
        try context.save()

        let gate = LateGenerationCompletionGate()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    await gate.startAndWaitForRelease()
                    return ToolGenerationResult(
                        toolName: "Late Resume",
                        executableName: "LateResume",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.continueGeneration(tool, modelContext: context, inferenceStore: inferenceStore)

        await gate.waitForStart()
        store.cancelGeneration()
        await gate.release()
        await Self.waitForIdle(store)

        #expect(tool.generationState == .ready)
        #expect(tool.generationPhase == .completed)
        #expect(tool.generationMode == nil)
        #expect(tool.pendingPrompt == nil)
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreShowsNoModelMessageWhenGenerationHasNoSelectedModel() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.inferenceDependencies())
        let store = ToolLibraryStore()
        store.prompt = "Build a notes tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == InferenceMessages.noAvailableModels)
        #expect(store.presentedErrorAction == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreOffersCreditPurchaseWhenIronsmithCreditsAreExhausted() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 0)
            )
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    Issue.record("Generation should not start without credits.")
                    throw CancellationError()
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a dashboard"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == InferenceStoreError.insufficientIronsmithCredits.localizedDescription)
        #expect(store.presentedErrorAction == ToolLibraryPresentedErrorAction.buyIronsmithCredits)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreRewritesGenericAnyLanguageModelGenerationErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 12)
            )
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw NSError(domain: "AnyLanguageModel.AnyLanguageModelError", code: 0)
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a dashboard"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == "There was an error generating your app. Please try again.")
        #expect(store.presentedErrorAction == nil)
        #expect(!(store.isGenerating))
    }

    @Test
    func toolRowStatusUsesCodexWorkingTextOnlyForCodexOwnedPhases() {
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingSource,
                repairErrorCount: nil,
                activeCodingAgent: .codex
            ) == "Codex is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingEditDiff,
                repairErrorCount: nil,
                activeCodingAgent: .codex
            ) == "Codex is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingRepairDiff,
                repairErrorCount: 2,
                activeCodingAgent: .codex
            ) == "Codex is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .repairing,
                repairErrorCount: 2,
                activeCodingAgent: .codex
            ) == "Codex is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .packaging,
                repairErrorCount: nil,
                activeCodingAgent: .codex
            ) == "Packaging"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingSource,
                repairErrorCount: nil,
                activeCodingAgent: .ironsmithFlame
            ) == "Generating source"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .repairing,
                repairErrorCount: 2,
                activeCodingAgent: nil
            ) == "Repairing 2 errors"
        )
    }

    @MainActor
    @Test
    func toolLibraryStoreEnablesAgentOutputForExistingCodexTranscript() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("TranscriptTool", isDirectory: true)
        let transcriptDirectory = CodexAgentTranscriptReader.transcriptDirectoryURL(for: packageRoot)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let tool = StoredTool(
            name: "Transcript Tool",
            executableName: "TranscriptTool",
            packageRootPath: packageRoot.path
        )
        let store = ToolLibraryStore()

        #expect(!store.canShowAgentOutput(for: tool))

        try #"{"type":"thread.started","thread_id":"thread-1"}"#
            .write(
                to: transcriptDirectory.appendingPathComponent("agent-test.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        #expect(store.canShowAgentOutput(for: tool))
    }

    @MainActor
    @Test
    func toolLibraryStoreTracksActiveCodexAgentDuringCreateGeneration() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let preferences = GenerationPreferencesStore(userDefaults: try Self.makeIsolatedUserDefaults())
        preferences.codingAgentPreference = .codex
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let model = ModelConfig(
            identifier: "codex:gpt-5.5",
            displayName: "GPT-5.5 (Codex)",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let packageRoot = root.appendingPathComponent("ActiveCodex", isDirectory: true)
        let capture = ToolLibraryActiveAgentCapture()
        var store: ToolLibraryStore!
        store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Active Codex",
                            executableName: "ActiveCodex",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "ActiveCodex"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    await capture.record(
                        store.activeCodingAgentByToolID.values.contains(.codex)
                    )
                    return ToolGenerationResult(
                        toolName: "Active Codex",
                        executableName: "ActiveCodex",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build with Codex"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(await capture.sawActiveCodex)
        #expect(store.activeCodingAgentByToolID.isEmpty)
    }

    @MainActor
    @Test
    func toolLibraryStoreRefreshesIronsmithCreditsAfterEachModelInvocation() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let accountCapture = IronsmithAccountFetchCapture(balances: [100, 91, 84, 84])
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(fetchCapture: accountCapture)
            )
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let packageRoot = URL(fileURLWithPath: "/tmp/ironsmith-credit-refresh", isDirectory: true)
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Credit Tool",
                            executableName: "CreditTool",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "CreditTool"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    await request.languageModelContext.languageModelInvoker.recordInvocationCompleted()
                    await request.languageModelContext.languageModelInvoker.recordInvocationCompleted()
                    return ToolGenerationResult(
                        toolName: "Credit Tool",
                        executableName: "CreditTool",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a credit watching tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(await accountCapture.fetchCount == 4)
        #expect(inferenceStore.ironsmithAccountSummary?.credits.balanceCredits == 84)
        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreNotifiesWhenGenerationFinishes() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("FinishedTool", isDirectory: true)
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Finished Tool",
                            executableName: "FinishedTool",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "FinishedTool"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    return ToolGenerationResult(
                        toolName: "Finished Tool",
                        executableName: "FinishedTool",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )
        store.prompt = "Build a finished tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let notifications = await notificationCapture.recorded()
        #expect(
            notifications == [
                ToolGenerationNotification(
                    kind: .finished,
                    toolName: "Finished Tool",
                    detail: nil
                )
            ]
        )
    }

    @MainActor
    @Test
    func toolLibraryStoreDoesNotNotifyWhenGenerationFinishesWhilePopoverIsVisible() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("VisibleTool", isDirectory: true)
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Visible Tool",
                            executableName: "VisibleTool",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "VisibleTool"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    return ToolGenerationResult(
                        toolName: "Visible Tool",
                        executableName: "VisibleTool",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )
        store.setPopoverVisible(true)
        store.prompt = "Build a visible tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(await notificationCapture.recorded().isEmpty)
    }

    @MainActor
    @Test
    func toolLibraryStorePresentsMessageForResumableTokenStop() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("TokenStop", isDirectory: true)
        let message = "Stopped after 6 repair attempts preserve tokens. Continue to keep repairing from current source."
        let tool = StoredTool(
            name: "Token Stop",
            executableName: "TokenStop",
            packageRootPath: packageRoot.path,
            generationState: .stopped,
            generationPhase: .generatingRepairDiff,
            generationMode: .edit,
            pendingPrompt: "Continue repairing"
        )
        context.insert(tool)
        try context.save()

        let gate = LateGenerationCompletionGate()
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    await gate.startAndWaitForRelease()
                    throw ToolGenerationError.stoppedToSaveTokens(message)
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )

        store.continueGeneration(tool, modelContext: context, inferenceStore: inferenceStore)
        await gate.waitForStart()
        await gate.release()
        await Self.waitForIdle(store)

        #expect(tool.generationState == .stopped)
        #expect(tool.generationErrorSummary == message)
        #expect(store.presentedErrorMessage == message)
        #expect(store.presentedErrorAction == nil)
        #expect(
            await notificationCapture.recorded() == [
                ToolGenerationNotification(
                    kind: .stopped,
                    toolName: "Token Stop",
                    detail: message
                )
            ]
        )
    }
}

private actor ToolGenerationNotificationCapture {
    private var notifications: [ToolGenerationNotification] = []

    func record(_ notification: ToolGenerationNotification) {
        notifications.append(notification)
    }

    func recorded() -> [ToolGenerationNotification] {
        notifications
    }
}

private actor ToolLibraryActiveAgentCapture {
    private(set) var sawActiveCodex = false

    func record(_ isActiveCodex: Bool) {
        sawActiveCodex = sawActiveCodex || isActiveCodex
    }
}

private actor LateGenerationCompletionGate {
    private var isStarted = false
    private var isReleased = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func startAndWaitForRelease() async {
        isStarted = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForStart() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

extension ToolLibraryTests {
    @MainActor
    static func waitForIdle(_ store: ToolLibraryStore) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while store.isGenerating && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
