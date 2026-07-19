import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    static func prepareContentViewSource(
        _ contentViewPath: String,
        layout: ToolPackageLayout,
        context: ToolGenerationRuntimeContext
    ) async throws {
        let source = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        switch context.pipelineConfiguration.sourcePreparationPolicy {
        case .none:
            return
        case .extractModelEnvelope:
            let extracted = ToolGenerationRuntimeContext.cleanedSource(source)
            if extracted != source {
                try context.write(extracted, to: contentViewPath, packageRootURL: layout.packageRootURL)
            }
        case .normalizeAndFormat:
            let normalized = ContentViewSourceCleanup.normalizedSource(source)
            if normalized != source {
                try context.write(normalized, to: contentViewPath, packageRootURL: layout.packageRootURL)
            }

            let url = try context.packageFileURL(for: contentViewPath, packageRootURL: layout.packageRootURL)
            _ = await context.processClient.formatSwiftSource(url)
        }
    }

    func buildCurrentSource(phase: String) async throws -> BuildState? {
        try Task.checkCancellation()
        let result = try await context.processClient.build(layout.packageRootURL)
        try Task.checkCancellation()
        guard !result.succeeded else {
            return nil
        }

        let diagnostics = SwiftPackageProcessClient.parseDiagnostics(
            in: result.combinedOutput,
            packageRootURL: layout.packageRootURL
        )
        logBuildFailure(phase: phase, diagnostics: diagnostics)
        let contentViewErrors = ContentViewRepairSupport.actionableErrors(
            from: diagnostics,
            contentViewPath: contentViewPath
        )
        let source = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        return BuildState(
            result: result,
            diagnostics: diagnostics,
            contentViewErrors: contentViewErrors,
            source: source
        )
    }

    func compiledContentViewIsPlaceholder(phase: String) throws -> Bool {
        let source = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        guard ContentViewSourceCleanup.isPlaceholderScaffold(source) else {
            return false
        }

        AgentDiagnosticsLog.append(
            """
            Compiled ContentView.swift rejected because it only contains the placeholder scaffold.
            phase: \(phase)
            packageRoot: \(layout.packageRootURL.path)
            """
        )
        return true
    }

    func logBuildFailure(
        phase: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) {
        let contentViewErrors = ContentViewRepairSupport.actionableErrors(
            from: diagnostics,
            contentViewPath: contentViewPath
        )
        let otherDiagnostics = diagnostics.filter { diagnostic in
            diagnostic.relativePath != contentViewPath || diagnostic.severity != .error
        }
        let otherDiagnosticsSummary = otherDiagnostics.isEmpty
            ? "No non-ContentView diagnostics."
            : AgentDiagnosticsLog.renderDiagnostics(otherDiagnostics, limit: 4)
        AgentDiagnosticsLog.append(
            """
            Build failed.
            phase: \(phase)
            packageRoot: \(layout.packageRootURL.path)
            executableName: \(layout.executableName)
            diagnosticCount: \(diagnostics.count)
            contentViewErrorCount: \(contentViewErrors.count)
            otherDiagnostics:
            \(otherDiagnosticsSummary)
            contentViewDiagnostics:
            \(AgentDiagnosticsLog.renderDiagnostics(contentViewErrors, limit: AgentDiagnosticsLog.buildFailureDiagnosticLimit, includeSupportingLines: true, supportingLineLimit: AgentDiagnosticsLog.repairRequestSupportingLineLimit))
            """
        )
    }
}
