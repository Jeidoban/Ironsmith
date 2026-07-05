import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @MainActor
    @Test
    func openAIModelsDefaultToLargeModelPatchRepairStrategy() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let model = ModelConfig(
            identifier: "gpt-test",
            displayName: "GPT Test",
            providerIdentifier: ProviderKind.openAI.rawValue,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [model]
        store.selectedModelID = model.selectionIdentifier

        let context = try await store.makeSelectedAgentLanguageModelContext()
        #expect(context.pipelineConfiguration.profile == .largeModel)
        #expect(
            context.repairStrategy == .modelSearchReplace(
                maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
            )
        )
    }

    @MainActor
    @Test
    func ollamaModelsDefaultToSmallModelPatchRepairStrategy() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let model = ModelConfig(
            identifier: "gemma4:e2b",
            displayName: "Gemma 4 E2B",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [model]
        store.selectedModelID = model.selectionIdentifier

        let context = try await store.makeSelectedAgentLanguageModelContext()
        #expect(context.pipelineConfiguration.profile == .smallModel)
        #expect(context.repairStrategy == .modelSearchReplace(maxPatchBlocksPerTurn: 3))
    }

    @MainActor
    @Test
    func customOpenAICompatibleModelsDefaultToSmallModelPatchRepairStrategy() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .customOpenAICompatible)!
        let model = ModelConfig(
            identifier: "qwen2.5-coder",
            displayName: "Qwen Coder",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [model]
        store.selectedModelID = model.selectionIdentifier

        let context = try await store.makeSelectedAgentLanguageModelContext()
        #expect(context.pipelineConfiguration.profile == .smallModel)
        #expect(context.repairStrategy == .modelSearchReplace(maxPatchBlocksPerTurn: 3))
    }

    @MainActor
    @Test
    func ironsmithGenerationRequiresAvailableCredits() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        store.providers = [provider]
        store.remoteModels = [model]
        store.selectedModelID = model.selectionIdentifier
        store.ironsmithSession = Self.ironsmithSession()
        store.ironsmithAccountSummary = Self.ironsmithAccountSummary(balanceCredits: 0)

        do {
            _ = try await store.makeSelectedAgentLanguageModelContext()
            Issue.record("Expected zero-credit Ironsmith generation to fail before model creation.")
        } catch {
            #expect(error.localizedDescription == "Your AI credits have run out. Buy more below, or switch to a local or API-key model to keep going.")
        }
    }

    @MainActor
    @Test
    func languageModelClientBuildsOllamaLanguageModel() async throws {
        let credentialBox = CredentialBox()
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        provider.baseURLString = "http://localhost:11435"
        credentialBox.values[provider.apiKeyReference!] = "ollama-key"
        let model = ModelConfig(
            identifier: "gemma4:e2b",
            displayName: "Gemma 4 E2B",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let client = LanguageModelClient.live(
            credentialClient: CredentialClient(
                loadAPIKey: { reference in credentialBox.values[reference] },
                saveAPIKey: { apiKey, reference in credentialBox.values[reference] = apiKey },
                deleteAPIKey: { reference in credentialBox.values.removeValue(forKey: reference) }
            ),
            localModelClient: Self.fakeLocalModelClient()
        )

        let languageModel = try await client.makeLanguageModel(model, provider)
        let ollamaModel = try #require(languageModel as? OllamaLanguageModel)

        #expect(ollamaModel.model == "gemma4:e2b")
        #expect(ollamaModel.baseURL.absoluteString == "http://localhost:11435/")
    }

    @MainActor
    @Test
    func languageModelClientBuildsOpenAICodexLanguageModel() async throws {
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let model = ModelConfig(
            identifier: "codex:gpt-5.5",
            displayName: "GPT-5.5 (Codex)",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let authClient = OpenAICodexAuthClient(
            credential: {
                OpenAICodexCredential(accessToken: "codex-token", accountID: "account-id")
            },
            signIn: {
                OpenAICodexCredential(accessToken: "codex-token", accountID: "account-id")
            },
            signOut: {},
            validCredential: {
                OpenAICodexCredential(accessToken: "codex-token", accountID: "account-id")
            },
            discoverModels: { [] }
        )
        let client = LanguageModelClient.live(
            credentialClient: CredentialClient(
                loadAPIKey: { _ in nil },
                saveAPIKey: { _, _ in },
                deleteAPIKey: { _ in }
            ),
            localModelClient: Self.fakeLocalModelClient(),
            openAICodexAuthClient: authClient
        )

        let languageModel = try await client.makeLanguageModel(model, provider)
        let openAIModel = try #require(languageModel as? OpenAILanguageModel)

        #expect(openAIModel.model == "gpt-5.5")
        #expect(openAIModel.baseURL == OpenAICodexBackend.backendBaseURL)
    }

    @MainActor
    @Test
    func openAICodexGenerationOptionsOmitMaxTokensAndDisableStorage() {
        let model = ModelConfig(
            identifier: "codex:gpt-5.5",
            displayName: "GPT-5.5 (Codex)",
            providerIdentifier: ProviderKind.openAI.rawValue,
            source: .remote,
            installState: .installed
        )

        let options = model.generationOptions(preferences: Self.generationPreferences())
        let openAIOptions = options[custom: OpenAILanguageModel.self]

        #expect(options.maximumResponseTokens == nil)
        #expect(openAIOptions?.store == false)

        let customPreferences = Self.generationPreferences()
        customPreferences.customOptionsEnabled = true
        customPreferences.maximumResponseTokens = 8192

        let customOptions = model.generationOptions(preferences: customPreferences)
        #expect(customOptions.maximumResponseTokens == nil)
    }

    @MainActor
    @Test
    func openAICodexGenerationOptionsSanitizerRemovesUnsupportedParameters() {
        let languageModel = OpenAILanguageModel(
            baseURL: OpenAICodexBackend.backendBaseURL,
            apiKey: "token",
            model: "gpt-5.5",
            apiVariant: .responses
        )
        var options = GenerationOptions(maximumResponseTokens: 8192)
        var openAIOptions = OpenAILanguageModel.CustomGenerationOptions()
        openAIOptions.store = true
        options[custom: OpenAILanguageModel.self] = openAIOptions

        let sanitized = OpenAICodexGenerationOptions.sanitized(options, for: languageModel)

        #expect(sanitized.maximumResponseTokens == nil)
        #expect(sanitized[custom: OpenAILanguageModel.self]?.store == false)
    }

    @MainActor
    @Test
    func openAICodexGenerationOptionsSanitizerLeavesNormalOpenAIOptionsUnchanged() {
        let languageModel = OpenAILanguageModel(
            baseURL: OpenAILanguageModel.defaultBaseURL,
            apiKey: "token",
            model: "gpt-5.5",
            apiVariant: .responses
        )
        var options = GenerationOptions(maximumResponseTokens: 8192)
        var openAIOptions = OpenAILanguageModel.CustomGenerationOptions()
        openAIOptions.store = true
        options[custom: OpenAILanguageModel.self] = openAIOptions

        let sanitized = OpenAICodexGenerationOptions.sanitized(options, for: languageModel)

        #expect(sanitized.maximumResponseTokens == 8192)
        #expect(sanitized[custom: OpenAILanguageModel.self]?.store == true)
    }

    @MainActor
    @Test
    func selectionIdentifierWorksForPersistedAndTransientModels() {
        let localModel = ModelConfig(
            identifier: ModelConfig.appleFoundationIdentifier,
            displayName: "Apple Foundation Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .appleFoundation,
            installState: .builtIn
        )
        let remoteModel = ModelConfig(
            identifier: "gpt-test",
            displayName: "gpt-test",
            providerIdentifier: ProviderKind.openAI.rawValue,
            source: .remote,
            installState: .installed
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(),
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        inferenceStore.providers = [
            ProviderCatalog.makeProvider(for: .local)!,
            ProviderCatalog.makeProvider(for: .openAI)!,
        ]
        inferenceStore.persistedModels = [localModel]
        inferenceStore.remoteModels = [remoteModel]
        inferenceStore.selectedModelID = remoteModel.selectionIdentifier

        #expect(localModel.selectionIdentifier == "\(ProviderConfig.localProviderIdentifier)::\(ModelConfig.appleFoundationIdentifier)")
        #expect(remoteModel.selectionIdentifier == "\(ProviderKind.openAI.rawValue)::gpt-test")
        #expect(inferenceStore.availableModels.count == 1)
        #expect(!(inferenceStore.availableModels.contains { $0.source == .appleFoundation }))
        #expect(inferenceStore.selectedModel?.identifier == "gpt-test")

        inferenceStore.setAppleFoundationModelEnabled(true)

        #expect(inferenceStore.availableModels.count == 2)
        #expect(inferenceStore.availableModels.contains { $0.source == .appleFoundation })
    }

    @MainActor
    @Test
    func localProviderModelsHideAppleFoundationUntilEnabled() throws {
        let localProvider = try #require(ProviderCatalog.makeProvider(for: .local))
        let foundationModel = ModelConfig(
            identifier: ModelConfig.appleFoundationIdentifier,
            displayName: "Apple Foundation Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .appleFoundation,
            installState: .builtIn
        )
        let mlxModel = ModelConfig(
            identifier: "local-test-model",
            displayName: "Local Test Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(),
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        inferenceStore.providers = [localProvider]
        inferenceStore.persistedModels = [foundationModel, mlxModel]

        #expect(inferenceStore.models(for: localProvider).map(\.identifier) == [mlxModel.identifier])

        inferenceStore.setAppleFoundationModelEnabled(true)

        #expect(
            inferenceStore.models(for: localProvider).map(\.identifier) == [
                ModelConfig.appleFoundationIdentifier,
                mlxModel.identifier,
            ]
        )
    }

    @MainActor
    @Test
    func modelSelectionPersistsAcrossStoreInstances() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let selection = Self.modelSelection()
        let firstStore = InferenceStore(
            dependencies: Self.dependencies(),
            modelSelection: selection
        )

        await firstStore.loadIfNeeded(modelContext: context)
        let mlxModel = ModelConfig(
            identifier: "local-test-model",
            displayName: "Local Test Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )
        context.insert(mlxModel)
        try context.save()
        try firstStore.refreshData()

        firstStore.selectModel(mlxModel.selectionIdentifier)

        let secondStore = InferenceStore(
            dependencies: Self.dependencies(),
            modelSelection: selection
        )
        await secondStore.loadIfNeeded(modelContext: context)

        #expect(secondStore.selectedModelID == mlxModel.selectionIdentifier)
        #expect(secondStore.selectedModel?.identifier == mlxModel.identifier)
    }

    @MainActor
    @Test
    func remoteModelSelectionSurvivesReloadAfterDiscovery() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        context.insert(provider)
        try context.save()

        let remoteSelectionID = "\(provider.identifier)::gpt-test"
        let selection = Self.modelSelection()
        selection.selectedModelID = remoteSelectionID
        let store = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: ["gpt-test"]),
            modelSelection: selection
        )

        await store.loadIfNeeded(modelContext: context)

        #expect(store.selectedModelID == remoteSelectionID)
        #expect(store.selectedModel?.identifier == "gpt-test")
        #expect(store.selectedModel?.source == .remote)
        #expect(selection.selectedModelID == remoteSelectionID)
    }

    @MainActor
    @Test
    func invalidPersistedModelSelectionClearsWhenNoEnabledModelIsAvailable() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let selection = Self.modelSelection()
        selection.selectedModelID = "missing::model"
        let store = InferenceStore(
            dependencies: Self.dependencies(),
            modelSelection: selection,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )

        await store.loadIfNeeded(modelContext: context)

        #expect(store.selectedModel == nil)
        #expect(store.selectedModelID == nil)
        #expect(selection.selectedModelID == nil)
        #expect(store.selectedModelFallbackMessage?.contains("AI model") == true)

        await store.prepareSettings(modelContext: context)
        #expect(store.selectedModelFallbackMessage?.contains("AI model") == true)

        store.selectModel(store.selectedModelID)
        #expect(store.selectedModelFallbackMessage == nil)
    }

    @MainActor
    @Test
    func invalidPersistedModelSelectionFallsBackToFirstEnabledModel() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let selection = Self.modelSelection()
        selection.selectedModelID = "missing::model"
        let mlxModel = ModelConfig(
            identifier: "local-test-model",
            displayName: "Local Test Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )
        context.insert(mlxModel)
        try context.save()
        let store = InferenceStore(
            dependencies: Self.dependencies(),
            modelSelection: selection,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )

        await store.loadIfNeeded(modelContext: context)

        #expect(store.selectedModelID == mlxModel.selectionIdentifier)
        #expect(store.selectedModel?.identifier == mlxModel.identifier)
        #expect(selection.selectedModelID == mlxModel.selectionIdentifier)
        #expect(store.selectedModelFallbackMessage?.contains("first available AI model") == true)
    }

    @MainActor
    @Test
    func selectIronsmithModelSelectsMatchingRemoteModel() throws {
        let store = InferenceStore(
            dependencies: Self.dependencies(),
            modelSelection: Self.modelSelection()
        )
        let provider = try #require(ProviderCatalog.makeProvider(for: .ironsmith))
        let deepSeekModel = ModelConfig(
            identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier,
            displayName: "DeepSeek V4 Flash",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [deepSeekModel]

        #expect(store.selectIronsmithModel(identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier))
        #expect(store.selectedModelID == deepSeekModel.selectionIdentifier)
        #expect(store.modelSelection.selectedModelID == deepSeekModel.selectionIdentifier)
    }

    @MainActor
    @Test
    func selectIronsmithModelLeavesSelectionUnchangedWhenUnavailable() throws {
        let store = InferenceStore(
            dependencies: Self.dependencies(),
            modelSelection: Self.modelSelection()
        )
        let provider = try #require(ProviderCatalog.makeProvider(for: .ironsmith))
        let selectedModel = ModelConfig(
            identifier: "openai/gpt-5",
            displayName: "GPT-5",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [selectedModel]
        store.selectModel(selectedModel.selectionIdentifier)

        #expect(!store.selectIronsmithModel(identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier))
        #expect(store.selectedModelID == selectedModel.selectionIdentifier)
        #expect(store.modelSelection.selectedModelID == selectedModel.selectionIdentifier)
    }

    @MainActor
    @Test
    func settingsPreparationRefreshesServerProviderConnectionState() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let discoveryScript = RemoteDiscoveryScript([
            .success(["gemma4:e2b"]),
            .failure(URLError(.cannotConnectToHost)),
        ])
        let store = InferenceStore(
            dependencies: Self.dependencies(remoteDiscoveryScript: discoveryScript)
        )

        context.insert(provider)
        try context.save()

        await store.loadIfNeeded(modelContext: context)
        await Self.eventually {
            store.remoteModels.contains { $0.identifier == "gemma4:e2b" }
        }
        #expect(store.remoteModels.contains { $0.identifier == "gemma4:e2b" })
        #expect(store.connectionIssue(for: provider) == nil)

        await store.prepareSettings(modelContext: context)

        #expect(await discoveryScript.count == 2)
        #expect(!(store.remoteModels.contains { $0.providerIdentifier == provider.identifier }))
        #expect(store.connectionIssue(for: provider)?.message == "Could not connect to Ollama.")
    }

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func localModelDownloadSuccessUpdatesPersistedModel() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let entry = MLXModelCatalog.all[0]
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(downloadResult: .success(URL(fileURLWithPath: "/tmp/\(entry.identifier)")))
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        inferenceStore.downloadFromCatalog(entry)

        await Self.eventually {
            inferenceStore.persistedModels.contains {
                $0.identifier == entry.identifier && $0.installState == .installed
            }
        }

        let model = try #require(inferenceStore.persistedModels.first { $0.identifier == entry.identifier })
        #expect(model.localDirectoryPath != nil)
        #expect(model.downloadProgress == 1)
    }

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func localModelDownloadFailureRemovesPersistedModel() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let entry = MLXModelCatalog.all[0]
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(downloadResult: .failure(FakeInferenceError.expected))
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        inferenceStore.downloadFromCatalog(entry)

        await Self.eventually {
            inferenceStore.presentedErrorMessage != nil
        }

        #expect(!(inferenceStore.persistedModels.contains { $0.identifier == entry.identifier }))
    }

    @MainActor
    @Test
    func ollamaRecommendedModelPullRefreshesTransientModels() async throws {
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let entry = OllamaModelCatalog.all[0]
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                remoteModelIDs: [entry.identifier],
                ollamaPullProgresses: [
                    OllamaPullProgress(status: "pulling manifest", completed: nil, total: nil),
                    OllamaPullProgress(status: "pulling layers", completed: 50, total: 100),
                ]
            )
        )
        inferenceStore.providers = [provider]

        inferenceStore.pullOllamaRecommendedModel(entry, provider: provider)

        await Self.eventually(timeoutNanoseconds: 5_000_000_000) {
            inferenceStore.ollamaPullStates.isEmpty &&
                inferenceStore.remoteModels.contains { $0.identifier == entry.identifier }
        }

        #expect(inferenceStore.ollamaPullStates.isEmpty)
        #expect(inferenceStore.remoteModels.first?.providerIdentifier == provider.identifier)
    }

    @MainActor
    @Test
    func ollamaRecommendedModelPullStartsLocalOllamaWhenUnavailable() async throws {
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        provider.baseURLString = "http://localhost:11434"
        let entry = OllamaModelCatalog.all[0]
        let discoveryScript = RemoteDiscoveryScript([
            .failure(URLError(.cannotConnectToHost)),
            .success([entry.identifier]),
            .success([entry.identifier]),
        ])
        let operationRecorder = OllamaOperationRecorder()
        var dependencies = Self.dependencies(remoteDiscoveryScript: discoveryScript)
        dependencies.ollamaClient = OllamaClient(
            isInstalled: { true },
            startServer: {
                await operationRecorder.record("start")
            },
            pullModel: { _, _, _, _ in
                await operationRecorder.record("pull")
            },
            deleteModel: { _, _, _ in }
        )
        let inferenceStore = InferenceStore(dependencies: dependencies)
        inferenceStore.providers = [provider]

        inferenceStore.pullOllamaRecommendedModel(entry, provider: provider)

        await Self.eventually(timeoutNanoseconds: 2_000_000_000) {
            inferenceStore.ollamaPullStates.isEmpty &&
                inferenceStore.remoteModels.contains { $0.identifier == entry.identifier }
        }

        #expect(await operationRecorder.events == ["start", "pull"])
        #expect(await discoveryScript.count == 3)
        #expect(inferenceStore.connectionIssue(for: provider) == nil)
    }

    @MainActor
    @Test
    func ollamaPullProgressKeepsLastFractionForStatusOnlyUpdates() async throws {
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let entry = OllamaModelCatalog.all[0]
        var dependencies = Self.dependencies(remoteModelIDs: [entry.identifier])
        dependencies.ollamaClient = OllamaClient(
            isInstalled: { true },
            startServer: {},
            pullModel: { _, _, _, progress in
                progress(OllamaPullProgress(status: "pulling layers", completed: 50, total: 100))
                progress(OllamaPullProgress(status: "verifying digest", completed: nil, total: nil))
                try await Task.sleep(nanoseconds: 100_000_000)
            },
            deleteModel: { _, _, _ in }
        )
        let inferenceStore = InferenceStore(dependencies: dependencies)
        inferenceStore.providers = [provider]
        let key = inferenceStore.ollamaModelTransferKey(provider: provider, modelIdentifier: entry.identifier)

        inferenceStore.pullOllamaRecommendedModel(entry, provider: provider)

        await Self.eventually {
            inferenceStore.ollamaPullStates[key] == OllamaModelTransferState(
                status: "verifying digest",
                progress: 0.5
            )
        }

        #expect(inferenceStore.ollamaPullStates[key]?.progress == 0.5)
        await Self.eventually {
            inferenceStore.ollamaPullStates.isEmpty
        }
    }

    @MainActor
    @Test
    func ollamaRecommendedModelDeleteRefreshesTransientModels() async throws {
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        let entry = OllamaModelCatalog.all[0]
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(remoteModelIDs: [])
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [
            ModelConfig(
                identifier: entry.identifier,
                displayName: entry.displayName,
                providerIdentifier: provider.identifier,
                source: .remote,
                installState: .installed
            )
        ]

        inferenceStore.deleteOllamaRecommendedModel(entry, provider: provider)

        await Self.eventually {
            inferenceStore.ollamaDeletingModelKeys.isEmpty && inferenceStore.remoteModels.isEmpty
        }

        #expect(inferenceStore.ollamaDeletingModelKeys.isEmpty)
        #expect(inferenceStore.remoteModels.isEmpty)
    }
}

private actor OllamaOperationRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}
