import Foundation

enum ToolCodingAgentPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case ironsmithSpark = "small_model"
    case ironsmithFlame = "large_model"
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .ironsmithSpark:
            return "Ironsmith Spark"
        case .ironsmithFlame:
            return "Ironsmith Flame"
        case .codex:
            return "Codex"
        }
    }
}

enum ToolCodingAgent: String, Codable, Equatable, Sendable {
    case ironsmithSpark = "small_model"
    case ironsmithFlame = "large_model"
    case codex

    var displayName: String {
        switch self {
        case .ironsmithSpark:
            return "Ironsmith Spark"
        case .ironsmithFlame:
            return "Ironsmith Flame"
        case .codex:
            return "Codex"
        }
    }
}

nonisolated enum ToolModelFamily: Equatable, Sendable {
    case openAI
    case claude
    case gemini
    case other

    static func resolved(
        identifier: String,
        providerKind: ProviderKind? = nil
    ) -> Self {
        switch providerKind {
        case .openAI:
            return .openAI
        case .anthropic:
            return .claude
        case .gemini:
            return .gemini
        default:
            break
        }

        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix(OpenAICodexBackend.modelIdentifierPrefix)
            || normalized.hasPrefix("openai/")
            || normalized.hasPrefix("openai.")
            || normalized.hasPrefix("openai:")
            || normalized.hasPrefix("gpt-")
            || normalized.hasPrefix("gpt_")
            || normalized.hasPrefix("chatgpt")
            || normalized.hasPrefix("codex")
            || isOpenAIReasoningModelIdentifier(normalized)
        {
            return .openAI
        }
        if normalized.hasPrefix("anthropic/")
            || normalized.hasPrefix("anthropic.")
            || normalized.hasPrefix("anthropic:")
            || normalized.hasPrefix("claude")
        {
            return .claude
        }
        if normalized.hasPrefix("google/gemini")
            || normalized.hasPrefix("google.gemini")
            || normalized.hasPrefix("google:gemini")
            || normalized.hasPrefix("gemini")
        {
            return .gemini
        }
        return .other
    }

    private static func isOpenAIReasoningModelIdentifier(_ identifier: String) -> Bool {
        ["o1", "o3", "o4"].contains { family in
            identifier == family
                || identifier.hasPrefix("\(family)-")
                || identifier.hasPrefix("\(family)_")
                || identifier.hasPrefix("\(family)/")
                || identifier.hasPrefix("\(family):")
        }
    }

    static func resolved(model: ModelConfig, provider: ProviderConfig?) -> Self {
        resolved(identifier: model.identifier, providerKind: provider?.kind)
    }
}

nonisolated struct ToolCodingAgentResolutionContext: Equatable, Sendable {
    let generationMode: ToolGenerationMode
    let existingSourceLineCount: Int?

    static let create = Self(generationMode: .create, existingSourceLineCount: nil)

    var isLargeEdit: Bool {
        generationMode == .edit && (existingSourceLineCount ?? 0) > 600
    }
}

nonisolated enum ToolCodingAgentSupport {
    static func supportedPreferences(
        for model: ModelConfig?,
        provider: ProviderConfig?
    ) -> Set<ToolCodingAgentPreference> {
        var supported: Set<ToolCodingAgentPreference> = [
            .automatic,
            .ironsmithSpark,
            .ironsmithFlame,
        ]
        if supportsCodex(model: model, provider: provider) {
            supported.insert(.codex)
        }
        return supported
    }

    static func supportsCodex(
        model _: ModelConfig?,
        provider: ProviderConfig?
    ) -> Bool {
        switch provider?.kind {
        case .ironsmith, .openAI, .ollama:
            return true
        case .customOpenAICompatible:
            return provider?.openAICompatibleAPIVariant == .responses
        case .local, .anthropic, .gemini, nil:
            return false
        }
    }

    static func effectivePreference(
        requested: ToolCodingAgentPreference,
        model: ModelConfig?,
        provider: ProviderConfig?
    ) -> ToolCodingAgentPreference {
        supportedPreferences(for: model, provider: provider).contains(requested)
            ? requested
            : .automatic
    }
}

