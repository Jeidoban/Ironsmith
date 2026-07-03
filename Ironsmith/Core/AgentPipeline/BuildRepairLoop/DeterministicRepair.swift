import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func applyDeterministicRepairsUntilStable(
        startingFrom initialState: BuildState,
        phasePrefix: String
    ) async throws -> BuildState? {
        var currentState = initialState
        var seenSignatures = Set<String>()

        for pass in 1...ToolGenerationRepairPolicy.maximumDeterministicRepairPasses {
            try Task.checkCancellation()
            guard !currentState.contentViewErrors.isEmpty else {
                return currentState
            }

            let stallKey = ContentViewRepairSupport.repairStallKey(
                for: currentState.contentViewErrors,
                source: currentState.source,
                maximumCount: currentState.contentViewErrors.count
            )
            guard seenSignatures.insert(stallKey).inserted else {
                AgentDiagnosticsLog.append(
                    """
                    Deterministic repair stopped after repeated source and diagnostic signature.
                    packageRoot: \(layout.packageRootURL.path)
                    phase: \(phasePrefix)
                    pass: \(pass)
                    contentViewErrorCount: \(currentState.contentViewErrors.count)
                    """
                )
                return currentState
            }

            guard let deterministicCandidate = applyDeterministicRepairEdits(
                to: currentState.source,
                diagnostics: currentState.contentViewErrors,
                pass: pass,
                phase: phasePrefix
            ) else {
                return currentState
            }

            switch try await compileSourceMutation(
                SourceMutationRequest(
                    source: deterministicCandidate.source,
                    originalSource: currentState.source,
                    previousContentViewErrorCount: currentState.contentViewErrors.count,
                    phase: "\(phasePrefix) \(pass)",
                    rollbackSubject: "Deterministic repair"
                )
            ) {
            case .finished:
                return nil
            case .accepted(let state):
                currentState = state
            case .rolledBack:
                return currentState
            }
        }

        return currentState
    }

    func applyDeterministicRepairEdits(
        to source: String,
        diagnostics: [SwiftCompilerDiagnostic],
        pass: Int,
        phase: String
    ) -> RepairSourceCandidate? {
        var updatedSource = source
        var appliedRepairs: [ContentViewDeterministicRepair] = []
        var seenTargets = Set<String>()

        for diagnostic in diagnostics {
            let repairSnippet = ContentViewRepairSupport.extractSnippet(from: updatedSource, around: diagnostic.line)
            guard let repair = ContentViewRepairSupport.makeDeterministicRepair(
                for: diagnostic,
                source: updatedSource,
                snippet: repairSnippet
            ) else {
                continue
            }

            let edit = repair.edit
            let targetKey = "\(edit.operation.rawValue)::\(edit.target)::\(edit.replacement)"
            guard seenTargets.insert(targetKey).inserted else {
                continue
            }

            do {
                let validationSnippets = deterministicValidationSnippets(
                    for: repair.edit,
                    source: updatedSource,
                    diagnosticLine: diagnostic.line,
                    fallbackSnippet: repairSnippet
                )
                updatedSource = try ContentViewRepairSupport.applyValidatedDeterministicEdit(
                    edit,
                    to: updatedSource,
                    snippets: validationSnippets,
                    allowWholeSourceTargets: true,
                )
                appliedRepairs.append(repair)
            } catch ToolGenerationError.invalidRepairPatch {
                AgentDiagnosticsLog.append(
                    """
                    Deterministic repair edit skipped after validation failure.
                    packageRoot: \(layout.packageRootURL.path)
                    phase: \(phase)
                    pass: \(pass)
                    fixer: \(repair.name)
                    edit:
                    \(AgentDiagnosticsLog.renderDeterministicEdit(edit))
                    """
                )
            } catch {
                AgentDiagnosticsLog.append(
                    """
                    Deterministic repair edit skipped after unexpected failure.
                    packageRoot: \(layout.packageRootURL.path)
                    phase: \(phase)
                    pass: \(pass)
                    fixer: \(repair.name)
                    error:
                    \(AgentDiagnosticsLog.renderError(error, limit: 1_000))
                    """
                )
            }
        }

        guard !appliedRepairs.isEmpty, updatedSource != source else {
            return nil
        }

        AgentDiagnosticsLog.append(
            """
            Deterministic repair edits accepted.
            packageRoot: \(layout.packageRootURL.path)
            phase: \(phase)
            pass: \(pass)
            fixers: \(appliedRepairs.map(\.name).joined(separator: ", "))
            edits:
            \(appliedRepairs.map { AgentDiagnosticsLog.renderDeterministicEditSummary($0.edit) }.joined(separator: "\n---\n"))
            """
        )

        return RepairSourceCandidate(
            source: updatedSource,
            summary: appliedRepairs.map { AgentDiagnosticsLog.renderDeterministicEditSummary($0.edit) }.joined(separator: "\n---\n")
        )
    }

    func deterministicValidationSnippets(
        for edit: ContentViewDeterministicEdit,
        source: String,
        diagnosticLine: Int,
        fallbackSnippet: ContentViewRepairSnippet
    ) -> [ContentViewRepairSnippet] {
        guard edit.operation == .replaceLine else {
            return [
                ContentViewRepairSnippet(
                    startLine: 1,
                    endLine: source.components(separatedBy: .newlines).count,
                    text: source
                )
            ]
        }

        let lines = source.components(separatedBy: .newlines)
        let diagnosticIndex = diagnosticLine - 1
        guard lines.indices.contains(diagnosticIndex) else {
            return [fallbackSnippet]
        }

        return [
            ContentViewRepairSnippet(
                startLine: diagnosticLine,
                endLine: diagnosticLine,
                text: lines[diagnosticIndex]
            )
        ]
    }

    func repairBudget(for contentViewErrors: [SwiftCompilerDiagnostic]) -> Int {
        if let maximumModelRepairAttempts = context.pipelineConfiguration.maximumModelRepairAttempts {
            return maximumModelRepairAttempts
        }
        let estimatedPassesForCurrentErrors = max(
            1,
            ContentViewRepairSupport.estimatedRepairGroupCount(
                from: contentViewErrors,
                maximumCount: repairDiagnosticBatchLimit(for: contentViewErrors)
            )
        )
        let dynamicBudget = estimatedPassesForCurrentErrors + context.repairStrategy.repairSlackAttempts
        let requestedFloor = context.repairStrategy.minimumRepairAttempts
        let ceiling = context.repairStrategy.maximumRepairAttempts
        return min(ceiling, max(requestedFloor, dynamicBudget))
    }
}
