import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func makeRepairPromptPlan(
        source: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> RepairPromptPlan {
        let maximumDiffHunks = context.repairStrategy.maxHunksPerTurn
        let targetDiagnostics = ContentViewRepairSupport.selectedDiagnosticGroup(
            from: diagnostics,
            maximumCount: repairDiagnosticBatchLimit(for: diagnostics)
        )
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
            maximumDiffHunks: maximumDiffHunks,
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
        let maximumDiffHunks = promptPlan.maximumDiffHunks
        let repairTargetKey = compactRepairTargetLogKey(for: promptPlan)
        if lastLoggedRepairTargetKey == repairTargetKey {
            AgentDiagnosticsLog.append(
                """
                Repair target repeated.
                packageRoot: \(layout.packageRootURL.path)
                maximumDiffHunks: \(diffHunkLimitDescription(maximumDiffHunks))
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
                maximumDiffHunks: \(diffHunkLimitDescription(maximumDiffHunks))
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
            maximumDiffHunks: maximumDiffHunks
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
        let diff: String
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingRepairDiff, nil)
            let draftPath = ToolPackageLayout.pendingContentViewDraftPath
            let response = try await context.streamText(
                in: repairConversation.session,
                to: prompt
            ) { partialDiff in
                try context.write(
                    partialDiff,
                    to: draftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            try Task.checkCancellation()
            diff = response
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

        let sanitizedDiff = ContentViewRepairSupport.sanitizedRepairDiffSummary(diff)
        AgentDiagnosticsLog.append(
            """
            Model repair diff proposed.
            packageRoot: \(layout.packageRootURL.path)
            rawCharacters: \(diff.count)
            sanitizedDiff:
            \(AgentDiagnosticsLog.compactMultiline(sanitizedDiff, limit: AgentDiagnosticsLog.repairDiffLimit))
            """
        )
        let repairedSource: String
        do {
            repairedSource = try ContentViewRepairSupport.applyValidatedDiff(
                sanitizedDiff,
                to: originalSource,
                maximumHunks: maximumDiffHunks
            )
        } catch {
            AgentDiagnosticsLog.append(
                """
                Model repair diff rejected.
                packageRoot: \(layout.packageRootURL.path)
                maxDiffHunks: \(diffHunkLimitDescription(maximumDiffHunks))
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 800))
                sanitizedDiff:
                \(AgentDiagnosticsLog.compactMultiline(sanitizedDiff, limit: AgentDiagnosticsLog.repairDiffLimit))
                """
            )
            throw error
        }
        AgentDiagnosticsLog.append(
            """
            Model repair diff accepted.
            packageRoot: \(layout.packageRootURL.path)
            maxDiffHunks: \(diffHunkLimitDescription(maximumDiffHunks))
            """
        )
        return RepairSourceCandidate(
            source: repairedSource,
            summary: AgentDiagnosticsLog.compact(sanitizedDiff, limit: AgentDiagnosticsLog.repairDiffLimit)
        )
    }

    func compactRepairTargetLogKey(for promptPlan: RepairPromptPlan) -> String {
        let diagnosticKey = promptPlan.targetDiagnostics
            .map { "\($0.line):\($0.column):\($0.message)" }
            .joined(separator: "|")
        let snippetKey = promptPlan.snippets
            .map { "\($0.startLine)-\($0.endLine)" }
            .joined(separator: "|")
        return "\(diffHunkLimitDescription(promptPlan.maximumDiffHunks))::\(diagnosticKey)::\(snippetKey)"
    }

    func repairDiagnosticBatchLimit(for diagnostics: [SwiftCompilerDiagnostic]) -> Int {
        context.repairStrategy.maxHunksPerTurn ?? max(1, diagnostics.count)
    }

    func diffHunkLimitDescription(_ maximumDiffHunks: Int?) -> String {
        maximumDiffHunks.map(String.init) ?? "unlimited"
    }
}
