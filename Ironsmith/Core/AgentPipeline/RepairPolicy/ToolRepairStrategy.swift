import Foundation

enum AgentPipelineProfilePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case smallModel = "small_model"
    case largeModel = "large_model"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .smallModel:
            return "Small Model Agent"
        case .largeModel:
            return "Large Model Agent"
        }
    }
}

enum AgentPipelineProfile: String, Codable, Equatable, Sendable {
    case smallModel = "small_model"
    case largeModel = "large_model"

    var displayName: String {
        switch self {
        case .smallModel:
            return "Small Model Agent"
        case .largeModel:
            return "Large Model Agent"
        }
    }
}

struct ToolGenerationPipelineConfiguration: Equatable, Sendable {
    let profile: AgentPipelineProfile
    let repairStrategy: ToolRepairStrategy
    let maximumGenerationAttempts: Int
    let batchesRepairDiagnostics: Bool
    let restoresBestCandidateOnFailure: Bool
    let rollsBackModelRepairWhenErrorCountIncreases: Bool
    let regeneratesAfterModelRepairStall: Bool
    let fallsBackToWholeFileEditAfterInvalidInitialPatch: Bool
    let maximumModelRepairAttempts: Int?

    static func small(repairStrategy: ToolRepairStrategy) -> Self {
        ToolGenerationPipelineConfiguration(
            profile: .smallModel,
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

    static func large(repairStrategy: ToolRepairStrategy) -> Self {
        ToolGenerationPipelineConfiguration(
            profile: .largeModel,
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
