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
        "This provider or coding agent doesn't currently support attachments."
}
