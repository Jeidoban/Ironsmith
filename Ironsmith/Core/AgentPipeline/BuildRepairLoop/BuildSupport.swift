import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    enum SourceMutationOrigin: Equatable {
        case deterministicRepair
        case modelRepair
    }

    struct SourceMutationRequest {
        let source: String
        let originalSource: String
        let previousContentViewErrorCount: Int
        let phase: String
        let rollbackSubject: String
        let allowsIncreasedContentViewErrors: Bool
        let origin: SourceMutationOrigin

        init(
            source: String,
            originalSource: String,
            previousContentViewErrorCount: Int,
            phase: String,
            rollbackSubject: String,
            allowsIncreasedContentViewErrors: Bool = false,
            origin: SourceMutationOrigin
        ) {
            self.source = source
            self.originalSource = originalSource
            self.previousContentViewErrorCount = previousContentViewErrorCount
            self.phase = phase
            self.rollbackSubject = rollbackSubject
            self.allowsIncreasedContentViewErrors = allowsIncreasedContentViewErrors
            self.origin = origin
        }
    }

    func betterCandidate(
        current: SourceCandidate?,
        source: String,
        diagnostics: [SwiftCompilerDiagnostic],
        contentViewErrorCount: Int,
        phase: String
    ) -> SourceCandidate {
        let candidate = SourceCandidate(
            source: source,
            diagnostics: diagnostics,
            contentViewErrorCount: contentViewErrorCount,
            phase: phase
        )
        guard let current else {
            return candidate
        }
        if contentViewErrorCount < current.contentViewErrorCount {
            return candidate
        }
        if contentViewErrorCount == current.contentViewErrorCount,
           diagnostics.count < current.diagnostics.count {
            return candidate
        }
        return current
    }

    func recordBestCandidate(
        from state: BuildState,
        phase: String,
        bestCandidate: inout SourceCandidate?
    ) {
        bestCandidate = betterCandidate(
            current: bestCandidate,
            source: state.source,
            diagnostics: state.diagnostics,
            contentViewErrorCount: state.contentViewErrors.count,
            phase: phase
        )
    }

    func increment(_ counts: inout [String: Int], for key: String) -> Int {
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        return count
    }

    func restoreBestCandidateAndFail(
        _ bestCandidate: SourceCandidate?,
        lastFailedState: BuildState?,
        fallbackMessage: String?,
        failureRecovery: FailureRecovery
    ) throws {
        switch failureRecovery {
        case .restoreBestCandidate:
            if let bestCandidate {
                try context.write(bestCandidate.source, to: contentViewPath, packageRootURL: layout.packageRootURL)
                AgentDiagnosticsLog.append(
                    """
                    Restored best ContentView.swift candidate.
                    packageRoot: \(layout.packageRootURL.path)
                    phase: \(bestCandidate.phase)
                    contentViewErrorCount: \(bestCandidate.contentViewErrorCount)
                    """
                )
            }
        case .preserveCurrentSource:
            AgentDiagnosticsLog.append(
                """
                Preserved current ContentView.swift after failed generation.
                packageRoot: \(layout.packageRootURL.path)
                """
            )
        case .restoreOriginalSource(let originalSource),
             .restoreOriginalSourceAfterFailurePreservingInterruptedSource(let originalSource):
            try context.write(originalSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
            AgentDiagnosticsLog.append(
                """
                Restored original ContentView.swift after failed edit.
                packageRoot: \(layout.packageRootURL.path)
                """
            )
        }

        if let fallbackMessage, !fallbackMessage.isEmpty {
            throw ToolGenerationError.compileFailed(fallbackMessage)
        }
        if let lastFailedState {
            let remainingErrors = lastFailedState.contentViewErrors.count
            if remainingErrors > 0 {
                throw ToolGenerationError.compileFailed("ContentView.swift still has \(remainingErrors) compiler errors after generation and repair attempts.")
            }
            throw ToolGenerationError.compileFailed(SwiftPackageProcessClient.compilerExcerpt(from: lastFailedState.result.combinedOutput))
        }
        throw ToolGenerationError.compileFailed("ContentView.swift did not compile after generation and repair attempts.")
    }

    func restoreInterruptedSource(
        _ bestCandidate: SourceCandidate?,
        failureRecovery: FailureRecovery
    ) throws {
        switch failureRecovery {
        case .restoreBestCandidate:
            if let bestCandidate {
                try context.write(bestCandidate.source, to: contentViewPath, packageRootURL: layout.packageRootURL)
                AgentDiagnosticsLog.append(
                    """
                    Restored best ContentView.swift candidate after interruption.
                    packageRoot: \(layout.packageRootURL.path)
                    phase: \(bestCandidate.phase)
                    contentViewErrorCount: \(bestCandidate.contentViewErrorCount)
                    """
                )
            }
        case .preserveCurrentSource:
            AgentDiagnosticsLog.append(
                """
                Preserved current ContentView.swift after interruption.
                packageRoot: \(layout.packageRootURL.path)
                """
            )
        case .restoreOriginalSource(let originalSource):
            try context.write(originalSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
            AgentDiagnosticsLog.append(
                """
                Restored original ContentView.swift after interrupted edit.
                packageRoot: \(layout.packageRootURL.path)
                """
            )
        case .restoreOriginalSourceAfterFailurePreservingInterruptedSource(_):
            AgentDiagnosticsLog.append(
                """
                Preserved current ContentView.swift after interrupted edit.
                packageRoot: \(layout.packageRootURL.path)
                """
            )
        }
    }

    static func isRetryableCandidateFailure(_ error: any Error) -> Bool {
        if error is ContentViewRepairSupport.SearchReplacePatchValidationError {
            return true
        }
        guard let generationError = error as? ToolGenerationError else {
            return false
        }
        switch generationError {
        case .invalidRepairPatch, .noRepairPatchCandidate:
            return true
        case .emptyPrompt, .compileFailed, .stoppedToSaveTokens:
            return false
        }
    }

    func compileSourceMutation(
        _ request: SourceMutationRequest
    ) async throws -> SourceMutationBuildResult {
        try Task.checkCancellation()
        try context.write(request.source, to: contentViewPath, packageRootURL: layout.packageRootURL)
        if request.origin == .deterministicRepair {
            try await Self.prepareContentViewSource(contentViewPath, layout: layout, context: context)
        }

        guard let state = try await buildCurrentSource(phase: request.phase) else {
            if try compiledContentViewIsPlaceholder(phase: request.phase) {
                try context.write(request.originalSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
                return .rolledBack
            }
            return .finished
        }

        guard request.allowsIncreasedContentViewErrors
            || state.contentViewErrors.count <= request.previousContentViewErrorCount
        else {
            AgentDiagnosticsLog.append(
                """
                \(request.rollbackSubject) rolled back.
                packageRoot: \(layout.packageRootURL.path)
                previousContentViewErrorCount: \(request.previousContentViewErrorCount)
                newContentViewErrorCount: \(state.contentViewErrors.count)
                """
            )
            try context.write(request.originalSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
            return .rolledBack
        }

        return .accepted(state)
    }

    func skippedRepairReason(for error: any Error) -> SkippedRepairReason? {
        if error is ContentViewRepairSupport.SearchReplacePatchValidationError {
            return .invalidRepairPatch
        }
        guard let generationError = error as? ToolGenerationError else {
            return nil
        }
        switch generationError {
        case .invalidRepairPatch:
            return .invalidRepairPatch
        case .noRepairPatchCandidate:
            return .noDeterministicRepair
        case .emptyPrompt, .compileFailed, .stoppedToSaveTokens:
            return nil
        }
    }

    func logSkippedRepairAttempt(
        reason: SkippedRepairReason,
        attempt: Int,
        remainingBudget: Int,
        contentViewErrors: [SwiftCompilerDiagnostic]
    ) {
        AgentDiagnosticsLog.append(
            """
            Repair attempt skipped after \(reason.logTitle).
            packageRoot: \(layout.packageRootURL.path)
            attempt: \(attempt)
            remainingBudget: \(remainingBudget)
            currentDiagnostics:
            \(AgentDiagnosticsLog.renderDiagnostics(contentViewErrors, limit: 4))
            """
        )
    }
}
