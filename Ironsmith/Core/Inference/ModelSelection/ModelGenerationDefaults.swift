import AnyLanguageModel
import Foundation
import JSONSchema

struct ModelGenerationDefaults: Equatable {
    struct Sampling: Equatable {
        var topP: Float?
        var topK: Int?
        var minP: Float?
        var presencePenalty: Float?
        var repetitionPenalty: Float?
    }

    var maximumResponseTokens: Int?
    var sampling: Sampling?

    static let globalMaximumResponseTokens = 32_768
    static let remoteMaximumResponseTokens = globalMaximumResponseTokens

    static let foundation = Self(maximumResponseTokens: globalMaximumResponseTokens)
    static let remote = Self(maximumResponseTokens: globalMaximumResponseTokens)
    static let ollamaDefaults = Self(maximumResponseTokens: globalMaximumResponseTokens)

    static func defaults(for model: ModelConfig) -> Self {
        switch model.source {
        case .appleFoundation:
            return .foundation
        case .mlx:
            return .remote
        case .remote:
            return model.providerIdentifier == ProviderKind.ollama.rawValue ? .ollamaDefaults : .remote
        }
    }
}

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
    nonisolated static let globalMaximumResponseTokens = ModelGenerationDefaults.globalMaximumResponseTokens
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
        let options = capabilities.applying(to: baseOptions(for: stage, model: model))
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
        return capabilities.applying(to: baseOptions(for: stage, model: model))
    }

    @MainActor
    private static func baseOptions(
        for stage: ToolGenerationStage,
        model: ModelConfig?
    ) -> GenerationOptions {
        switch stage {
        case .codingAgent:
            let maximumResponseTokens = model
                .flatMap { ModelGenerationDefaults.defaults(for: $0).maximumResponseTokens }
                ?? globalMaximumResponseTokens
            return GenerationOptions(maximumResponseTokens: maximumResponseTokens)
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

private extension ModelGenerationDefaults {
    var ollamaGenerationParameters: OllamaLanguageModel.CustomGenerationOptions? {
        guard let sampling else { return nil }
        var options: OllamaLanguageModel.CustomGenerationOptions = [:]
        if let topP = sampling.topP {
            options["top_p"] = .double(Double(topP))
        }
        if let topK = sampling.topK {
            options["top_k"] = .int(topK)
        }
        if let minP = sampling.minP {
            options["min_p"] = .double(Double(minP))
        }
        if let presencePenalty = sampling.presencePenalty {
            options["presence_penalty"] = .double(Double(presencePenalty))
        }
        if let repetitionPenalty = sampling.repetitionPenalty {
            options["repeat_penalty"] = .double(Double(repetitionPenalty))
        }
        return options.isEmpty ? nil : options
    }
}
