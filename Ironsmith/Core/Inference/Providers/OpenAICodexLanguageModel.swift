import AnyLanguageModel
import Foundation
import JSONSchema

nonisolated struct OpenAICodexLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let base: OpenAILanguageModel
    let usesResponsesLite: Bool

    var model: String { base.model }
    var baseURL: URL { base.baseURL }

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        try await base.respond(
            within: session,
            to: prompt,
            generating: type,
            includeSchemaInPrompt: includeSchemaInPrompt,
            options: preparedGenerationOptions(options)
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        base.streamResponse(
            within: session,
            to: prompt,
            generating: type,
            includeSchemaInPrompt: includeSchemaInPrompt,
            options: preparedGenerationOptions(options)
        )
    }

    func preparedGenerationOptions(_ options: GenerationOptions) -> GenerationOptions {
        guard usesResponsesLite else { return options }

        var options = options
        var custom = options[custom: OpenAILanguageModel.self]
            ?? OpenAILanguageModel.CustomGenerationOptions()
        var extraBody = custom.extraBody ?? [:]
        var reasoning: [String: JSONValue] = [:]
        if case .object(let existingReasoning) = extraBody["reasoning"] {
            reasoning = existingReasoning
        }
        reasoning["context"] = .string("all_turns")
        extraBody["reasoning"] = .object(reasoning)
        custom.parallelToolCalls = false
        custom.extraBody = extraBody
        options[custom: OpenAILanguageModel.self] = custom
        return options
    }
}
