import Foundation

enum ToolGenerationRepairPolicy {
    // Small generated files start model repair once this many actionable compiler errors or fewer remain.
    static let regenerationThreshold = 12

    // Larger generated files often surface more diagnostics for one fixable issue.
    static let regenerationThresholdSourceLinesPerError = 20
    static let maximumRegenerationThreshold = 48

    // Maximum number of fresh ContentView generations to try before failing or restoring the best candidate.
    static let maximumGenerationAttempts = 10

    // Default batch size for deterministic JSON edit repairs.
    static let defaultDeterministicEditOperationsPerBatch = 3

    // Initial local-model edit patches can span more user-requested regions than compiler repairs.
    static let smallModelPatchBlocksPerTurn = 3

    // Larger remote-capable models can usually coordinate a broader patch without requiring regeneration.
    static let largeModelPatchBlocksPerTurn = 24

    // Catastrophic compiler cascades are usually one root issue repeated many times; keep prompts bounded.
    static let largeModelMaximumRepairDiagnostics = 200

    // Large-model edit patches get one fresh retry after an invalid/unappliable patch.
    static let minimumEditPatchGenerationAttempts = 2

    // Hard cap on search/replace patch response size before validation.
    static let maximumPatchCharacters = 128_000

    // Paid-call safety limit for the large-model profile.
    static let largeModelMaximumRepairAttempts = 6

    // Number of invalid model repairs for the same target before trying regeneration.
    static let invalidPatchAttemptsBeforeStall = 2

    // Number of invalid initial edit patches before falling back to whole-file edit generation.
    static let invalidInitialEditPatchesBeforeFullFileEdit = 2

    // Maximum deterministic compile/fix passes for one source candidate before declaring it stable.
    static let maximumDeterministicRepairPasses = 4

    // Minimum model repair turns once deterministic repairs are exhausted.
    static let modelMinimumRepairAttempts = 6

    // Extra model repair turns added for misses, rollbacks, and newly exposed errors.
    static let modelRepairSlackAttempts = 4

    // Hard cap on model repair turns.
    static let modelMaximumRepairAttempts = 20

    static func regenerationThreshold(
        for source: String,
        minimumThreshold: Int = regenerationThreshold
    ) -> Int {
        let sourceLineCount = source.components(separatedBy: .newlines).count
        return regenerationThreshold(
            forSourceLineCount: sourceLineCount,
            minimumThreshold: minimumThreshold
        )
    }

    static func regenerationThreshold(
        forSourceLineCount sourceLineCount: Int,
        minimumThreshold: Int = regenerationThreshold
    ) -> Int {
        let normalizedLineCount = max(1, sourceLineCount)
        let lineScaledThreshold = Int(
            ceil(Double(normalizedLineCount) / Double(regenerationThresholdSourceLinesPerError))
        )
        let lowerBound = max(regenerationThreshold, minimumThreshold)
        let upperBound = max(maximumRegenerationThreshold, lowerBound)
        return min(upperBound, max(lowerBound, lineScaledThreshold))
    }
}
