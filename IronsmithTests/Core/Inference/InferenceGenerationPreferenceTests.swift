import AnyLanguageModel
import Foundation
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

        preferences.generatedPromptRefinementEnabled = false
        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(!(reloadedPreferences.generatedPromptRefinementEnabled))
    }

    @MainActor
    @Test
    func agentPipelineProfilePreferenceDefaultsAutomaticAndPersists() {
        let suiteName = "IronsmithTests.AgentPipelineProfile.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let preferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(preferences.agentPipelineProfile == .automatic)

        preferences.agentPipelineProfile = .largeModel

        let reloadedPreferences = GenerationPreferencesStore(userDefaults: userDefaults)
        #expect(reloadedPreferences.agentPipelineProfile == .largeModel)
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
    func explicitAgentPipelineProfileOverridesAutomaticProviderDefault() async throws {
        let preferences = Self.generationPreferences()
        preferences.agentPipelineProfile = .largeModel
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
        #expect(context.pipelineConfiguration.profile == .largeModel)
        #expect(
            context.repairStrategy == .modelSearchReplace(
                maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
            )
        )
    }
}
