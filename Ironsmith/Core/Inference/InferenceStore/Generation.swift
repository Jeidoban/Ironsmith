import Foundation

extension InferenceStore {
    func makeSelectedAgentLanguageModelContext(
        resolutionContext: ToolCodingAgentResolutionContext = .create
    ) async throws -> AgentLanguageModelContext {
        guard let selectedModel else {
            throw InferenceStoreError.missingSelectedModel
        }

        let provider = provider(for: selectedModel)
        try validateSelectedModelCanGenerate(selectedModel, provider: provider)
        let languageModel = try await dependencies.languageModelClient.makeLanguageModel(
            selectedModel, provider)
        let codingAgent = ToolCodingAgentResolver.resolve(
            requested: generationPreferences.codingAgentPreference,
            model: selectedModel,
            provider: provider,
            context: resolutionContext
        )
        let reasoningEffort = ToolReasoningSupport.effectiveEffort(
            requested: generationPreferences.reasoningEffort,
            model: selectedModel,
            provider: provider
        )
        let shouldRefreshIronsmithCredits = provider?.kind == .ironsmith
        return AgentLanguageModelContext(
            codingAgent: ToolGenerationOptionsResolver.stageConfiguration(
                for: .codingAgent,
                model: selectedModel,
                provider: provider,
                languageModel: languageModel,
                reasoningEffort: reasoningEffort
            ),
            promptRefinement: ToolGenerationOptionsResolver.stageConfiguration(
                for: .promptRefinement,
                model: selectedModel,
                provider: provider,
                languageModel: languageModel,
                reasoningEffort: reasoningEffort
            ),
            metadata: ToolGenerationOptionsResolver.stageConfiguration(
                for: .metadata,
                model: selectedModel,
                provider: provider,
                languageModel: languageModel,
                reasoningEffort: reasoningEffort
            ),
            pipelineConfiguration: pipelineConfiguration(for: selectedModel, codingAgent: codingAgent),
            promptRefinementEnabled: generationPreferences.generatedPromptRefinementEnabled,
            codingAgentModelIdentifier: selectedModel.identifier,
            codexAgentAuthentication: try await codexAgentAuthentication(
                for: selectedModel,
                provider: provider,
                codingAgent: codingAgent
            ),
            reasoningEffort: reasoningEffort,
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
        codingAgent: ToolCodingAgent
    ) -> ToolGenerationPipelineConfiguration {
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

    private func codexAgentAuthentication(
        for model: ModelConfig,
        provider: ProviderConfig?,
        codingAgent: ToolCodingAgent
    ) async throws -> CodexAgentAuthentication? {
        guard codingAgent == .codex else {
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
                    configurationIdentifier: "ironsmith",
                    sessionProviderIdentifier: provider.identifier,
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
        case .ollama:
            return .customResponsesProvider(
                try codexCustomResponsesProvider(
                    provider,
                    configurationIdentifier: "ironsmith_ollama",
                    baseURL: codexOllamaBaseURL(provider)
                )
            )
        case .customOpenAICompatible:
            guard provider.openAICompatibleAPIVariant == .responses else {
                throw CodexAgentError.unsupportedProvider
            }
            return .customResponsesProvider(
                try codexCustomResponsesProvider(
                    provider,
                    configurationIdentifier: "ironsmith_custom_\(provider.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                    baseURL: codexProviderBaseURL(provider)
                )
            )
        case .local, .anthropic, .gemini:
            throw CodexAgentError.unsupportedProvider
        }
    }

    private func codexCustomResponsesProvider(
        _ provider: ProviderConfig,
        configurationIdentifier: String,
        baseURL: URL
    ) throws -> CodexAgentCustomResponsesProvider {
        let apiKey: String? = if let reference = provider.apiKeyReference {
            try dependencies.credentialClient.loadAPIKey(reference)
        } else {
            nil
        }
        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAPIKey = trimmedAPIKey?.isEmpty == false
        return CodexAgentCustomResponsesProvider(
            configurationIdentifier: configurationIdentifier,
            sessionProviderIdentifier: provider.identifier,
            displayName: provider.displayName,
            baseURL: baseURL,
            authenticationEnvironmentVariable: hasAPIKey
                ? "IRONSMITH_CODEX_PROVIDER_API_KEY"
                : nil,
            authenticationToken: hasAPIKey ? trimmedAPIKey : nil
        )
    }

    private func codexOllamaBaseURL(_ provider: ProviderConfig) throws -> URL {
        let baseURL = try codexProviderBaseURL(provider)
        if baseURL.pathComponents.last?.lowercased() == "v1" {
            return baseURL
        }
        return baseURL.appendingPathComponent("v1", isDirectory: true)
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
