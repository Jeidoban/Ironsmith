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
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
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
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
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
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    Issue.record("Generation should not start without credits.")
                    throw CancellationError()
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a dashboard"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == InferenceStoreError.insufficientIronsmithCredits.localizedDescription)
        #expect(store.presentedErrorAction == .buyIronsmithCredits)
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
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
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
                generationClient: ToolGenerationClient { _, _, _, _, _, languageModelContext, _ in
                    await languageModelContext.afterLanguageModelInvocation()
                    await languageModelContext.afterLanguageModelInvocation()
                    return ToolGenerationResult(
                        toolName: "Credit Tool",
                        executableName: "CreditTool",
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
