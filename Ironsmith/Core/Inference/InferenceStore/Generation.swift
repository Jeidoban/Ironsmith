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
        let shouldRefreshIronsmithCredits = provider?.kind == .ironsmith
        return AgentLanguageModelContext(
            codingAgent: ToolGenerationOptionsResolver.stageConfiguration(
                for: .codingAgent,
                model: selectedModel,
                provider: provider,
                languageModel: languageModel
            ),
            promptRefinement: ToolGenerationOptionsResolver.stageConfiguration(
                for: .promptRefinement,
                model: selectedModel,
                provider: provider,
                languageModel: languageModel
            ),
            metadata: ToolGenerationOptionsResolver.stageConfiguration(
                for: .metadata,
                model: selectedModel,
                provider: provider,
                languageModel: languageModel
            ),
            pipelineConfiguration: pipelineConfiguration(for: selectedModel, provider: provider),
            promptRefinementEnabled: generationPreferences.generatedPromptRefinementEnabled,
            codingAgentModelIdentifier: selectedModel.identifier,
            codexAgentAuthentication: try await codexAgentAuthentication(
                for: selectedModel,
                provider: provider
            ),
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
        let codingAgent = resolvedToolCodingAgent(for: model, provider: provider)
        switch codingAgent {
        case .ironsmithSpark:
            return .ironsmithSpark(repairStrategy: smallModelRepairStrategy(for: model))
        case .ironsmithFlame:
            return .ironsmithFlame(
                repairStrategy: .modelSearchReplace(
                    maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
                )
            )
        case .codex:
            return .codex()
        }
    }

    private func resolvedToolCodingAgent(
        for model: ModelConfig,
        provider: ProviderConfig?
    ) -> ToolCodingAgent {
        switch ToolCodingAgentSupport.effectivePreference(
            requested: generationPreferences.codingAgentPreference,
            model: model,
            provider: provider
        ) {
        case .ironsmithSpark:
            return .ironsmithSpark
        case .ironsmithFlame:
            return .ironsmithFlame
        case .codex:
            return .codex
        case .automatic:
            return defaultToolCodingAgent(for: model, provider: provider)
        }
    }

    private func defaultToolCodingAgent(
        for model: ModelConfig,
        provider: ProviderConfig?
    ) -> ToolCodingAgent {
        guard model.source == .remote else {
            return .ironsmithSpark
        }

        switch provider?.kind {
        case .ironsmith, .openAI, .anthropic, .gemini:
            return .ironsmithFlame
        case .local, .ollama, .customOpenAICompatible, nil:
            return .ironsmithSpark
        }
    }

    private func codexAgentAuthentication(
        for model: ModelConfig,
        provider: ProviderConfig?
    ) async throws -> CodexAgentAuthentication? {
        guard resolvedToolCodingAgent(for: model, provider: provider) == .codex else {
            return nil
        }
        guard let provider else {
            throw CodexAgentError.unsupportedProvider
        }

        switch provider.kind {
        case .ironsmith:
            let accessToken = try await dependencies.accountClient.generationAccessToken()
            guard !accessToken.isEmpty else {
                throw LanguageModelClientError.missingAccountSession
            }
            return .customResponsesProvider(
                CodexAgentCustomResponsesProvider(
                    identifier: "ironsmith",
                    displayName: provider.displayName,
                    baseURL: try codexProviderBaseURL(provider),
                    authenticationEnvironmentVariable: "IRONSMITH_CODEX_ACCESS_TOKEN",
                    authenticationToken: accessToken
                )
            )
        case .openAI:
            if model.openAICodexRawIdentifier != nil {
                return .chatGPTLogin
            }
            guard let reference = provider.apiKeyReference,
                  let apiKey = try dependencies.credentialClient.loadAPIKey(reference),
                  !apiKey.isEmpty
            else {
                throw LanguageModelClientError.missingAPIKey
            }
            return .apiKey(apiKey)
        case .local, .anthropic, .gemini, .ollama, .customOpenAICompatible:
            throw CodexAgentError.unsupportedProvider
        }
    }

    private func codexProviderBaseURL(_ provider: ProviderConfig) throws -> URL {
        let descriptor = ProviderCatalog.descriptor(for: provider.kind)
        let baseURLString = provider.baseURLString.isEmpty
            ? descriptor?.defaultBaseURLString ?? ""
            : provider.baseURLString
        guard let baseURL = try? ProviderBaseURLValidator.validatedURL(from: baseURLString) else {
            throw LanguageModelClientError.invalidProviderURL
        }
        return baseURL
    }

    private func smallModelRepairStrategy(for model: ModelConfig) -> ToolRepairStrategy {
        switch model.source {
        case .appleFoundation:
            return .deterministicOnly
        case .mlx:
            return .deterministicOnly
        case .remote:
            return .modelSearchReplace(
                maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.smallModelPatchBlocksPerTurn
            )
        }
    }
}
