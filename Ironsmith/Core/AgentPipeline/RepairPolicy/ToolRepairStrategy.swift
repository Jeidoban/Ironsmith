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

enum ToolCodingAgentSupport {
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
        case .ironsmith, .openAI:
            return true
        case .local, .anthropic, .gemini, .ollama, .customOpenAICompatible, nil:
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
