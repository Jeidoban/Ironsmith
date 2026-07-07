import AnyLanguageModel
import Foundation

nonisolated enum ToolGenerationStage: Sendable, Equatable, CaseIterable {
    case codingAgent
    case promptRefinement
    case metadata
}

struct ToolGenerationStageConfiguration {
    let stage: ToolGenerationStage
    let languageModel: any LanguageModel
    let generationOptions: GenerationOptions
    let streaming: Bool
}

nonisolated struct ModelGenerationCapabilities: Equatable, Sendable {
    var supportsMaximumResponseTokens: Bool
    var supportsResponseStorage: Bool
    var requiresStreaming: Bool

    static let standard = Self(
        supportsMaximumResponseTokens: true,
        supportsResponseStorage: true,
        requiresStreaming: false
    )

    static let openAICodex = Self(
        supportsMaximumResponseTokens: false,
        supportsResponseStorage: false,
        requiresStreaming: true
    )

    static func resolved(
        model: ModelConfig?,
        provider: ProviderConfig?,
        languageModel: (any LanguageModel)?
    ) -> Self {
        if model?.isOpenAICodexModel == true || isOpenAICodexLanguageModel(languageModel) {
            return .openAICodex
        }
        return .standard
    }

    static func isOpenAICodexLanguageModel(_ languageModel: (any LanguageModel)?) -> Bool {
        guard let openAIModel = languageModel as? OpenAILanguageModel else {
            return false
        }
        return openAIModel.baseURL == OpenAICodexBackend.backendBaseURL
    }

    func applying(to options: GenerationOptions) -> GenerationOptions {
        var options = options
        if !supportsMaximumResponseTokens {
            options.maximumResponseTokens = nil
        }

        if !supportsResponseStorage {
            var openAIOptions =
                options[custom: OpenAILanguageModel.self]
                ?? OpenAILanguageModel.CustomGenerationOptions()
            openAIOptions.store = false
            options[custom: OpenAILanguageModel.self] = openAIOptions
        }

        return options
    }
}

enum ToolGenerationOptionsResolver {
    nonisolated static let defaultStreaming = true
    nonisolated static let globalMaximumResponseTokens = 32_768
    nonisolated static let promptRefinementMaximumResponseTokens = 1_000
    nonisolated static let metadataMaximumResponseTokens = 512

    @MainActor
    static func stageConfiguration(
        for stage: ToolGenerationStage,
        model: ModelConfig?,
        provider: ProviderConfig?,
        languageModel: any LanguageModel
    ) -> ToolGenerationStageConfiguration {
        let capabilities = ModelGenerationCapabilities.resolved(
            model: model,
            provider: provider,
            languageModel: languageModel
        )
        let options = capabilities.applying(to: baseOptions(for: stage))
        return ToolGenerationStageConfiguration(
            stage: stage,
            languageModel: languageModel,
            generationOptions: options,
            streaming: defaultStreaming || capabilities.requiresStreaming
        )
    }

    @MainActor
    static func options(
        for stage: ToolGenerationStage,
        model: ModelConfig?,
        provider: ProviderConfig?,
        languageModel: (any LanguageModel)?
    ) -> GenerationOptions {
        let capabilities = ModelGenerationCapabilities.resolved(
            model: model,
            provider: provider,
            languageModel: languageModel
        )
        return capabilities.applying(to: baseOptions(for: stage))
    }

    @MainActor
    private static func baseOptions(for stage: ToolGenerationStage) -> GenerationOptions {
        switch stage {
        case .codingAgent:
            return GenerationOptions(maximumResponseTokens: globalMaximumResponseTokens)
        case .promptRefinement:
            return GenerationOptions(maximumResponseTokens: promptRefinementMaximumResponseTokens)
        case .metadata:
            return GenerationOptions(maximumResponseTokens: metadataMaximumResponseTokens)
        }
    }
}

extension ModelConfig {
    @MainActor
    func generationOptions(preferences: GenerationPreferencesStore) -> GenerationOptions {
        ToolGenerationOptionsResolver.options(
            for: .codingAgent,
            model: self,
            provider: nil,
            languageModel: nil
        )
    }
}
