import AnyLanguageModel
import Foundation
import JSONSchema
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @MainActor
    @Test
    func imageGenerationProviderDefaultsToAutomaticAndPersists() {
        let suiteName = "IronsmithTests.ImageGenerationProvider.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(preferences.imageGenerationProvider == .automatic)

        preferences.imageGenerationProvider = .gemini
        #expect(
            GenerationPreferencesStore(userDefaults: userDefaults).imageGenerationProvider == .gemini
        )
    }

    @MainActor
    @Test
    func unavailableImageProviderReconcilesToAutomatic() {
        let preferences = Self.generationPreferences()
        preferences.imageGenerationProvider = .gemini
        let store = Self.dependenciesBackedStore(generationPreferences: preferences)
        store.providers = []

        #expect(!store.availableImageGenerationProviders.contains(.gemini))
        store.reconcileImageGenerationProvider()

        #expect(preferences.imageGenerationProvider == .automatic)
    }

    @MainActor
    @Test
    func startupPreservesCodexBackedOpenAIImageProviderSelection() async throws {
        let preferences = Self.generationPreferences()
        preferences.imageGenerationProvider = .openAI
        let credential = OpenAICodexCredential(accessToken: "codex-token")
        let authClient = OpenAICodexAuthClient(
            credential: { credential },
            signIn: { credential },
            signOut: {},
            validCredential: { credential },
            discoverModels: { [] }
        )
        let store = InferenceStore(
            dependencies: Self.dependencies(openAICodexAuthClient: authClient),
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let modelContext = ModelContext(container)
        modelContext.insert(ProviderCatalog.makeProvider(for: .openAI)!)
        try modelContext.save()

        await store.loadIfNeeded(modelContext: modelContext)

        #expect(store.hasOpenAICodexCredential)
        #expect(preferences.imageGenerationProvider == .openAI)
    }

    @MainActor
    @Test
    func automaticImageProviderMatchesSelectedModelProvider() throws {
        let preferences = Self.generationPreferences()
        let dependencies = Self.dependencies()
        let store = InferenceStore(
            dependencies: dependencies,
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        let openAI = ProviderCatalog.makeProvider(for: .openAI)!
        let gemini = ProviderCatalog.makeProvider(for: .gemini)!
        let ironsmith = ProviderCatalog.makeProvider(for: .ironsmith)!
        try dependencies.credentialClient.saveAPIKey("openai-key", openAI.apiKeyReference!)
        try dependencies.credentialClient.saveAPIKey("gemini-key", gemini.apiKeyReference!)
        store.providers = [openAI, gemini, ironsmith]
        store.ironsmithSession = Self.ironsmithSession()
        store.remoteModels = [
            Self.imageProviderTestModel(provider: openAI),
            Self.imageProviderTestModel(provider: gemini),
            Self.imageProviderTestModel(provider: ironsmith),
        ]

        store.selectModel(store.remoteModels[0].selectionIdentifier)
        #expect(store.effectiveImageGenerationProvider == .openAI)

        store.selectModel(store.remoteModels[1].selectionIdentifier)
        #expect(store.effectiveImageGenerationProvider == .gemini)

        store.selectModel(store.remoteModels[2].selectionIdentifier)
        #expect(store.effectiveImageGenerationProvider == .ironsmith)
    }

    @MainActor
    @Test
    func automaticImageProviderUsesFallbackOrderForUnsupportedModelProvider() throws {
        let preferences = Self.generationPreferences()
        let dependencies = Self.dependencies()
        let store = InferenceStore(
            dependencies: dependencies,
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        let openAI = ProviderCatalog.makeProvider(for: .openAI)!
        let gemini = ProviderCatalog.makeProvider(for: .gemini)!
        let ironsmith = ProviderCatalog.makeProvider(for: .ironsmith)!
        let anthropic = ProviderCatalog.makeProvider(for: .anthropic)!
        try dependencies.credentialClient.saveAPIKey("openai-key", openAI.apiKeyReference!)
        try dependencies.credentialClient.saveAPIKey("gemini-key", gemini.apiKeyReference!)
        store.providers = [openAI, gemini, ironsmith, anthropic]
        store.ironsmithSession = Self.ironsmithSession()
        store.openAICodexCredential = OpenAICodexCredential(accessToken: "codex-token")
        let selectedModel = Self.imageProviderTestModel(provider: anthropic)
        store.remoteModels = [selectedModel]
        store.selectModel(selectedModel.selectionIdentifier)

        #expect(store.effectiveImageGenerationProvider == .openAI)

        store.openAICodexCredential = nil
        #expect(store.effectiveImageGenerationProvider == .openAI)

        try dependencies.credentialClient.deleteAPIKey(openAI.apiKeyReference!)
        #expect(store.effectiveImageGenerationProvider == .gemini)

        try dependencies.credentialClient.deleteAPIKey(gemini.apiKeyReference!)
        let expected: ToolImageGenerationProvider = store.availableImageGenerationProviders.contains(
            .imagePlayground
        ) ? .imagePlayground : .ironsmith
        #expect(store.effectiveImageGenerationProvider == expected)
    }

    @MainActor
    @Test
    func manuallySelectedImageProviderOverridesAutomaticMatching() throws {
        let preferences = Self.generationPreferences()
        preferences.imageGenerationProvider = .gemini
        let dependencies = Self.dependencies()
        let store = InferenceStore(
            dependencies: dependencies,
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        let gemini = ProviderCatalog.makeProvider(for: .gemini)!
        let ironsmith = ProviderCatalog.makeProvider(for: .ironsmith)!
        try dependencies.credentialClient.saveAPIKey("gemini-key", gemini.apiKeyReference!)
        store.providers = [gemini, ironsmith]
        store.ironsmithSession = Self.ironsmithSession()
        let selectedModel = Self.imageProviderTestModel(provider: ironsmith)
        store.remoteModels = [selectedModel]
        store.selectModel(selectedModel.selectionIdentifier)

        #expect(store.effectiveImageGenerationProvider == .gemini)
    }

    @MainActor
    @Test
    func availableImageProvidersUseAutomaticFallbackOrder() throws {
        let store = Self.dependenciesBackedStore()
        let openAI = ProviderCatalog.makeProvider(for: .openAI)!
        let gemini = ProviderCatalog.makeProvider(for: .gemini)!
        let ironsmith = ProviderCatalog.makeProvider(for: .ironsmith)!
        try store.dependencies.credentialClient.saveAPIKey("openai-key", openAI.apiKeyReference!)
        try store.dependencies.credentialClient.saveAPIKey("gemini-key", gemini.apiKeyReference!)
        store.providers = [ironsmith, gemini, openAI]
        store.ironsmithSession = Self.ironsmithSession()

        var expected: [ToolImageGenerationProvider] = [.automatic, .openAI, .gemini]
        if store.availableImageGenerationProviders.contains(.imagePlayground) {
            expected.append(.imagePlayground)
        }
        expected.append(contentsOf: [.ironsmith, .disabled])

        #expect(store.availableImageGenerationProviders == expected)
    }

    private static func imageProviderTestModel(provider: ProviderConfig) -> ModelConfig {
        ModelConfig(
            identifier: "\(provider.identifier)-image-test",
            displayName: "Image Test",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
    }

    @MainActor
    @Test
    func generatedPromptRefinementPreferenceDefaultsEnabledAndPersists() {
        let suiteName = "IronsmithTests.GeneratedPromptRefinement.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(preferences.generatedPromptRefinementEnabled == true)

        preferences.generatedPromptRefinementEnabled = false
        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(!(reloadedPreferences.generatedPromptRefinementEnabled))
    }

    @MainActor
    @Test
    func codingAgentPreferenceDefaultsAutomaticAndPersists() {
        let suiteName = "IronsmithTests.ToolCodingAgent.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(preferences.codingAgentPreference == .automatic)

        preferences.codingAgentPreference = .ironsmithFlame

        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(reloadedPreferences.codingAgentPreference == .ironsmithFlame)

        reloadedPreferences.codingAgentPreference = .codex

        let reloadedCodexPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(reloadedCodexPreferences.codingAgentPreference == .codex)
    }

    @MainActor
    @Test
    func reasoningEffortDefaultsAndPersists() {
        let suiteName = "IronsmithTests.ReasoningEffort.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(preferences.reasoningEffort == .default)

        preferences.reasoningEffort = .xhigh
        #expect(GenerationPreferencesStore(userDefaults: userDefaults).reasoningEffort == .xhigh)
    }

    @MainActor
    @Test
    func reasoningSupportUsesProviderSpecificCapabilities() {
        let openAI = ProviderCatalog.makeProvider(for: .openAI)!
        let gpt = ModelConfig(
            identifier: "gpt-5.5",
            displayName: "GPT-5.5",
            providerIdentifier: openAI.identifier,
            source: .remote,
            installState: .installed
        )
        #expect(ToolReasoningSupport.supportedEfforts(for: gpt, provider: openAI) == [
            .low, .medium, .high, .xhigh,
        ])

        let gptPro = ModelConfig(
            identifier: "gpt-5-pro-2025-10-06",
            displayName: "GPT-5 Pro",
            providerIdentifier: openAI.identifier,
            source: .remote,
            installState: .installed
        )
        #expect(ToolReasoningSupport.supportedEfforts(for: gptPro, provider: openAI) == [.high])

        let custom = ProviderCatalog.makeProvider(for: .customOpenAICompatible)!
        #expect(ToolReasoningSupport.supportedEfforts(for: gpt, provider: custom) == ToolReasoningEffort.explicitCases)

        let gemini = ProviderCatalog.makeProvider(for: .gemini)!
        #expect(ToolReasoningSupport.supportedEfforts(for: gpt, provider: gemini).isEmpty)
    }

    @MainActor
    @Test
    func reasoningOptionsUseProviderWireShape() {
        let openAI = ProviderCatalog.makeProvider(for: .openAI)!
        let openAIModel = ModelConfig(
            identifier: "gpt-5.5",
            displayName: "GPT-5.5",
            providerIdentifier: openAI.identifier,
            source: .remote,
            installState: .installed
        )
        let languageModel = OpenAILanguageModel(
            apiKey: "token",
            model: openAIModel.identifier,
            apiVariant: .responses
        )
        let openAIOptions = ToolGenerationOptionsResolver.options(
            for: .codingAgent,
            model: openAIModel,
            provider: openAI,
            languageModel: languageModel,
            reasoningEffort: .xhigh
        )
        #expect(
            openAIOptions[custom: OpenAILanguageModel.self]?.extraBody?["reasoning"]
                == .object(["effort": .string("xhigh")])
        )

        let custom = ProviderCatalog.makeProvider(for: .customOpenAICompatible)!
        custom.openAICompatibleAPIVariant = .chatCompletions
        let customOptions = ToolGenerationOptionsResolver.options(
            for: .codingAgent,
            model: openAIModel,
            provider: custom,
            languageModel: nil,
            reasoningEffort: .max
        )
        #expect(
            customOptions[custom: OpenAILanguageModel.self]?.extraBody?["reasoning_effort"]
                == .string("max")
        )

        let anthropic = ProviderCatalog.makeProvider(for: .anthropic)!
        let claude = ModelConfig(
            identifier: "claude-opus-test",
            displayName: "Claude Opus",
            providerIdentifier: anthropic.identifier,
            source: .remote,
            installState: .installed,
            reasoningEfforts: [.low, .medium, .high, .max]
        )
        let anthropicOptions = ToolGenerationOptionsResolver.options(
            for: .codingAgent,
            model: claude,
            provider: anthropic,
            languageModel: nil,
            reasoningEffort: .max
        )
        #expect(
            anthropicOptions[custom: AnthropicLanguageModel.self]?.extraBody?["output_config"]
                == .object(["effort": .string("max")])
        )

        let defaultOptions = ToolGenerationOptionsResolver.options(
            for: .codingAgent,
            model: openAIModel,
            provider: openAI,
            languageModel: languageModel,
            reasoningEffort: .default
        )
        #expect(defaultOptions[custom: OpenAILanguageModel.self]?.extraBody?["reasoning"] == nil)
    }

    @MainActor
    @Test
    func unsupportedReasoningEffortResetsToDefault() {
        let preferences = Self.generationPreferences()
        preferences.reasoningEffort = .xhigh
        let store = Self.dependenciesBackedStore(generationPreferences: preferences)
        let gemini = ProviderCatalog.makeProvider(for: .gemini)!
        let model = ModelConfig(
            identifier: "gemini-test",
            displayName: "Gemini",
            providerIdentifier: gemini.identifier,
            source: .remote,
            installState: .installed
        )
        store.providers = [gemini]
        store.remoteModels = [model]

        store.selectModel(model.selectionIdentifier)

        #expect(preferences.reasoningEffort == .default)
    }

    @MainActor
    @Test
    func codingAgentPreferencePreservesLegacySmallAndLargeRawValues() {
        let suiteName = "IronsmithTests.ToolCodingAgentLegacy.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        userDefaults.set("small_model", forKey: "generation.agentPipelineProfile")
        #expect(GenerationPreferencesStore(userDefaults: userDefaults).codingAgentPreference == .ironsmithSpark)

        userDefaults.set("large_model", forKey: "generation.agentPipelineProfile")
        #expect(GenerationPreferencesStore(userDefaults: userDefaults).codingAgentPreference == .ironsmithFlame)
    }

    @MainActor
    @Test
    func generatedAppResourcePermissionPreferencesDefaultOffAndPersist() {
        let suiteName = "IronsmithTests.GeneratedAppResourcePermissions.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        for permission in GeneratedAppResourcePermission.allCases {
            #expect(!(preferences.isGeneratedAppResourcePermissionEnabled(permission)))
        }
        #expect(preferences.generatedAppResourcePermissions == .none)

        preferences.setGeneratedAppResourcePermission(.microphone, enabled: true)
        preferences.setGeneratedAppResourcePermission(.photoLibrary, enabled: true)
        preferences.setGeneratedAppResourcePermission(.appleEvents, enabled: true)

        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(reloadedPreferences.generatedAppResourcePermissions.enabled == [.microphone, .photoLibrary, .appleEvents])
        #expect(!(reloadedPreferences.isGeneratedAppResourcePermissionEnabled(.camera)))
    }

    @MainActor
    @Test
    func generatedAppSandboxPermissionPreferencesDefaultOnAndPersist() {
        let suiteName = "IronsmithTests.GeneratedAppSandboxPermissions.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        for permission in GeneratedAppSandboxPermission.allCases {
            #expect(preferences.isGeneratedAppSandboxPermissionEnabled(permission))
        }
        #expect(preferences.generatedAppSandboxPermissions == .default)

        preferences.setGeneratedAppSandboxPermission(.internet, enabled: false)

        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(!(reloadedPreferences.isGeneratedAppSandboxPermissionEnabled(.internet)))
        #expect(reloadedPreferences.isGeneratedAppSandboxPermissionEnabled(.userSelectedFiles))
        #expect(reloadedPreferences.generatedAppSandboxPermissions.enabled == [.userSelectedFiles])
    }

    @Test
    func generatedAppResourcePermissionWarningsOnlyForSensitiveResources() {
        #expect(GeneratedAppResourcePermission.contacts.enablementWarningMessage != nil)
        #expect(GeneratedAppResourcePermission.calendar.enablementWarningMessage != nil)
        #expect(GeneratedAppResourcePermission.photoLibrary.enablementWarningMessage != nil)
        #expect(GeneratedAppResourcePermission.appleEvents.enablementWarningMessage != nil)
        #expect(GeneratedAppResourcePermission.microphone.enablementWarningMessage == nil)
        #expect(GeneratedAppResourcePermission.camera.enablementWarningMessage == nil)
        #expect(GeneratedAppResourcePermission.location.enablementWarningMessage == nil)
    }

    @MainActor
    @Test
    func selectedAgentLanguageModelContextCarriesPromptRefinementPreference() async throws {
        let preferences = Self.generationPreferences()
        preferences.generatedPromptRefinementEnabled = false
        preferences.codingAgentPreference = .ironsmithFlame
        let store = Self.dependenciesBackedStore(generationPreferences: preferences)
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

        #expect(!(context.promptRefinementEnabled))
    }

    @MainActor
    @Test
    func selectedAgentLanguageModelContextUsesSelectedModelForEveryStage() async throws {
        let context = try await Self.agentLanguageModelContext(providerKind: .anthropic)

        #expect(context.codingAgent.languageModel is InferenceTestLanguageModel)
        #expect(context.promptRefinement.languageModel is InferenceTestLanguageModel)
        #expect(context.metadata.languageModel is InferenceTestLanguageModel)
    }

    @MainActor
    @Test
    func selectedAgentLanguageModelContextAppliesStageBudgets() async throws {
        let context = try await Self.agentLanguageModelContext(providerKind: .openAI)

        #expect(context.codingAgent.generationOptions.maximumResponseTokens == ToolGenerationOptionsResolver.globalMaximumResponseTokens)
        #expect(context.promptRefinement.generationOptions.maximumResponseTokens == ToolGenerationOptionsResolver.promptRefinementMaximumResponseTokens)
        #expect(context.metadata.generationOptions.maximumResponseTokens == ToolGenerationOptionsResolver.metadataMaximumResponseTokens)
        #expect(context.codingAgent.streaming)
        #expect(context.promptRefinement.streaming)
        #expect(context.metadata.streaming)
    }

    @MainActor
    @Test
    func modelGenerationOptionsDelegateToCodingAgentDefaults() throws {
        let preferences = Self.generationPreferences()
        let model = ModelConfig(
            identifier: "gpt-test",
            displayName: "GPT Test",
            providerIdentifier: ProviderKind.openAI.rawValue,
            source: .remote,
            installState: .installed
        )

        let options = model.generationOptions(preferences: preferences)

        #expect(options.temperature == nil)
        #expect(options.maximumResponseTokens == ToolGenerationOptionsResolver.globalMaximumResponseTokens)
    }

    @MainActor
    @Test
    func ollamaCatalogGroupsModelsByMemoryRequirement() {
        #expect(OllamaModelCatalog.sections.map(\.title) == [
            "8 GB RAM",
            "16 GB RAM",
            "24 GB RAM",
            "32 GB RAM",
            "48 GB RAM",
        ])
        #expect(OllamaModelCatalog.sections.map { $0.entries.map(\.identifier) } == [
            ["gemma4:e2b"],
            ["gemma4:e4b-it-q8_0", "gemma4:12b"],
            ["gemma4:12b-it-q8_0", "gemma4:26b"],
            ["qwen3.6:35b", "gemma4:26b-a4b-it-q8_0"],
            ["qwen3.6:35b-a3b-q8_0"],
        ])
    }

    @MainActor
    @Test
    func appleFoundationUsesDeterministicOnlyRepairStrategy() async throws {
        let store = InferenceStore(
            dependencies: Self.dependencies(),
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore(isEnabled: true)
        )
        let provider = ProviderCatalog.makeProvider(for: .local)!
        let model = ModelConfig(
            identifier: ModelConfig.appleFoundationIdentifier,
            displayName: "Apple Foundation Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .appleFoundation,
            installState: .builtIn
        )

        store.providers = [provider]
        store.persistedModels = [model]
        store.selectedModelID = model.selectionIdentifier

        let context = try await store.makeSelectedAgentLanguageModelContext()
        #expect(context.repairStrategy == .deterministicOnly)
    }

    @MainActor
    @Test
    func explicitToolCodingAgentOverridesAutomaticProviderDefault() async throws {
        let preferences = Self.generationPreferences()
        preferences.codingAgentPreference = .ironsmithFlame
        let store = Self.dependenciesBackedStore(generationPreferences: preferences)
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
        #expect(context.pipelineConfiguration.codingAgent == .ironsmithFlame)
        #expect(
            context.repairStrategy == .modelSearchReplace(
                maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
            )
        )
    }

    @MainActor
    @Test
    func selectedOpenAICodexModelUsesCodexAgentAndChatGPTAuthenticationWhenRequested() async throws {
        let preferences = Self.generationPreferences()
        preferences.codingAgentPreference = .codex
        let store = Self.dependenciesBackedStore(generationPreferences: preferences)
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let model = ModelConfig(
            identifier: "codex:gpt-5.5",
            displayName: "GPT-5.5 (Codex)",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [model]
        store.selectModel(model.selectionIdentifier)

        let context = try await store.makeSelectedAgentLanguageModelContext()

        #expect(context.pipelineConfiguration.codingAgent == .codex)
        #expect(context.codingAgentModelIdentifier == "codex:gpt-5.5")
        #expect(context.codexAgentAuthentication == .chatGPTLogin)
    }

    @MainActor
    @Test
    func selectedIronsmithModelUsesCodexCustomResponsesProviderWhenRequested() async throws {
        let preferences = Self.generationPreferences()
        preferences.codingAgentPreference = .codex
        let accountClient = Self.accountClient()
        let store = InferenceStore(
            dependencies: Self.dependencies(accountClient: accountClient),
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        provider.baseURLString = "https://api.ironsmith.test/api/v1"
        let model = ModelConfig(
            identifier: "deepseek/deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        store.providers = [provider]
        store.remoteModels = [model]
        store.selectModel(model.selectionIdentifier)
        try await store.prepareSelectedModelForGeneration()

        let context = try await store.makeSelectedAgentLanguageModelContext()

        #expect(context.pipelineConfiguration.codingAgent == .codex)
        #expect(context.codingAgentModelIdentifier == "deepseek/deepseek-v4-flash")
        #expect(
            context.codexAgentAuthentication
                == .customResponsesProvider(
                    CodexAgentCustomResponsesProvider(
                        configurationIdentifier: "ironsmith",
                        sessionProviderIdentifier: "ironsmith",
                        displayName: "Ironsmith",
                        baseURL: URL(string: "https://api.ironsmith.test/api/v1")!,
                        authenticationEnvironmentVariable: "IRONSMITH_CODEX_ACCESS_TOKEN",
                        authenticationToken: "access-token"
                    )
                )
        )
    }

    @MainActor
    @Test
    func automaticCodingAgentUsesProviderModelAndLargeEditRules() {
        let openAIProvider = ProviderCatalog.makeProvider(for: .openAI)!
        let ironsmithProvider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let ollamaProvider = ProviderCatalog.makeProvider(for: .ollama)!
        let customProvider = ProviderCatalog.makeProvider(for: .customOpenAICompatible)!
        customProvider.identifier = "custom.test"
        let anthropicProvider = ProviderCatalog.makeProvider(for: .anthropic)!

        func resolve(
            _ identifier: String,
            provider: ProviderConfig,
            lineCount: Int? = nil,
            requested: ToolCodingAgentPreference = .automatic,
            requiresAttachmentSupport: Bool = false,
            supportsImageInput: Bool = false
        ) -> ToolCodingAgent {
            let model = ModelConfig(
                identifier: identifier,
                displayName: identifier,
                providerIdentifier: provider.identifier,
                source: .remote,
                installState: .installed,
                supportsImageInput: supportsImageInput
            )
            return ToolCodingAgentResolver.resolve(
                requested: requested,
                model: model,
                provider: provider,
                context: ToolCodingAgentResolutionContext(
                    generationMode: lineCount == nil ? .create : .edit,
                    existingSourceLineCount: lineCount,
                    requiresAttachmentSupport: requiresAttachmentSupport
                )
            )
        }

        #expect(resolve("future-model", provider: openAIProvider) == .codex)
        #expect(resolve("openai/gpt-5.4", provider: ironsmithProvider) == .codex)
        #expect(resolve("anthropic/claude-sonnet", provider: ironsmithProvider) == .ironsmithFlame)
        #expect(
            resolve(
                "anthropic/claude-sonnet",
                provider: ironsmithProvider,
                requiresAttachmentSupport: true,
                supportsImageInput: true
            ) == .codex
        )
        #expect(
            resolve(
                "anthropic/claude-sonnet",
                provider: ironsmithProvider,
                requested: .ironsmithFlame,
                requiresAttachmentSupport: true,
                supportsImageInput: true
            ) == .ironsmithFlame
        )
        #expect(resolve("anthropic/claude-sonnet", provider: ironsmithProvider, lineCount: 600) == .ironsmithFlame)
        #expect(resolve("anthropic/claude-sonnet", provider: ironsmithProvider, lineCount: 601) == .codex)

        #expect(resolve("gpt-oss:20b", provider: ollamaProvider) == .codex)
        #expect(resolve("claude-local", provider: ollamaProvider) == .ironsmithFlame)
        #expect(resolve("claude-local", provider: ollamaProvider, lineCount: 601) == .codex)
        #expect(resolve("gemma4:12b", provider: ollamaProvider, lineCount: 601) == .ironsmithSpark)

        customProvider.openAICompatibleAPIVariant = .chatCompletions
        #expect(resolve("openai/gpt-5.4", provider: customProvider) == .ironsmithFlame)
        #expect(resolve("openai/gpt-5.4", provider: customProvider, lineCount: 601) == .ironsmithFlame)

        customProvider.openAICompatibleAPIVariant = .responses
        #expect(resolve("openai/gpt-5.4", provider: customProvider) == .codex)
        #expect(resolve("google/gemini-3.1", provider: customProvider) == .ironsmithFlame)
        #expect(resolve("google/gemini-3.1", provider: customProvider, lineCount: 601) == .codex)
        #expect(resolve("deepseek-v4", provider: customProvider, lineCount: 601) == .ironsmithSpark)

        #expect(resolve("claude-sonnet", provider: anthropicProvider, lineCount: 601) == .ironsmithFlame)
        #expect(
            resolve(
                "openai/gpt-5.4",
                provider: openAIProvider,
                requested: .ironsmithSpark
            ) == .ironsmithSpark
        )
    }

    @MainActor
    @Test
    func selectedOllamaOpenAIModelUsesUnauthenticatedResponsesProviderForCodex() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .ollama)!
        provider.baseURLString = "http://localhost:11434"
        let model = ModelConfig(
            identifier: "gpt-oss:20b",
            displayName: "GPT OSS 20B",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        store.providers = [provider]
        store.remoteModels = [model]
        store.selectModel(model.selectionIdentifier)

        let context = try await store.makeSelectedAgentLanguageModelContext()
        let authentication = try #require(context.codexAgentAuthentication)
        guard case .customResponsesProvider(let codexProvider) = authentication else {
            Issue.record("Expected an Ollama custom Responses provider.")
            return
        }

        #expect(context.pipelineConfiguration.codingAgent == .codex)
        #expect(codexProvider.configurationIdentifier == "ironsmith_ollama")
        #expect(codexProvider.sessionProviderIdentifier == "ollama")
        #expect(codexProvider.baseURL.absoluteString == "http://localhost:11434/v1/")
        #expect(codexProvider.authenticationEnvironmentVariable == nil)
        #expect(codexProvider.authenticationToken == nil)
    }
}
