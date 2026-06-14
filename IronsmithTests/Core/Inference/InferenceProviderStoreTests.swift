import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @MainActor
    @Test
    func remoteProviderModelsAreTransientAfterDiscovery() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["gpt-test"])
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let didAdd = await inferenceStore.addProvider(
            choice: .init(descriptor: ProviderCatalog.descriptor(for: .openAI)!),
            apiKey: "test-key"
        )

        let persistedModels = try context.fetch(FetchDescriptor<ModelConfig>())
        #expect(didAdd)
        #expect(inferenceStore.remoteModels.map(\.identifier) == ["gpt-test"])
        #expect(persistedModels.allSatisfy { $0.source != .remote })
    }

    @MainActor
    @Test
    func inferenceStoreLoadsSeedDataThroughRepository() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.dependencies())

        await inferenceStore.loadIfNeeded(modelContext: context)

        #expect(inferenceStore.providers.contains { $0.identifier == ProviderConfig.localProviderIdentifier })
        #expect(inferenceStore.remoteModels.isEmpty)
    }

    @MainActor
    @Test
    func loadIfNeededIsIdempotentWhenLaunchAndSettingsBothCallIt() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let counter = RemoteDiscoveryCounter()
        context.insert(ProviderCatalog.makeProvider(for: .openAI)!)
        try context.save()

        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                remoteModelIDs: ["gpt-test"],
                remoteDiscoveryHook: {
                    await counter.increment()
                }
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        await inferenceStore.loadIfNeeded(modelContext: context)

        #expect(await counter.count == 1)
        #expect(inferenceStore.remoteModels.map(\.identifier) == ["gpt-test"])
    }

    @MainActor
    @Test
    func inferenceStoreAddsEditsAndDeletesProvider() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["claude-test"])
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let didAdd = await inferenceStore.addProvider(
            choice: .init(descriptor: ProviderCatalog.descriptor(for: .anthropic)!),
            apiKey: "first-key"
        )
        let provider = try #require(inferenceStore.providers.first { $0.kind == .anthropic })

        let didSave = await inferenceStore.saveProviderEdits(provider: provider, apiKey: "second-key")

        let fetchedProviders = try context.fetch(FetchDescriptor<ProviderConfig>())
        let savedProvider = try #require(fetchedProviders.first { $0.kind == .anthropic })
        #expect(didAdd)
        #expect(didSave)
        #expect(savedProvider.identifier == provider.identifier)

        inferenceStore.removeProvider(provider)

        #expect(!(inferenceStore.providers.contains { $0.kind == .anthropic }))
        #expect(inferenceStore.remoteModels.isEmpty)
    }

    @MainActor
    @Test
    func inferenceStoreCanAddMultipleCustomOpenAICompatibleProviders() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["llama3.1:8b"])
        )

        await inferenceStore.loadIfNeeded(modelContext: context)

        let customChoice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .customOpenAICompatible)!
        )
        let didAddLocal = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "",
            displayName: "Local Ollama",
            baseURLString: "http://localhost:11434/v1"
        )
        let didAddRouter = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "router-key",
            displayName: "Router",
            baseURLString: "https://openrouter.ai/api/v1"
        )

        let customProviders = inferenceStore.providers.filter { $0.kind == .customOpenAICompatible }

        #expect(didAddLocal)
        #expect(didAddRouter)
        #expect(customProviders.count == 2)
        #expect(Set(customProviders.map(\.identifier)).count == 2)
        #expect(customProviders.allSatisfy { $0.origin == .custom })
        #expect(inferenceStore.remoteModels.contains { $0.identifier == "llama3.1:8b" })
    }

    @MainActor
    @Test
    func inferenceStoreRejectsUnsafeConfigurableProviderBaseURLs() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.dependencies())

        await inferenceStore.loadIfNeeded(modelContext: context)

        let customChoice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .customOpenAICompatible)!
        )
        let didAddRemoteHTTP = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "",
            displayName: "Remote HTTP",
            baseURLString: "http://example.com/v1"
        )
        let didAddFileURL = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "",
            displayName: "File URL",
            baseURLString: "file:///tmp/model"
        )

        #expect(!(didAddRemoteHTTP))
        #expect(!(didAddFileURL))
        #expect(inferenceStore.providers.allSatisfy { $0.kind != .customOpenAICompatible })

        let didAddLocal = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "",
            displayName: "Local",
            baseURLString: "http://localhost:11434/v1"
        )
        let provider = try #require(inferenceStore.providers.first { $0.kind == .customOpenAICompatible })
        let didSaveRemoteHTTP = await inferenceStore.saveProviderEdits(
            provider: provider,
            apiKey: "",
            displayName: "Remote HTTP",
            baseURLString: "http://example.com/v1"
        )

        #expect(didAddLocal)
        #expect(!(didSaveRemoteHTTP))
        #expect(provider.displayName == "Local")
        #expect(provider.baseURLString == "http://localhost:11434/v1")
    }

    @MainActor
    @Test
    func inferenceStoreEditsCustomOpenAICompatibleConnectionDetails() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["qwen2.5-coder"])
        )

        await inferenceStore.loadIfNeeded(modelContext: context)

        let customChoice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .customOpenAICompatible)!
        )
        let didAdd = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "",
            displayName: "Local Ollama",
            baseURLString: "http://localhost:11434/v1"
        )
        let provider = try #require(inferenceStore.providers.first { $0.kind == .customOpenAICompatible })
        let didSave = await inferenceStore.saveProviderEdits(
            provider: provider,
            apiKey: "",
            displayName: "Local LM Studio",
            baseURLString: "http://localhost:1234/v1"
        )

        let savedProvider = try #require(inferenceStore.providers.first { $0.identifier == provider.identifier })
        #expect(didAdd)
        #expect(didSave)
        #expect(savedProvider.displayName == "Local LM Studio")
        #expect(savedProvider.baseURLString == "http://localhost:1234/v1")
        #expect(inferenceStore.remoteModels.contains { $0.identifier == "qwen2.5-coder" })
    }

    @MainActor
    @Test
    func customOpenAICompatibleConnectionFailuresShowOnProviderCard() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteDiscoveryError: URLError(.cannotConnectToHost))
        )

        await inferenceStore.loadIfNeeded(modelContext: context)

        let customChoice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .customOpenAICompatible)!
        )
        let didAdd = await inferenceStore.addProvider(
            choice: customChoice,
            apiKey: "",
            displayName: "Local Server",
            baseURLString: "http://localhost:1234/v1"
        )
        let provider = try #require(inferenceStore.providers.first { $0.kind == .customOpenAICompatible })

        #expect(didAdd)
        #expect(inferenceStore.presentedErrorMessage == nil)
        #expect(inferenceStore.connectionIssue(for: provider)?.message == "Could not connect to the server.")
        #expect(!(inferenceStore.remoteModels.contains { $0.providerIdentifier == provider.identifier }))
    }

    @MainActor
    @Test
    func inferenceStoreAddsAndEditsOllamaWithoutAPIKey() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["gemma4:e2b"], ollamaInstalled: true)
        )

        await inferenceStore.loadIfNeeded(modelContext: context)

        let choice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .ollama)!
        )
        let didAdd = await inferenceStore.addProvider(
            choice: choice,
            apiKey: "",
            baseURLString: ""
        )
        let provider = try #require(inferenceStore.providers.first { $0.kind == .ollama })
        let didSave = await inferenceStore.saveProviderEdits(
            provider: provider,
            apiKey: "ollama-key",
            baseURLString: "http://localhost:11435"
        )

        let savedProvider = try #require(inferenceStore.providers.first { $0.identifier == ProviderKind.ollama.rawValue })
        #expect(didAdd)
        #expect(didSave)
        #expect(savedProvider.displayName == "Ollama")
        #expect(savedProvider.baseURLString == "http://localhost:11435")
        #expect(inferenceStore.remoteModels.contains { $0.identifier == "gemma4:e2b" })
        #expect(inferenceStore.apiKey(for: savedProvider) == "ollama-key")
    }

    @MainActor
    @Test
    func inferenceStoreRejectsLocalOllamaProviderWhenOllamaIsNotInstalled() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.dependencies(ollamaInstalled: false))

        await inferenceStore.loadIfNeeded(modelContext: context)

        let choice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .ollama)!
        )
        let didAdd = await inferenceStore.addProvider(
            choice: choice,
            apiKey: "",
            baseURLString: "http://localhost:11434"
        )

        #expect(!didAdd)
        #expect(inferenceStore.presentedErrorMessage == "Install Ollama before adding it as a provider.")
        #expect(!(inferenceStore.providers.contains { $0.kind == .ollama }))
        #expect(!(try context.fetch(FetchDescriptor<ProviderConfig>()).contains { $0.kind == .ollama }))
    }

    @MainActor
    @Test
    func inferenceStoreAllowsInstalledLocalOllamaProviderWhenServerIsNotRunning() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                remoteDiscoveryError: URLError(.cannotConnectToHost),
                ollamaInstalled: true
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)

        let choice = InferenceStore.ProviderChoice(
            descriptor: ProviderCatalog.descriptor(for: .ollama)!
        )
        let didAdd = await inferenceStore.addProvider(
            choice: choice,
            apiKey: "",
            baseURLString: "http://localhost:11434"
        )
        let provider = try #require(inferenceStore.providers.first { $0.kind == .ollama })

        #expect(didAdd)
        #expect(inferenceStore.presentedErrorMessage == nil)
        #expect(inferenceStore.connectionIssue(for: provider)?.message == "Could not connect to Ollama.")
        #expect(try context.fetch(FetchDescriptor<ProviderConfig>()).contains { $0.kind == .ollama })
    }

    @MainActor
    @Test
    func ollamaConnectionFailureCanStartServerAndRefreshModels() async throws {
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["gemma4:e2b"])
        )
        inferenceStore.providers = [provider]
        inferenceStore.providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
            message: "Could not connect to Ollama."
        )

        inferenceStore.startOllama(for: provider)

        await Self.eventually(timeoutNanoseconds: 2_000_000_000) {
            inferenceStore.remoteModels.contains { $0.identifier == "gemma4:e2b" }
                && !inferenceStore.isStartingOllama(provider)
        }

        #expect(inferenceStore.connectionIssue(for: provider) == nil)
        #expect(inferenceStore.remoteModels.first?.providerIdentifier == provider.identifier)
    }

    @MainActor
    @Test
    func ollamaStartPollsUntilServerResponds() async throws {
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let discoveryScript = RemoteDiscoveryScript([
            .failure(URLError(.cannotConnectToHost)),
            .success(["gemma4:e2b"]),
        ])
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteDiscoveryScript: discoveryScript)
        )
        inferenceStore.providers = [provider]
        inferenceStore.providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
            message: "Could not connect to Ollama."
        )

        inferenceStore.startOllama(for: provider)

        await Self.eventually(timeoutNanoseconds: 2_000_000_000) {
            inferenceStore.remoteModels.contains { $0.identifier == "gemma4:e2b" }
                && !inferenceStore.isStartingOllama(provider)
        }

        #expect(await discoveryScript.count == 2)
        #expect(inferenceStore.connectionIssue(for: provider) == nil)
    }

    @MainActor
    @Test
    func ollamaCanOnlyBeStartedForLocalServerURLs() throws {
        let inferenceStore = InferenceStore(dependencies: Self.dependencies())
        let provider = ProviderCatalog.makeProvider(for: .ollama)!

        provider.baseURLString = "http://localhost:11434"
        #expect(inferenceStore.canStartOllama(for: provider))

        provider.baseURLString = "http://127.0.0.1:11434"
        #expect(inferenceStore.canStartOllama(for: provider))

        provider.baseURLString = "http://[::1]:11434"
        #expect(inferenceStore.canStartOllama(for: provider))

        provider.baseURLString = "https://example.com"
        #expect(!(inferenceStore.canStartOllama(for: provider)))

        let customProvider = ProviderCatalog.makeProvider(for: .customOpenAICompatible)!
        customProvider.baseURLString = "http://localhost:1234/v1"
        #expect(!(inferenceStore.canStartOllama(for: customProvider)))
    }

    @MainActor
    @Test
    func availableProviderChoicesAlwaysIncludeCustomOpenAICompatible() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.dependencies(ollamaInstalled: true))

        await inferenceStore.loadIfNeeded(modelContext: context)

        #expect(inferenceStore.availableProviderChoices.contains { $0.kind == .customOpenAICompatible })

        for choice in inferenceStore.availableProviderChoices where choice.kind != .customOpenAICompatible {
            _ = await inferenceStore.addProvider(choice: choice, apiKey: "test-key")
        }

        #expect(inferenceStore.availableProviderChoices.map(\.kind) == [.customOpenAICompatible])
    }
}
