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

    var temperature: Double?
    var maximumResponseTokens: Int? = 4096
    var mlxKVCacheMaxSize: Int?
    var mlxKVCacheBitsEnabled: Bool?
    var mlxKVCacheBits: Int?
    var mlxThinkingEnabled: Bool?
    var sampling: Sampling?

    static let remoteMaximumResponseTokens = 32_768

    static let foundation = Self(
        temperature: 0.7,
        maximumResponseTokens: 4096
    )

    static let remote = Self(
        temperature: nil,
        maximumResponseTokens: remoteMaximumResponseTokens
    )

    static let ollamaDefaults = Self(
        temperature: nil,
        maximumResponseTokens: remoteMaximumResponseTokens
    )

    static let qwenDefaults = Self(
        temperature: 0.6,
        maximumResponseTokens: 4096,
        mlxKVCacheMaxSize: 16_384,
        mlxKVCacheBitsEnabled: false,
        mlxKVCacheBits: 4,
        mlxThinkingEnabled: false,
        sampling: Sampling(
            topP: 0.95,
            topK: 20,
            minP: 0.0,
            presencePenalty: 0.0,
            repetitionPenalty: 1.0
        )
    )

    static func defaults(for model: ModelConfig) -> Self {
        switch model.source {
        case .appleFoundation:
            return .foundation
        case .mlx:
            return MLXModelCatalog.generationDefaultsByIdentifier[model.identifier] ?? .qwenDefaults
        case .remote:
            if model.isOpenAICodexModel {
                var defaults = Self.remote
                defaults.maximumResponseTokens = nil
                return defaults
            }
            if model.providerIdentifier == ProviderKind.ollama.rawValue {
                return OllamaModelCatalog.generationDefaultsByIdentifier[model.identifier] ?? .ollamaDefaults
            }
            return .remote
        }
    }
}

extension ModelConfig {
    @MainActor
    func generationOptions(preferences: GenerationPreferencesStore) -> GenerationOptions {
        let defaults = ModelGenerationDefaults.defaults(for: self)
        let customOptionsEnabled = preferences.customOptionsEnabled
        let temperature: Double?

        switch source {
        case .remote:
            temperature = customOptionsEnabled ? preferences.temperature : nil
        case .appleFoundation, .mlx:
            temperature = customOptionsEnabled ? preferences.temperature : defaults.temperature
        }

        var options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens(for: defaults, preferences: preferences)
        )

        if source == .mlx {
            #if canImport(Hub)
            let maxSize = customOptionsEnabled
                ? preferences.mlxKVCacheMaxSize
                : defaults.mlxKVCacheMaxSize ?? 4096
            let bitsEnabled = customOptionsEnabled
                ? preferences.mlxKVCacheBitsEnabled
                : defaults.mlxKVCacheBitsEnabled ?? false
            let bits = bitsEnabled
                ? (customOptionsEnabled ? preferences.mlxKVCacheBits : defaults.mlxKVCacheBits ?? 4)
                : nil

            options[custom: MLXLanguageModel.self] = MLXLanguageModel.CustomGenerationOptions(
                kvCache: .init(maxSize: maxSize, bits: bits, groupSize: 64, quantizedStart: 0),
                userInputProcessing: nil,
                additionalContext: ["enable_thinking": .bool(defaults.mlxThinkingEnabled ?? false)],
                // TODO: Enable if we add back mlx and use AnyLanguageModel fork
//                regularGeneration: defaults.mlxGenerationParameters,
//                structuredGeneration: defaults.mlxGenerationParameters
            )
            #endif
        }

        if source == .remote, providerIdentifier == ProviderKind.ollama.rawValue,
           let ollamaOptions = defaults.ollamaGenerationParameters {
            options[custom: OllamaLanguageModel.self] = ollamaOptions
        }

        if source == .remote, isOpenAICodexModel {
            options[custom: OpenAILanguageModel.self] = OpenAILanguageModel.CustomGenerationOptions(
                store: false
            )
        }

        return options
    }

    @MainActor
    private func maximumResponseTokens(
        for defaults: ModelGenerationDefaults,
        preferences: GenerationPreferencesStore
    ) -> Int? {
        if isOpenAICodexModel {
            return nil
        }
        if preferences.customOptionsEnabled {
            return preferences.maximumResponseTokens
        }
        return defaults.maximumResponseTokens
    }
}

private extension ModelGenerationDefaults {
    // TODO: Enable if we add back mlx and use AnyLanguageModel fork
//    var mlxGenerationParameters: MLXLanguageModel.CustomGenerationOptions.GenerationParameters? {
//        guard let sampling else { return nil }
//        return .init(
//            topP: sampling.topP,
//            topK: sampling.topK,
//            minP: sampling.minP,
//            repetitionPenalty: sampling.repetitionPenalty,
//            presencePenalty: sampling.presencePenalty
//        )
//    }

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
