import AnyLanguageModel
import Foundation

struct ContentViewBuildRepairLoop {
    let context: ToolGenerationRuntimeContext
    let layout: ToolPackageLayout
    let displayName: String
    let contentViewPath: String
    let regenerationThreshold: Int
    let maximumGenerationAttempts: Int

    struct SourceCandidate {
        let source: String
        let diagnostics: [SwiftCompilerDiagnostic]
        let contentViewErrorCount: Int
        let phase: String
    }

    struct RepairSourceCandidate {
        let source: String
        let summary: String
    }

    struct BuildState {
        let result: SwiftPackageBuildResult
        let diagnostics: [SwiftCompilerDiagnostic]
        let contentViewErrors: [SwiftCompilerDiagnostic]
        let source: String
    }

    enum SkippedRepairReason {
        case invalidRepairPatch
        case noDeterministicRepair

        var logTitle: String {
            switch self {
            case .invalidRepairPatch:
                return "invalid patch"
            case .noDeterministicRepair:
                return "no deterministic repair"
            }
        }

        var regenerationTitle: String {
            switch self {
            case .invalidRepairPatch:
                return "invalid patches"
            case .noDeterministicRepair:
                return "no deterministic repair"
            }
        }
    }

    struct RepairPromptPlan {
        let maximumDiffHunks: Int?
        let targetDiagnostics: [SwiftCompilerDiagnostic]
        let snippets: [ContentViewRepairSnippet]
    }

    enum SourceMutationBuildResult {
        case finished
        case accepted(BuildState)
        case rolledBack
    }

    enum CandidateRepairResult {
        case finished
        case regenerate(String)
        case failed(BuildState)
    }

    enum FailureRecovery {
        case restoreBestCandidate
        case restoreOriginalSource(String)
    }