nonisolated enum ToolCodingAgentResolver {
    static func resolve(
        requested: ToolCodingAgentPreference,
        model: ModelConfig,
        provider: ProviderConfig?,
        context: ToolCodingAgentResolutionContext
    ) -> ToolCodingAgent {
        switch ToolCodingAgentSupport.effectivePreference(
            requested: requested,
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
            let defaultAgent = automaticDefault(model: model, provider: provider)
            if defaultAgent == .ironsmithFlame,
               context.isLargeEdit,
               ToolCodingAgentSupport.supportsCodex(model: model, provider: provider)
            {
                return .codex
            }
            return defaultAgent
        }
    }

    private static func automaticDefault(
        model: ModelConfig,
        provider: ProviderConfig?
    ) -> ToolCodingAgent {
        guard model.source == .remote else {
            return .ironsmithSpark
        }

        let family = ToolModelFamily.resolved(model: model, provider: provider)
        switch provider?.kind {
        case .openAI:
            return .codex
        case .ironsmith:
            return family == .openAI ? .codex : .ironsmithFlame
        case .ollama:
            switch family {
            case .openAI:
                return .codex
            case .claude, .gemini:
                return .ironsmithFlame
            case .other:
                return .ironsmithSpark
            }
        case .customOpenAICompatible:
            switch family {
            case .openAI:
                return provider?.openAICompatibleAPIVariant == .responses
                    ? .codex
                    : .ironsmithFlame
            case .claude, .gemini:
                return .ironsmithFlame
            case .other:
                return .ironsmithSpark
            }
        case .anthropic, .gemini:
            return .ironsmithFlame
        case .local, nil:
            return .ironsmithSpark
        }
    }
}

struct ToolGenerationPipelineConfiguration: Equatable, Sendable {
    let codingAgent: ToolCodingAgent
    let repairStrategy: ToolRepairStrategy
    let maximumGenerationAttempts: Int
    let batchesRepairDiagnostics: Bool
    let restoresBestCandidateOnFailure: Bool
    let rollsBackModelRepairWhenErrorCountIncreases: Bool
    let regeneratesAfterModelRepairStall: Bool
    let fallsBackToWholeFileEditAfterInvalidInitialPatch: Bool
    let maximumModelRepairAttempts: Int?

    static func ironsmithSpark(repairStrategy: ToolRepairStrategy) -> Self {
        ToolGenerationPipelineConfiguration(
            codingAgent: .ironsmithSpark,
            repairStrategy: repairStrategy,
            maximumGenerationAttempts: ToolGenerationRepairPolicy.maximumGenerationAttempts,
            batchesRepairDiagnostics: true,
            restoresBestCandidateOnFailure: true,
            rollsBackModelRepairWhenErrorCountIncreases: true,
            regeneratesAfterModelRepairStall: true,
            fallsBackToWholeFileEditAfterInvalidInitialPatch: true,
            maximumModelRepairAttempts: nil
        )
    }

    static func ironsmithFlame(repairStrategy: ToolRepairStrategy) -> Self {
        ToolGenerationPipelineConfiguration(
            codingAgent: .ironsmithFlame,
            repairStrategy: repairStrategy,
            maximumGenerationAttempts: 1,
            batchesRepairDiagnostics: false,
            restoresBestCandidateOnFailure: false,
            rollsBackModelRepairWhenErrorCountIncreases: false,
            regeneratesAfterModelRepairStall: false,
            fallsBackToWholeFileEditAfterInvalidInitialPatch: false,
            maximumModelRepairAttempts: ToolGenerationRepairPolicy.largeModelMaximumRepairAttempts
        )
    }

    static func codex() -> Self {
        ToolGenerationPipelineConfiguration(
            codingAgent: .codex,
            repairStrategy: .deterministicOnly,
            maximumGenerationAttempts: 1,
            batchesRepairDiagnostics: false,
            restoresBestCandidateOnFailure: false,
            rollsBackModelRepairWhenErrorCountIncreases: false,
            regeneratesAfterModelRepairStall: false,
            fallsBackToWholeFileEditAfterInvalidInitialPatch: false,
            maximumModelRepairAttempts: nil
        )
    }
}

enum ToolRepairStrategy: Equatable, Sendable {
    case deterministicOnly
    case modelSearchReplace(maxPatchBlocksPerTurn: Int)

    var minimumRepairAttempts: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelSearchReplace:
            return ToolGenerationRepairPolicy.modelMinimumRepairAttempts
        }
    }

    var repairSlackAttempts: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelSearchReplace:
            return ToolGenerationRepairPolicy.modelRepairSlackAttempts
        }
    }

    var maximumRepairAttempts: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelSearchReplace:
            return ToolGenerationRepairPolicy.modelMaximumRepairAttempts
        }
    }

    var maxPatchBlocksPerTurn: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelSearchReplace(let maxPatchBlocksPerTurn):
            return max(1, maxPatchBlocksPerTurn)
        }
    }

    var usesModelRepair: Bool {
        switch self {
        case .deterministicOnly:
            return false
        case .modelSearchReplace:
            return true
        }
    }
}
