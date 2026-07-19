import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func runDiagnosticWholeFileRewrite(
        _ rewrite: ContentViewCandidateGenerator.DiagnosticRewrite,
        startingFrom state: BuildState,
        trigger: ModelRepairRegenerationReason
    ) async throws -> DiagnosticWholeFileRewriteResult {
        AgentDiagnosticsLog.append(
            """
            Diagnostic whole-file rewrite started.
            packageRoot: \(layout.packageRootURL.path)
            trigger: \(trigger.description)
            actionableErrorCount: \(state.contentViewErrors.count)
            """
        )

        do {
            try Task.checkCancellation()
            let session = makeGenerationSession(instructions: rewrite.instructions)
            try await rewrite.writeCandidate(state.source, state.contentViewErrors, session)
            try Task.checkCancellation()
            try await Self.prepareContentViewSource(
                contentViewPath,
                layout: layout,
                context: context
            )

            let phase = "diagnostic whole-file rewrite compile"
            guard let rewrittenState = try await buildCurrentSource(phase: phase) else {
                if try compiledContentViewIsPlaceholder(phase: phase) {
                    AgentDiagnosticsLog.append(
                        """
                        Diagnostic whole-file rewrite rejected as placeholder source.
                        packageRoot: \(layout.packageRootURL.path)
                        """
                    )
                    return .unavailable("diagnostic whole-file rewrite produced placeholder source")
                }
                try await lifecycle.updateRepairErrorCount(nil)
                AgentDiagnosticsLog.append(
                    """
                    Diagnostic whole-file rewrite compiled successfully.
                    packageRoot: \(layout.packageRootURL.path)
                    """
                )
                return .finished
            }

            guard let stableState = try await applyDeterministicRepairsUntilStable(
                startingFrom: rewrittenState,
                phasePrefix: "diagnostic whole-file rewrite deterministic repair"
            ) else {
                try await lifecycle.updateRepairErrorCount(nil)
                AgentDiagnosticsLog.append(
                    """
                    Diagnostic whole-file rewrite compiled after deterministic repair.
                    packageRoot: \(layout.packageRootURL.path)
                    """
                )
                return .finished
            }

            AgentDiagnosticsLog.append(
                """
                Diagnostic whole-file rewrite still requires model repair.
                packageRoot: \(layout.packageRootURL.path)
                previousContentViewErrorCount: \(state.contentViewErrors.count)
                newContentViewErrorCount: \(stableState.contentViewErrors.count)
                """
            )
            return .candidate(stableState)
        } catch where IronsmithErrorPresentation.isCancellation(error) || Task.isCancelled {
            throw error
        } catch {
            AgentDiagnosticsLog.append(
                """
                Diagnostic whole-file rewrite unavailable; requesting scratch regeneration.
                packageRoot: \(layout.packageRootURL.path)
                trigger: \(trigger.description)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 1_500))
                """
            )
            return .unavailable("diagnostic whole-file rewrite failed")
        }
    }
}
