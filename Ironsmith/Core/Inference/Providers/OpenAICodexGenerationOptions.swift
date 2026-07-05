import AnyLanguageModel
import Foundation

nonisolated enum OpenAICodexGenerationOptions {
    static func isCodexLanguageModel(_ languageModel: any LanguageModel) -> Bool {
        guard let openAIModel = languageModel as? OpenAILanguageModel else {
            return false
        }
        return openAIModel.baseURL == OpenAICodexBackend.backendBaseURL
    }

    static func sanitized(
        _ options: GenerationOptions,
        for languageModel: any LanguageModel
    ) -> GenerationOptions {
        guard isCodexLanguageModel(languageModel) else {
            return options
        }

        var options = options
        options.maximumResponseTokens = nil

        var openAIOptions = options[custom: OpenAILanguageModel.self] ?? OpenAILanguageModel.CustomGenerationOptions()
        openAIOptions.store = false
        options[custom: OpenAILanguageModel.self] = openAIOptions

        return options
    }
}
