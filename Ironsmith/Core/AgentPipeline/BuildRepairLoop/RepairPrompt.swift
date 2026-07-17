import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func makeRepairPromptPlan(
        source: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> RepairPromptPlan {
        let maximumPatchBlocks = context.repairStrategy.maxPatchBlocksPerTurn
        let diagnosticLimit = repairDiagnosticBatchLimit(for: diagnostics)
        let targetDiagnostics = context.pipelineConfiguration.batchesRepairDiagnostics
            ? ContentViewRepairSupport.selectedDiagnosticGroup(
                from: diagnostics,
                maximumCount: diagnosticLimit
            )
            : Array(diagnostics.prefix(diagnosticLimit))
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
        let allSnippets = immediateSnippets + blockSnippets + relatedSnippets
        let snippets = context.pipelineConfiguration.batchesRepairDiagnostics
            ? allSnippets
            : Array(allSnippets.prefix(ToolGenerationRepairPolicy.largeModelMaximumRepairDiagnostics))
        return RepairPromptPlan(
            maximumPatchBlocks: maximumPatchBlocks,
            targetDiagnostics: targetDiagnostics,
            snippets: snippets
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
            let response = try await context.languageModelInvoker.respond(
                stage: .codingAgent,
                in: repairConversation.session,
                to: prompt,
                generating: String.self
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

        let sanitizedPatch: String
        switch context.sourcePatchFormat {
        case .searchReplace:
            sanitizedPatch = ContentViewRepairSupport.sanitizedSearchReplacePatchSummary(patch)
        case .unifiedDiff:
            sanitizedPatch = ContentViewRepairSupport.sanitizedDiffSummary(patch)
        }
        AgentDiagnosticsLog.append(
            """
            Model repair patch proposed.
            packageRoot: \(layout.packageRootURL.path)
            rawCharacters: \(patch.count)
            sanitizedPatch:
            \(sanitizedPatch)
            """
        )
        let repairedSource: String
        do {
            switch context.sourcePatchFormat {
            case .searchReplace:
                let application = try ContentViewRepairSupport.applySearchReplacePatchBestEffort(
                    sanitizedPatch,
                    to: originalSource,
                    maximumPatchBlocks: maximumPatchBlocks
                )
                repairedSource = application.source
                if !application.skippedBlocks.isEmpty {
                    AgentDiagnosticsLog.append(
                        """
                        Model repair patch partially applied.
                        packageRoot: \(layout.packageRootURL.path)
                        \(application.logSummary)
                        """
                    )
                }
            case .unifiedDiff:
                repairedSource = try ContentViewRepairSupport.applyValidatedDiff(
                    sanitizedPatch,
                    to: originalSource,
                    maximumHunks: maximumPatchBlocks
                )
            }
        } catch {
            AgentDiagnosticsLog.append(
                """
                Model repair patch rejected.
                packageRoot: \(layout.packageRootURL.path)
                maximumPatchBlocks: \(maximumPatchBlocks)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 800))
                sanitizedPatch:
                \(sanitizedPatch)
                """
            )
            throw error
        }
        try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
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
            return min(
                max(1, diagnostics.count),
                ToolGenerationRepairPolicy.largeModelMaximumRepairDiagnostics
            )
        }
        return context.repairStrategy.maxPatchBlocksPerTurn
    }
}
