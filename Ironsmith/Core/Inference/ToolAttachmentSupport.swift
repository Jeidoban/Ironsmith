import Foundation

nonisolated enum ToolAttachmentSupport {
    static func isSupported(
        model: ModelConfig?,
        provider: ProviderConfig?,
        codingAgent: ToolCodingAgent
    ) -> Bool {
        switch codingAgent {
        case .custom:
            return true
        case .codex:
            return canUseCodexAttachments(model: model, provider: provider)
        case .ironsmithSpark, .ironsmithFlame:
            return false
        }
    }

    static func canUseCodexAttachments(
        model: ModelConfig?,
        provider: ProviderConfig?
    ) -> Bool {
        guard let model, let provider else { return false }

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

    static func preferenceAfterAddingAttachments(
        _ preference: ToolCodingAgentPreference
    ) -> ToolCodingAgentPreference {
        switch preference {
        case .automatic, .custom:
            return preference
        case .ironsmithSpark, .ironsmithFlame, .codex:
            return .codex
        }
    }
}
