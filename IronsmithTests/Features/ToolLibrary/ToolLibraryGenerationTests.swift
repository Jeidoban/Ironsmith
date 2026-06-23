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
        let inferenceStore = InferenceStore(dependencies: Self.inferenceDependencies())
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
        let inferenceStore = InferenceStore(dependencies: Self.inferenceDependencies())
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
        let inferenceStore = InferenceStore(dependencies: Self.inferenceDependencies())
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("LateCreate", isDirectory: true)
        let manifest = ToolManifest(displayName: "Late Create", executableName: "LateCreate", files: [])
        let gate = LateGenerationCompletionGate()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Late Create",
                            executableName: "LateCreate",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "LateCreate"),
                            settings: request.settings,
                            packageRootURL: packageRoot,
                            manifest: manifest
                        ),
                        request.prompt
                    )
                    await gate.startAndWaitForRelease()
                    return ToolGenerationResult(
                        toolName: "Late Create",
                        executableName: "LateCreate",
                        settings: request.settings,
                        packageRootURL: packageRoot,
                        manifest: manifest
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
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
    }

    @MainActor
    @Test
    func toolLibraryStoreKeepsLateCanceledSuccessfulResumeReady() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.inferenceDependencies())
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("LateResume", isDirectory: true)
        let manifest = ToolManifest(displayName: "Late Resume", executableName: "LateResume", files: [])
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
                        packageRootURL: packageRoot,
                        manifest: manifest
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
                            packageRootURL: packageRoot,
                            manifest: ToolManifest(displayName: "Credit Tool", executableName: "CreditTool", files: [])
                        ),
                        request.prompt
                    )
                    await request.languageModelContext.afterLanguageModelInvocation()
                    await request.languageModelContext.afterLanguageModelInvocation()
                    return ToolGenerationResult(
                        toolName: "Credit Tool",
                        executableName: "CreditTool",
                        settings: request.settings,
                        packageRootURL: packageRoot,
                        manifest: ToolManifest(displayName: "Credit Tool", executableName: "CreditTool", files: [])
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
