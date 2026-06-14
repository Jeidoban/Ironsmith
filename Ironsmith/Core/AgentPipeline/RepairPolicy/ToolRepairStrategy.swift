enum ToolRepairStrategy: Equatable, Sendable {
    case deterministicOnly
    case modelDiff(maxHunksPerTurn: Int?)

    var minimumRepairAttempts: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelDiff:
            return ToolGenerationRepairPolicy.modelMinimumRepairAttempts
        }
    }

    var repairSlackAttempts: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelDiff:
            return ToolGenerationRepairPolicy.modelRepairSlackAttempts
        }
    }

    var maximumRepairAttempts: Int {
        switch self {
        case .deterministicOnly:
            return 0
        case .modelDiff:
            return ToolGenerationRepairPolicy.modelMaximumRepairAttempts
        }
    }

    var maxHunksPerTurn: Int? {
        switch self {
        case .deterministicOnly:
            return nil
        case .modelDiff(let maxHunksPerTurn):
            return maxHunksPerTurn.map { max(1, $0) }
        }
    }

    var maxInitialEditHunks: Int? {
        switch self {
        case .deterministicOnly:
            return nil
        case .modelDiff(let maxHunksPerTurn):
            guard let maxHunksPerTurn else {
                return nil
            }
            if maxHunksPerTurn <= 1 {
                return ToolGenerationRepairPolicy.localModelEditDiffHunks
            }
            return max(1, maxHunksPerTurn)
        }
    }

    var usesModelRepair: Bool {
        switch self {
        case .deterministicOnly:
            return false
        case .modelDiff:
            return true
        }
    }
}
