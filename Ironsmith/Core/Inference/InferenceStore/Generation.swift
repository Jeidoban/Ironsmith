import AnyLanguageModel
import Foundation

extension InferenceStore {
    func makeSelectedAgentLanguageModelContext() async throws -> AgentLanguageModelContext {
        guard let selectedModel else {
            throw InferenceStoreError.missingSelectedModel
        }

        let provider = provider(for: selectedModel)
        try validateSelectedModelCanGenerate(selectedModel, provider: provider)
        let languageModel = try await dependencies.languageModelClient.makeLanguageModel(
            selectedModel, provider)
        let options = selectedModel.generationOptions(preferences: generationPreferences)
        let shouldRefreshIronsmithCredits = provider?.kind == .ironsmith
        return AgentLanguageModelContext(
            languageModel: languageModel,
            metadataLanguageModel: AnyLanguageModel.SystemLanguageModel.default,
            options: options,
            pipelineConfiguration: pipelineConfiguration(for: selectedModel, provider: provider),
            promptRefinementEnabled: generationPreferences.generatedPromptRefinementEnabled,
            afterLanguageModelInvocation: { [weak self] in
                guard shouldRefreshIronsmithCredits else { return }
                await self?.refreshIronsmithAccountSummary()
            }
        )
    }

    func prepareSelectedModelForGeneration() async throws {
        guard let selectedModel else {
            throw InferenceStoreError.missingSelectedModel
        }

        let provider = provider(for: selectedModel)
        guard provider?.kind == .ironsmith else {
            return
        }

        ironsmithSession = dependencies.accountClient.currentSession()
        guard ironsmithSession != nil else {
            throw LanguageModelClientError.missingAccountSession
        }

        isRefreshingIronsmithAccount = true
        defer { isRefreshingIronsmithAccount = false }

        ironsmithAccountSummary = try await dependencies.accountClient.fetchAccountSummary()
        ironsmithSession = dependencies.accountClient.currentSession()
        try validateSelectedModelCanGenerate(selectedModel, provider: provider)
    }

    private func validateSelectedModelCanGenerate(
        _ model: ModelConfig,
        provider: ProviderConfig?
    ) throws {
        guard model.source == .remote, provider?.kind == .ironsmith else {
            return
        }

        guard ironsmithSession != nil else {
            throw LanguageModelClientError.missingAccountSession
        }

        if let balanceCredits = ironsmithAccountSummary?.credits.balanceCredits, balanceCredits <= 0
        {
            throw InferenceStoreError.insufficientIronsmithCredits
        }
    }

    private func pipelineConfiguration(
        for model: ModelConfig,
        provider: ProviderConfig?
    ) -> ToolGenerationPipelineConfiguration {
        let profile = resolvedAgentPipelineProfile(for: model, provider: provider)
        switch profile {
        case .smallModel:
            return .small(repairStrategy: smallModelRepairStrategy(for: model))
        case .largeModel:
            return .large(
                repairStrategy: .modelSearchReplace(
                    maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
                )
            )
        }
    }

    private func resolvedAgentPipelineProfile(
        for model: ModelConfig,
        provider: ProviderConfig?
    ) -> AgentPipelineProfile {
        switch generationPreferences.agentPipelineProfile {
        case .smallModel:
            return .smallModel
        case .largeModel:
            return .largeModel
        case .automatic:
            return defaultAgentPipelineProfile(for: model, provider: provider)
        }
    }

    private func defaultAgentPipelineProfile(
        for model: ModelConfig,
        provider: ProviderConfig?
    ) -> AgentPipelineProfile {
        guard model.source == .remote else {
            return .smallModel
        }

        switch provider?.kind {
        case .ironsmith, .openAI, .anthropic, .gemini:
            return .largeModel
        case .local, .ollama, .customOpenAICompatible, nil:
            return .smallModel
        }
    }

    private func smallModelRepairStrategy(for model: ModelConfig) -> ToolRepairStrategy {
        switch model.source {
        case .appleFoundation:
            return .deterministicOnly
        case .mlx:
            guard !usesDeterministicOnlyMLXRepair(model) else {
                return .deterministicOnly
            }
            return .modelSearchReplace(
                maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.smallModelPatchBlocksPerTurn
            )
        case .remote:
            return .modelSearchReplace(
                maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.smallModelPatchBlocksPerTurn
            )
        }
    }

    private func usesDeterministicOnlyMLXRepair(_ model: ModelConfig) -> Bool {
        let searchableName = "\(model.identifier) \(model.displayName)".lowercased()
        guard searchableName.contains("qwen") else {
            return false
        }
        return searchableName.range(
            of: #"(^|[^a-z0-9])(4b|9b)([^a-z0-9]|$)"#,
            options: .regularExpression
        ) != nil
    }
}