    func run(
        generator: ContentViewCandidateGenerator,
        failureRecovery: FailureRecovery = .restoreBestCandidate,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        var activeGenerator = generator
        var bestCandidate: SourceCandidate?
        var lastFailedState: BuildState?
        var lastFailureMessage: String?
        var pendingRegenerationReason: String?
        var consecutiveRetryableCandidateFailures = 0

        candidateLoop: for generationAttempt in 1...maximumGenerationAttempts {
            try Task.checkCancellation()
            let isInitialAttempt = generationAttempt == 1
            if !isInitialAttempt {
                AgentDiagnosticsLog.append(
                    """
                    Regenerating ContentView.swift.
                    packageRoot: \(layout.packageRootURL.path)
                    mode: \(activeGenerator.modeDescription)
                    generationAttempt: \(generationAttempt)
                    reason: \(pendingRegenerationReason ?? "repair requested a fresh candidate")
                    """
                )
            }

            let statusVerb = isInitialAttempt ? activeGenerator.initialStatusVerb : activeGenerator.retryStatusVerb
            status("\(statusVerb) \(displayName)")
            do {
                try await activeGenerator.writeFreshCandidate(makeGenerationSession(instructions: activeGenerator.instructions))
                try Task.checkCancellation()
                try await Self.cleanContentViewSource(contentViewPath, layout: layout, context: context)
                consecutiveRetryableCandidateFailures = 0
            } catch where ToolGenerationError.isContextWindowExceeded(error) {
                AgentDiagnosticsLog.append(
                    """
                    ContentView generation exceeded context window; retrying generation.
                    packageRoot: \(layout.packageRootURL.path)
                    mode: \(activeGenerator.modeDescription)
                    generationAttempt: \(generationAttempt)
                    error:
                    \(AgentDiagnosticsLog.renderError(error, limit: 1_500))
                    """
                )
                guard generationAttempt < maximumGenerationAttempts else {
                    throw error
                }
                continue
            } catch where activeGenerator.retriesInvalidCandidates && Self.isRetryableCandidateFailure(error) {
                consecutiveRetryableCandidateFailures += 1
                lastFailureMessage = error.localizedDescription
                pendingRegenerationReason = error.localizedDescription
                AgentDiagnosticsLog.append(
                    """
                    ContentView candidate rejected; requesting another candidate.
                    packageRoot: \(layout.packageRootURL.path)
                    mode: \(activeGenerator.modeDescription)
                    generationAttempt: \(generationAttempt)
                    error:
                    \(AgentDiagnosticsLog.renderError(error, limit: 800))
                    """
                )
                if let fallback = activeGenerator.invalidCandidateFallback,
                   consecutiveRetryableCandidateFailures >= fallback.threshold,
                   generationAttempt < maximumGenerationAttempts {
                    AgentDiagnosticsLog.append(
                        """
                        Edit diff fallback selected.
                        packageRoot: \(layout.packageRootURL.path)
                        generationAttempt: \(generationAttempt)
                        invalidFailureCount: \(consecutiveRetryableCandidateFailures)
                        fallbackReason: \(error.localizedDescription)
                        """
                    )
                    activeGenerator = fallback.makeGenerator()
                    consecutiveRetryableCandidateFailures = 0
                    pendingRegenerationReason = "switched to whole-file edit after repeated invalid edit diffs"
                }
                guard generationAttempt < maximumGenerationAttempts else {
                    break candidateLoop
                }
                continue
            } catch {
                AgentDiagnosticsLog.append(
                    """
                    ContentView generation request failed.
                    packageRoot: \(layout.packageRootURL.path)
                    mode: \(activeGenerator.modeDescription)
                    generationAttempt: \(generationAttempt)
                    error:
                    \(AgentDiagnosticsLog.renderError(error))
                    """
                )
                throw error
            }

            let phase = isInitialAttempt ? "initial compile" : "regenerated compile \(generationAttempt - 1)"
            status("Building \(displayName)")
            guard var state = try await buildCurrentSource(phase: phase) else {
                if try compiledContentViewIsPlaceholder(phase: phase) {
                    pendingRegenerationReason = "compiled ContentView.swift was only the placeholder scaffold"
                    lastFailureMessage = "ContentView.swift compiled but only contains the placeholder Generated App scaffold."
                    continue
                }
                return
            }

            guard let stableState = try await applyDeterministicRepairsUntilStable(
                startingFrom: state,
                phasePrefix: "\(phase) deterministic repair",
                status: status
            ) else {
                return
            }
            state = stableState
            lastFailedState = state

            recordBestCandidate(from: state, phase: phase, bestCandidate: &bestCandidate)
            if state.contentViewErrors.isEmpty {
                lastFailureMessage = SwiftPackageProcessClient.compilerExcerpt(from: state.result.combinedOutput)
                break candidateLoop
            }

            let sourceAwareRegenerationThreshold = ToolGenerationRepairPolicy.regenerationThreshold(
                for: state.source,
                minimumThreshold: regenerationThreshold
            )
            if state.contentViewErrors.count > sourceAwareRegenerationThreshold {
                pendingRegenerationReason = "ContentView error count \(state.contentViewErrors.count) exceeded regeneration threshold \(sourceAwareRegenerationThreshold)"
                continue
            }

            guard context.repairStrategy.usesModelRepair else {
                pendingRegenerationReason = "deterministic-only repair stalled with \(state.contentViewErrors.count) ContentView errors"
                continue
            }

            switch try await runModelRepairForCurrentCandidate(
                startingFrom: state,
                status: status,
                bestCandidate: &bestCandidate
            ) {
            case .finished:
                return
            case .regenerate(let reason):
                pendingRegenerationReason = reason
                continue
            case .failed(let failedState):
                lastFailedState = failedState
                lastFailureMessage = "ContentView.swift still has \(failedState.contentViewErrors.count) compiler errors after repair attempts."
                break candidateLoop
            }
        }

        try restoreBestCandidateAndFail(
            bestCandidate,
            lastFailedState: lastFailedState,
            fallbackMessage: lastFailureMessage,
            failureRecovery: failureRecovery
        )
    }
}
