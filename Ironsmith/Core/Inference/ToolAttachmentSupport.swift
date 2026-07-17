import Foundation

nonisolated enum ToolAttachmentSupport {
    static func isSupported(
        model: ModelConfig?,
        provider: ProviderConfig?,
        codingAgent: ToolCodingAgent
    ) -> Bool {
        guard codingAgent == .codex, let model, let provider else { return false }

        switch provider.kind {
        case .openAI:
            return true
        case .ironsmith:
            return model.supportsImageInput
        case .customOpenAICompatible:
            return provider.openAICompatibleAPIVariant == .responses
        case .local, .anthropic, .gemini, .ollama:
            return false
        }
    }

    static let unavailableMessage =
        "Attachments require Codex with OpenAI, an image-capable Ironsmith model, or a custom Responses provider."
}
