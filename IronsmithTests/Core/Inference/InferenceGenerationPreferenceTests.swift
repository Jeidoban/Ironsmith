import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @MainActor
    @Test
    func generatedPromptRefinementPreferenceDefaultsEnabledAndPersists() {
        let suiteName = "IronsmithTests.GeneratedPromptRefinement.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(preferences.generatedPromptRefinementEnabled == true)
        #expect(preferences.maximumResponseTokens == 32_768)
        #expect(preferences.maximumResponseTokens == ModelGenerationDefaults.remoteMaximumResponseTokens)

        preferences.generatedPromptRefinementEnabled = false
        preferences.maximumResponseTokens = 8192
        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(!(reloadedPreferences.generatedPromptRefinementEnabled))
        #expect(reloadedPreferences.maximumResponseTokens == 8192)
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
    func selectedAgentLanguageModelContextUsesFoundationMetadataModelForNameAndIcon() async throws {
        for kind in [ProviderKind.customOpenAICompatible, .ollama, .anthropic] {
            let context = try await Self.agentLanguageModelContext(providerKind: kind)

            #expect(context.languageModel is InferenceTestLanguageModel)
            #expect(context.metadataLanguageModel is AnyLanguageModel.SystemLanguageModel)
        }
    }

    @MainActor
    @Test
    func selectedAgentLanguageModelContextKeepsSelectedModelForPromptRefinementAndGeneration() async throws {
        let context = try await Self.agentLanguageModelContext(providerKind: .anthropic)

        #expect(context.languageModel is InferenceTestLanguageModel)
        #expect(context.metadataLanguageModel is AnyLanguageModel.SystemLanguageModel)
    }

    @MainActor
    @Test
    func foundationGenerationDefaultsMapToOptions() throws {
        let preferences = Self.generationPreferences()
        let model = ModelConfig(
            identifier: ModelConfig.appleFoundationIdentifier,
            displayName: "Apple Foundation Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .appleFoundation,
            installState: .builtIn
        )

        let options = model.generationOptions(preferences: preferences)

        #expect(options.temperature == ModelGenerationDefaults.foundation.temperature)
        #expect(options.maximumResponseTokens == ModelGenerationDefaults.foundation.maximumResponseTokens)
        #if canImport(Hub)
        #expect(options[custom: MLXLanguageModel.self] == nil)
        #endif
    }

    #if canImport(Hub)

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func eachMLXCatalogModelHasTunedDefaultsEntry() throws {
        #expect(Set(MLXModelCatalog.generationDefaultsByIdentifier.keys) == Set(MLXModelCatalog.all.map(\.identifier)))
        #expect(MLXModelCatalog.all.filter { $0.displayName.contains("Qwen") }.count == 4)

        for entry in MLXModelCatalog.all {
            let defaults = try #require(MLXModelCatalog.generationDefaultsByIdentifier[entry.identifier])
            let sampling = try #require(defaults.sampling)
            let expectedSampling = try #require(entry.generationDefaults.sampling)

            #expect(defaults.temperature == entry.generationDefaults.temperature)
            #expect(defaults.mlxKVCacheMaxSize == 16_384)
            #expect(defaults.mlxThinkingEnabled == entry.generationDefaults.mlxThinkingEnabled)
            #expect(sampling.topP == expectedSampling.topP)
            #expect(sampling.topK == expectedSampling.topK)
            #expect(sampling.minP == expectedSampling.minP)
            #expect(sampling.presencePenalty == expectedSampling.presencePenalty)
            #expect(sampling.repetitionPenalty == expectedSampling.repetitionPenalty)
        }
    }

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func mlxCatalogIncludesSmallAndLargeQwenRepairTargets() throws {
        let names = Set(MLXModelCatalog.all.map(\.displayName))

        #expect(names.contains("Qwen 3.5 4B"))
        #expect(names.contains("Qwen 3.5 9B"))
        #expect(names.contains("Qwen 3.6 35B 4-bit"))
        #expect(names.contains("Qwen 3.6 35B 8-bit"))
    }

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func qwenMLXGenerationDefaultsUseRequestedSamplingProfile() throws {
        let qwenEntry = try #require(MLXModelCatalog.all.first { $0.displayName.contains("Qwen") })
        let defaults = try #require(MLXModelCatalog.generationDefaultsByIdentifier[qwenEntry.identifier])
        let sampling = try #require(defaults.sampling)

        #expect(defaults.temperature == 0.6)
        #expect(!(defaults.mlxThinkingEnabled))
        #expect(sampling.topP == 0.95)
        #expect(sampling.topK == 20)
        #expect(sampling.minP == 0.0)
        #expect(sampling.presencePenalty == 0.0)
        #expect(sampling.repetitionPenalty == 1.0)
    }

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func mlxGenerationOptionsUseCatalogDefaults() throws {
        let preferences = Self.generationPreferences()
        let entry = MLXModelCatalog.all[0]
        let model = ModelConfig(
            identifier: entry.identifier,
            displayName: entry.displayName,
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )

        let options = model.generationOptions(preferences: preferences)
        let customOptions = try #require(options[custom: MLXLanguageModel.self])
        let regularGeneration = try #require(customOptions.regularGeneration)
        let structuredGeneration = try #require(customOptions.structuredGeneration)
        let expectedDefaults = entry.generationDefaults
        let expectedSampling = try #require(expectedDefaults.sampling)
        let expectedKVCacheMaxSize = try #require(expectedDefaults.mlxKVCacheMaxSize)

        #expect(options.temperature == expectedDefaults.temperature)
        #expect(options.maximumResponseTokens == expectedDefaults.maximumResponseTokens)
        #expect(customOptions.additionalContext?["enable_thinking"] == .bool(expectedDefaults.mlxThinkingEnabled ?? false))
        #expect(customOptions.kvCache.maxSize == expectedKVCacheMaxSize)
        #expect(customOptions.kvCache.bits == nil)
        #expect(regularGeneration.topP == expectedSampling.topP)
        #expect(regularGeneration.topK == expectedSampling.topK)
        #expect(regularGeneration.minP == expectedSampling.minP)
        #expect(regularGeneration.presencePenalty == expectedSampling.presencePenalty)
        #expect(regularGeneration.repetitionPenalty == expectedSampling.repetitionPenalty)
        #expect(structuredGeneration == regularGeneration)
    }

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func qwenMLXGenerationOptionsDisableThinking() throws {
        let preferences = Self.generationPreferences()
        let entry = try #require(MLXModelCatalog.all.first { $0.displayName.contains("Qwen") })
        let model = ModelConfig(
            identifier: entry.identifier,
            displayName: entry.displayName,
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )

        let options = model.generationOptions(preferences: preferences)
        let customOptions = try #require(options[custom: MLXLanguageModel.self])

        #expect(customOptions.additionalContext?["enable_thinking"] == .bool(false))
    }
    #endif

    @MainActor
    @Test
    func customGenerationOptionsOverrideSelectedModelDefaults() throws {
        let preferences = Self.generationPreferences()
        preferences.customOptionsEnabled = true
        preferences.temperature = 0.33
        preferences.maximumResponseTokens = 24_576
        var models = [
            ModelConfig(
                identifier: ModelConfig.appleFoundationIdentifier,
                displayName: "Apple Foundation Model",
                providerIdentifier: ProviderConfig.localProviderIdentifier,
                source: .appleFoundation,
                installState: .builtIn
            ),
            ModelConfig(
                identifier: "gpt-test",
                displayName: "GPT Test",
                providerIdentifier: ProviderKind.openAI.rawValue,
                source: .remote,
                installState: .installed
            ),
        ]
        if let entry = MLXModelCatalog.all.first {
            models.append(
                ModelConfig(
                    identifier: entry.identifier,
                    displayName: entry.displayName,
                    providerIdentifier: ProviderConfig.localProviderIdentifier,
                    source: .mlx,
                    installState: .installed
                )
            )
        }

        for model in models {
            let options = model.generationOptions(preferences: preferences)
            #expect(options.temperature == 0.33)
            #expect(options.maximumResponseTokens == 24_576)
        }
    }

    #if canImport(Hub)

    @MainActor
    @Test(.disabled("MLX catalog is temporarily disabled while local model downloads are parked."))
    func mlxKVCachePreferencesOnlyApplyWhenCustomOptionsAreEnabled() throws {
        let preferences = Self.generationPreferences()
        preferences.mlxKVCacheMaxSize = 8192
        preferences.mlxKVCacheBitsEnabled = true
        preferences.mlxKVCacheBits = 6
        let model = ModelConfig(
            identifier: MLXModelCatalog.all[0].identifier,
            displayName: MLXModelCatalog.all[0].displayName,
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )

        var customOptions = try #require(model.generationOptions(preferences: preferences)[custom: MLXLanguageModel.self])
        let defaultKVCacheMaxSize = try #require(ModelGenerationDefaults.defaults(for: model).mlxKVCacheMaxSize)
        #expect(customOptions.kvCache.maxSize == defaultKVCacheMaxSize)
        #expect(customOptions.kvCache.bits == nil)

        preferences.customOptionsEnabled = true
        customOptions = try #require(model.generationOptions(preferences: preferences)[custom: MLXLanguageModel.self])
        #expect(customOptions.kvCache.maxSize == 8192)
        #expect(customOptions.kvCache.bits == 6)
    }
    #endif

    @MainActor
    @Test
    func remoteModelsUseProviderDefaultsUnlessCustomOptionsAreEnabled() throws {
        let preferences = Self.generationPreferences()
        let model = ModelConfig(
            identifier: "gpt-test",
            displayName: "GPT Test",
            providerIdentifier: ProviderKind.openAI.rawValue,
            source: .remote,
            installState: .installed
        )

        var options = model.generationOptions(preferences: preferences)
        #expect(options.temperature == nil)
        #expect(options.maximumResponseTokens == ModelGenerationDefaults.remoteMaximumResponseTokens)
        #if canImport(Hub)
        #expect(options[custom: MLXLanguageModel.self] == nil)
        #endif

        preferences.customOptionsEnabled = true
        preferences.temperature = 0.44
        preferences.maximumResponseTokens = 8192
        options = model.generationOptions(preferences: preferences)
        #expect(options.temperature == 0.44)
        #expect(options.maximumResponseTokens == 8192)
        #if canImport(Hub)
        #expect(options[custom: MLXLanguageModel.self] == nil)
        #endif
    }

    @MainActor
    @Test
    func ollamaCatalogUsesServerGenerationDefaults() throws {
        #expect(OllamaModelCatalog.all.map(\.identifier) == [
            "gemma4:e2b",
            "gemma4:e4b-it-q8_0",
            "gemma4:12b",
            "gemma4:12b-it-q8_0",
            "gemma4:26b",
            "qwen3.6:35b",
            "gemma4:26b-a4b-it-q8_0",
            "qwen3.6:35b-a3b-q8_0",
        ])
        #expect(Set(OllamaModelCatalog.generationDefaultsByIdentifier.keys) == Set(OllamaModelCatalog.all.map(\.identifier)))

        let entry = OllamaModelCatalog.all[0]
        let defaults = try #require(OllamaModelCatalog.generationDefaultsByIdentifier[entry.identifier])
        let preferences = Self.generationPreferences()
        let model = ModelConfig(
            identifier: entry.identifier,
            displayName: entry.displayName,
            providerIdentifier: ProviderKind.ollama.rawValue,
            source: .remote,
            installState: .installed
        )
        let options = model.generationOptions(preferences: preferences)

        #expect(defaults.temperature == nil)
        #expect(defaults.maximumResponseTokens == ModelGenerationDefaults.remoteMaximumResponseTokens)
        #expect(defaults.mlxKVCacheMaxSize == nil)
        #expect(defaults.mlxKVCacheBitsEnabled == nil)
        #expect(defaults.mlxKVCacheBits == nil)
        #expect(defaults.mlxThinkingEnabled == nil)
        #expect(defaults.sampling == nil)
        #expect(options.temperature == nil)
        #expect(options.maximumResponseTokens == ModelGenerationDefaults.remoteMaximumResponseTokens)
        #expect(options[custom: OllamaLanguageModel.self] == nil)
    }

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
    func smallQwenMLXModelsUseDeterministicOnlyRepairStrategy() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .local)!
        let models = [
            ModelConfig(
                identifier: "mlx-community/Qwen3.5-4B-MLX-4bit",
                displayName: "Qwen 3.5 4B",
                providerIdentifier: ProviderConfig.localProviderIdentifier,
                source: .mlx,
                installState: .installed
            ),
            ModelConfig(
                identifier: "mlx-community/Qwen3.5-9B-8bit",
                displayName: "Qwen 3.5 9B",
                providerIdentifier: ProviderConfig.localProviderIdentifier,
                source: .mlx,
                installState: .installed
            )
        ]

        store.providers = [provider]
        store.persistedModels = models

        for model in models {
            store.selectedModelID = model.selectionIdentifier
            #expect(try await store.makeSelectedAgentLanguageModelContext().repairStrategy == .deterministicOnly)
        }
    }

    @MainActor
    @Test
    func largerQwenMLXModelsUseModelDiffRepairStrategy() async throws {
        let store = Self.dependenciesBackedStore()
        let provider = ProviderCatalog.makeProvider(for: .local)!
        let model = ModelConfig(
            identifier: "unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit",
            displayName: "Qwen 3.6 35B 4-bit",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )

        store.providers = [provider]
        store.persistedModels = [model]
        store.selectedModelID = model.selectionIdentifier

        #expect(try await store.makeSelectedAgentLanguageModelContext().repairStrategy == .modelDiff(maxHunksPerTurn: 1))
    }

    @MainActor
    @Test
    func mlxContextSizeDoesNotAffectRepairStrategy() async throws {
        let preferences = Self.generationPreferences()
        preferences.customOptionsEnabled = true
        preferences.mlxKVCacheMaxSize = 4096
        let store = Self.dependenciesBackedStore(generationPreferences: preferences)
        let provider = ProviderCatalog.makeProvider(for: .local)!
        let model = ModelConfig(
            identifier: "mlx-community/Gemma-Test-MLX",
            displayName: "Gemma Test",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .installed
        )

        store.providers = [provider]
        store.persistedModels = [model]
        store.selectedModelID = model.selectionIdentifier

        #expect(try await store.makeSelectedAgentLanguageModelContext().repairStrategy == .modelDiff(maxHunksPerTurn: 1))
    }
}
