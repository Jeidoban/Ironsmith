import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func runModelRepairForCurrentCandidate(
        startingFrom initialState: BuildState,
        bestCandidate: inout SourceCandidate?
    ) async throws -> CandidateRepairResult {
        var state = initialState
        let repairBudget = repairBudget(for: state.contentViewErrors)
        var failedCandidateAttemptsBySignature: [String: Int] = [:]
        var acceptedNoProgressAttemptsBySignature: [String: Int] = [:]
        var repairContextCompactionAttempts = 0
        var lastLoggedRepairTargetKey: String?
        let repairConversation = ContentViewRepairConversation(context: context)
        repairConversation.startNewCandidate()

        for attempt in 1...repairBudget {
            try Task.checkCancellation()
            guard !state.contentViewErrors.isEmpty else {
                return .failed(state)
            }
            try await lifecycle.updateRepairErrorCount(state.contentViewErrors.count)
            let originalSource = state.source
            let contentViewErrors = state.contentViewErrors
            let failedCandidateSignature = ContentViewRepairSupport.repairStallKey(
                for: contentViewErrors,
                source: originalSource,
                maximumCount: repairDiagnosticBatchLimit(for: contentViewErrors)
            )
            let repairCandidate: RepairSourceCandidate
            do {
                repairCandidate = try await makeRepairCandidateSource(
                    originalSource: originalSource,
                    diagnostics: contentViewErrors,
                    repairConversation: repairConversation,
                    attempt: attempt,
                    lastLoggedRepairTargetKey: &lastLoggedRepairTargetKey
                )
                try Task.checkCancellation()
            } catch where ToolGenerationError.isContextWindowExceeded(error) {
                if repairContextCompactionAttempts < 1 {
                    repairContextCompactionAttempts += 1
                    let outcome = "repair turn exceeded the model context window; starting a compacted repair session with the current source"
                    repairConversation.compactWithCurrentSource(
                        outcome: outcome,
                        summary: "The previous repair session exceeded the context window. Continue repairing the current ContentView.swift from the diagnostics below; deterministic repairs have already been attempted where available."
                    )
                    AgentDiagnosticsLog.append(
                        """
                        Repair model exceeded context window; compacting repair conversation.
                        packageRoot: \(layout.packageRootURL.path)
                        compactionAttempt: \(repairContextCompactionAttempts)
                        error:
                        \(AgentDiagnosticsLog.renderError(error, limit: 1_500))
                        """
                    )
                    continue
                }
                AgentDiagnosticsLog.append(
                    """
                    Repair model exceeded context window twice; requesting regeneration.
                    packageRoot: \(layout.packageRootURL.path)
                    error:
                    \(AgentDiagnosticsLog.renderError(error, limit: 1_500))
                    """
                )
                return .regenerate("model repair exceeded the context window after compaction")
            } catch {
                guard let skippedRepairReason = skippedRepairReason(for: error) else {
                    throw error
                }

                logSkippedRepairAttempt(
                    reason: skippedRepairReason,
                    attempt: attempt,
                    remainingBudget: repairBudget - attempt,
                    contentViewErrors: contentViewErrors
                )
                let invalidAttempts = increment(&failedCandidateAttemptsBySignature, for: failedCandidateSignature)

                if context.pipelineConfiguration.regeneratesAfterModelRepairStall,
                   invalidAttempts >= ToolGenerationRepairPolicy.invalidPatchAttemptsBeforeStall {
                    return .regenerate("model produced repeated \(skippedRepairReason.regenerationTitle)")
                }
                continue
            }

            switch try await compileSourceMutation(
                SourceMutationRequest(
                    source: repairCandidate.source,
                    originalSource: originalSource,
                    previousContentViewErrorCount: contentViewErrors.count,
                    phase: "repair attempt \(attempt)",
                    rollbackSubject: "Repair patch",
                    allowsIncreasedContentViewErrors: !context.pipelineConfiguration.rollsBackModelRepairWhenErrorCountIncreases
                )
            ) {
            case .finished:
                return .finished
            case .accepted(let acceptedState):
                guard let stableState = try await applyDeterministicRepairsUntilStable(
                    startingFrom: acceptedState,
                    phasePrefix: "model repair \(attempt) deterministic repair"
                ) else {
                    return .finished
                }
                let progressOutcome: String
                if stableState.contentViewErrors.count < contentViewErrors.count {
                    progressOutcome = "accepted; ContentView error count \(contentViewErrors.count) -> \(stableState.contentViewErrors.count)"
                } else {
                    progressOutcome = """
                    accepted but made no compiler progress; ContentView error count stayed \(contentViewErrors.count).
                    The previous patch did not reduce compiler errors. Do not repeat the same patch; choose a different fix for the remaining diagnostics.
                    """
                }
                let outcome = repairOutcomeSummary(
                    progressOutcome,
                    repairSummary: repairCandidate.summary
                )
                repairConversation.keepAuthoritativeSourceInSession(outcome: outcome)
                state = stableState
                recordBestCandidate(from: state, phase: "repair attempt \(attempt)", bestCandidate: &bestCandidate)
                if state.contentViewErrors.isEmpty {
                    return .failed(state)
                }
                if state.contentViewErrors.count >= contentViewErrors.count {
                    let noProgressSignature = ContentViewRepairSupport.repairStallKey(
                        for: state.contentViewErrors,
                        source: state.source,
                        maximumCount: repairDiagnosticBatchLimit(for: state.contentViewErrors)
                    )
                    let noProgressAttempts = increment(&acceptedNoProgressAttemptsBySignature, for: noProgressSignature)
                    if context.pipelineConfiguration.regeneratesAfterModelRepairStall,
                       noProgressAttempts >= 3 {
                        return .regenerate("model accepted repeated no-progress patches")
                    }
                } else {
                    acceptedNoProgressAttemptsBySignature.removeAll()
                }
            case .rolledBack:
                let outcome = repairOutcomeSummary(
                    "rolled back because compiler error count increased or the candidate compiled to the placeholder",
                    repairSummary: repairCandidate.summary
                )
                repairConversation.keepAuthoritativeSourceInSession(outcome: outcome)
                let rolledBackAttempts = increment(&failedCandidateAttemptsBySignature, for: failedCandidateSignature)
                if context.pipelineConfiguration.regeneratesAfterModelRepairStall,
                   rolledBackAttempts >= ToolGenerationRepairPolicy.invalidPatchAttemptsBeforeStall {
                    return .regenerate("model patches repeatedly rolled back")
                }
            }
        }

        guard !state.contentViewErrors.isEmpty else {
            return .failed(state)
        }
        AgentDiagnosticsLog.append(
            """
            Repair safety limit reached.
            packageRoot: \(layout.packageRootURL.path)
            repairBudget: \(repairBudget)
            contentViewErrorCount: \(state.contentViewErrors.count)
            """
        )
        if context.pipelineConfiguration.regeneratesAfterModelRepairStall {
            return .regenerate("model repair budget exhausted after \(repairBudget) attempts")
        }
        return .failed(state)
    }
}
