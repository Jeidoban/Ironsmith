import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func makeRepairPromptPlan(
        source: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> RepairPromptPlan {
        let maximumPatchBlocks = context.repairStrategy.maxPatchBlocksPerTurn
        let targetDiagnostics = context.pipelineConfiguration.batchesRepairDiagnostics
            ? ContentViewRepairSupport.selectedDiagnosticGroup(
                from: diagnostics,
                maximumCount: repairDiagnosticBatchLimit(for: diagnostics)
            )
            : diagnostics
        let immediateSnippets = ContentViewRepairSupport.snippets(
            from: source,
            diagnostics: targetDiagnostics
        )
        let blockSnippets = ContentViewRepairSupport.enclosingEditableBlockSnippets(
            from: source,
            diagnostics: targetDiagnostics,
            excluding: immediateSnippets
        )
        let relatedSnippets = ContentViewRepairSupport.relatedEditableSnippets(
            from: source,
            diagnostics: targetDiagnostics,
            excluding: immediateSnippets + blockSnippets
        )
        let extraEditableSnippets = blockSnippets + relatedSnippets
        return RepairPromptPlan(
            maximumPatchBlocks: maximumPatchBlocks,
            targetDiagnostics: targetDiagnostics,
            snippets: immediateSnippets + extraEditableSnippets
        )
    }

    func repairOutcomeSummary(_ outcome: String, repairSummary: String) -> String {
        guard !repairSummary.isEmpty else { return outcome }
        return """
        \(outcome)
        Applied repair:
        \(repairSummary)
        """
    }

    func makeRepairCandidateSource(
        originalSource: String,
        diagnostics: [SwiftCompilerDiagnostic],
        repairConversation: ContentViewRepairConversation,
        attempt: Int,
        lastLoggedRepairTargetKey: inout String?
    ) async throws -> RepairSourceCandidate {
        let promptPlan = makeRepairPromptPlan(
            source: originalSource,
            diagnostics: diagnostics
        )
        let maximumPatchBlocks = promptPlan.maximumPatchBlocks
        let repairTargetKey = compactRepairTargetLogKey(for: promptPlan)
        if lastLoggedRepairTargetKey == repairTargetKey {
            AgentDiagnosticsLog.append(
                """
                Repair target repeated.
                packageRoot: \(layout.packageRootURL.path)
                maximumPatchBlocks: \(maximumPatchBlocks)
                selectedDiagnosticCount: \(promptPlan.targetDiagnostics.count)
                diagnostics:
                \(AgentDiagnosticsLog.renderDiagnostics(promptPlan.targetDiagnostics, limit: 4))
                """
            )
        } else {
            lastLoggedRepairTargetKey = repairTargetKey
            AgentDiagnosticsLog.append(
                """
                Repair target selected.
                packageRoot: \(layout.packageRootURL.path)
                maximumPatchBlocks: \(maximumPatchBlocks)
                selectedDiagnosticCount: \(promptPlan.targetDiagnostics.count)
                diagnostics:
                \(AgentDiagnosticsLog.renderDiagnostics(promptPlan.targetDiagnostics, limit: 8, includeSupportingLines: true, supportingLineLimit: AgentDiagnosticsLog.repairRequestSupportingLineLimit))
                relevantExcerpts:
                \(AgentDiagnosticsLog.renderRepairSnippets(promptPlan.snippets))
                """
            )
        }
        let prompt = repairConversation.repairPrompt(
            diagnostics: promptPlan.targetDiagnostics,
            source: originalSource,
            editableSnippets: promptPlan.snippets,
            maximumPatchBlocks: maximumPatchBlocks
        )
        AgentDiagnosticsLog.append(
            """
            Model repair request.
            packageRoot: \(layout.packageRootURL.path)
            promptMode: conversational
            attempt: \(attempt)
            diagnosticCount: \(promptPlan.targetDiagnostics.count)
            sourceIncluded: \(prompt.contains("Current authoritative ContentView.swift:"))
            relevantExcerptCount: \(promptPlan.snippets.count)
            """
        )
        let patch: String
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingRepairDiff, nil)
            let draftPath = ToolPackageLayout.pendingContentViewDraftPath
            let response = try await context.streamText(
                in: repairConversation.session,
                to: prompt
            ) { partialPatch in
                try context.write(
                    partialPatch,
                    to: draftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            try Task.checkCancellation()
            patch = response
        } catch {
            try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
            AgentDiagnosticsLog.append(
                """
                Model repair request failed.
                packageRoot: \(layout.packageRootURL.path)
                promptMode: conversational
                error:
                \(AgentDiagnosticsLog.renderError(error))
                """
            )
            throw error
        }

        let sanitizedPatch = ContentViewRepairSupport.sanitizedSearchReplacePatchSummary(patch)
        AgentDiagnosticsLog.append(
            """
            Model repair patch proposed.
            packageRoot: \(layout.packageRootURL.path)
            rawCharacters: \(patch.count)
            sanitizedPatch:
            \(AgentDiagnosticsLog.compactMultiline(sanitizedPatch, limit: AgentDiagnosticsLog.repairPatchLimit))
            """
        )
        let repairedSource: String
        do {
            repairedSource = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                sanitizedPatch,
                to: originalSource,
                maximumPatchBlocks: maximumPatchBlocks
            )
        } catch {
            AgentDiagnosticsLog.append(
                """
                Model repair patch rejected.
                packageRoot: \(layout.packageRootURL.path)
                maximumPatchBlocks: \(maximumPatchBlocks)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 800))
                sanitizedPatch:
                \(AgentDiagnosticsLog.compactMultiline(sanitizedPatch, limit: AgentDiagnosticsLog.repairPatchLimit))
                """
            )
            throw error
        }
        AgentDiagnosticsLog.append(
            """
            Model repair patch accepted.
            packageRoot: \(layout.packageRootURL.path)
            maximumPatchBlocks: \(maximumPatchBlocks)
            """
        )
        return RepairSourceCandidate(
            source: repairedSource,
            summary: AgentDiagnosticsLog.compact(sanitizedPatch, limit: AgentDiagnosticsLog.repairPatchLimit)
        )
    }

    func compactRepairTargetLogKey(for promptPlan: RepairPromptPlan) -> String {
        let diagnosticKey = promptPlan.targetDiagnostics
            .map { "\($0.line):\($0.column):\($0.message)" }
            .joined(separator: "|")
        let snippetKey = promptPlan.snippets
            .map { "\($0.startLine)-\($0.endLine)" }
            .joined(separator: "|")
        return "\(promptPlan.maximumPatchBlocks)::\(diagnosticKey)::\(snippetKey)"
    }

    func repairDiagnosticBatchLimit(for diagnostics: [SwiftCompilerDiagnostic]) -> Int {
        guard context.pipelineConfiguration.batchesRepairDiagnostics else {
            return max(1, diagnostics.count)
        }
        return context.repairStrategy.maxPatchBlocksPerTurn
    }
}
