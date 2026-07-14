import AnyLanguageModel
import Foundation

struct SingleFileToolGenerationRuntime {
    let context: ToolGenerationRuntimeContext

    private struct CreateToolSetup {
        let displayName: String
        let executableName: String
        let bundleIdentifier: String
        let layout: ToolPackageLayout
        let contentViewPath: String
        let iconPrompt: String?
        let settings: ToolGenerationSettings
    }

    func generateTool(
        for prompt: String,
        existingTool: Tool? = nil,
        settings: ToolGenerationSettings,
        imageGenerationProvider: ToolImageGenerationProvider = .disabled,
        lifecycle: ToolGenerationLifecycle = .noop
    ) async throws -> ToolGenerationResult {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ToolGenerationError.emptyPrompt
        }

        if let existingTool {
            let effectivePrompt = existingTool.isGenerationReady
                ? trimmedPrompt
                : Self.savedPrompt(for: existingTool, fallback: trimmedPrompt)
            if !existingTool.isGenerationReady, (existingTool.generationMode ?? .create) == .create {
                return try await createTool(
                    prompt: effectivePrompt,
                    existingTool: existingTool,
                    settings: settings,
                    imageGenerationProvider: imageGenerationProvider,
                    lifecycle: lifecycle
                )
            }
            return try await editTool(
                prompt: effectivePrompt,
                existingTool: existingTool,
                settings: settings,
                lifecycle: lifecycle
            )
        }

        return try await createTool(
            prompt: trimmedPrompt,
            settings: settings,
            imageGenerationProvider: imageGenerationProvider,
            lifecycle: lifecycle
        )
    }

    static func cleanedSource(_ response: String) -> String {
        ToolGenerationRuntimeContext.cleanedSource(response)
    }

    private static func savedPrompt(for tool: Tool, fallback: String) -> String {
        let savedPrompt = tool.pendingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedPrompt, !savedPrompt.isEmpty {
            return savedPrompt
        }
        return fallback
    }

    private func loadCreateSetup(
        for tool: Tool,
        settings: ToolGenerationSettings
    ) -> CreateToolSetup? {
        let layout = ToolPackageLayout(
            packageRootURL: tool.packageRootURL,
            executableName: tool.executableName
        )
        guard context.fileClient.fileExists(layout.packageManifestURL) else {
            return nil
        }
        return CreateToolSetup(
            displayName: tool.name,
            executableName: tool.executableName,
            bundleIdentifier: tool.bundleIdentifier,
            layout: layout,
            contentViewPath: layout.contentViewSourcePath,
            iconPrompt: nil,
            settings: settings
        )
    }

    private func prepareNewCreateSetup(
        metadata: ToolMetadataSuggestion,
        prompt: String,
        settings: ToolGenerationSettings,
        lifecycle: ToolGenerationLifecycle
    ) async throws -> CreateToolSetup {
        let displayName = metadata.displayName
        let resolvedSettings = settings.withMenuBarSystemImage(metadata.menuBarSystemImage)
        let executableName = ToolNameSanitizer.executableName(from: displayName)
        let bundleIdentifier = ToolBundleIdentifier.make(executableName: executableName)
        let packageRootURL = try context.makeUniquePackageRoot(displayName: displayName)
        let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
        let contentViewPath = layout.contentViewSourcePath

        try context.packageMaterializer.materializePackage(
            layout: layout,
            displayName: displayName,
            settings: resolvedSettings
        )
        try await lifecycle.prepareCreatedTool(
            ToolGenerationPreparedTool(
                name: displayName,
                executableName: executableName,
                bundleIdentifier: bundleIdentifier,
                settings: resolvedSettings,
                packageRootURL: packageRootURL
            ),
            prompt
        )

        return CreateToolSetup(
            displayName: displayName,
            executableName: executableName,
            bundleIdentifier: bundleIdentifier,
            layout: layout,
            contentViewPath: contentViewPath,
            iconPrompt: metadata.iconPrompt,
            settings: resolvedSettings
        )
    }

    private func preparePlaceholderCreateTool(
        prompt: String,
        settings: ToolGenerationSettings,
        lifecycle: ToolGenerationLifecycle
    ) async throws {
        let displayName = "New App"
        let executableName = ToolNameSanitizer.executableName(from: displayName)
        let packageRootURL = try context.makeUniquePackageRoot(displayName: displayName)
        try await lifecycle.prepareCreatedTool(
            ToolGenerationPreparedTool(
                name: displayName,
                executableName: executableName,
                bundleIdentifier: ToolBundleIdentifier.make(executableName: executableName),
                settings: settings,
                packageRootURL: packageRootURL
            ),
            prompt
        )
    }

    private func createTool(
        prompt: String,
        existingTool: Tool? = nil,
        settings: ToolGenerationSettings,
        imageGenerationProvider: ToolImageGenerationProvider,
        lifecycle: ToolGenerationLifecycle
    ) async throws -> ToolGenerationResult {
        let startingPhase = existingTool?.generationPhase ?? .initializing
        let setup: CreateToolSetup
        if let existingTool, let resumedSetup = loadCreateSetup(for: existingTool, settings: settings) {
            setup = resumedSetup
        } else {
            if existingTool == nil {
                try await preparePlaceholderCreateTool(
                    prompt: prompt,
                    settings: settings,
                    lifecycle: lifecycle
                )
            }
            try await lifecycle.updatePhase(.generating, .planning, nil)
            try Task.checkCancellation()
            let metadata = await context.metadataClient.suggestMetadata(
                userPrompt: prompt,
                invoker: context.languageModelInvoker
            )
            try Task.checkCancellation()
            setup = try await prepareNewCreateSetup(
                metadata: metadata,
                prompt: prompt,
                settings: settings,
                lifecycle: lifecycle
            )
        }

        AgentDiagnosticsLog.append(
            """
            Tool generation started.
            mode: create
            displayName: \(setup.displayName)
            executableName: \(setup.executableName)
            packageRoot: \(setup.layout.packageRootURL.path)
            phase: \(startingPhase.rawValue)
            prompt: \(AgentDiagnosticsLog.compact(prompt, limit: 240))
            """
        )

        do {
            try Task.checkCancellation()
            let iconTask = Task {
                try await generateIconAssets(
                    displayName: setup.displayName,
                    iconPrompt: setup.iconPrompt,
                    layout: setup.layout,
                    imageGenerationProvider: imageGenerationProvider
                )
            }
            defer { iconTask.cancel() }

            let contentPrompt: String
            if startingPhase == .generatingSource
                || startingPhase == .generatingRepairDiff
                || startingPhase == .repairing
                || startingPhase == .waitingForIcon
                || startingPhase == .packaging
                || startingPhase == .completed {
                contentPrompt = prompt
            } else {
                contentPrompt = try await contentGenerationPrompt(
                    for: prompt,
                    appKind: setup.settings.appKind,
                    sandboxEnabled: setup.settings.sandboxEnabled,
                    lifecycle: lifecycle
                )
            }

            if startingPhase == .waitingForIcon || startingPhase == .packaging || startingPhase == .completed {
                return try await packageTool(
                    displayName: setup.displayName,
                    executableName: setup.executableName,
                    bundleIdentifier: setup.bundleIdentifier,
                    packageRootURL: setup.layout.packageRootURL,
                    settings: setup.settings,
                    iconPrompt: setup.iconPrompt,
                    iconTask: iconTask,
                    lifecycle: lifecycle
                )
            }

            if context.pipelineConfiguration.codingAgent == .codex {
                try await generateWithCodexAgent(
                    displayName: setup.displayName,
                    layout: setup.layout,
                    contentViewPath: setup.contentViewPath,
                    userPrompt: contentPrompt,
                    settings: setup.settings,
                    lifecycle: lifecycle
                )
                return try await packageTool(
                    displayName: setup.displayName,
                    executableName: setup.executableName,
                    bundleIdentifier: setup.bundleIdentifier,
                    packageRootURL: setup.layout.packageRootURL,
                    settings: setup.settings,
                    iconPrompt: setup.iconPrompt,
                    iconTask: iconTask,
                    lifecycle: lifecycle
                )
            }

            let generator = createGenerator(
                userPrompt: contentPrompt,
                appKind: setup.settings.appKind,
                sandboxEnabled: setup.settings.sandboxEnabled,
                layout: setup.layout,
                contentViewPath: setup.contentViewPath,
                lifecycle: lifecycle,
                resumePartialSource: startingPhase == .generatingSource,
                useCurrentSourceOnFirstAttempt: startingPhase == .repairing || startingPhase == .generatingRepairDiff,
                resumePartialRepairPatch: startingPhase == .generatingRepairDiff
            )
            try await compileGeneratedTool(
                displayName: setup.displayName,
                layout: setup.layout,
                contentViewPath: setup.contentViewPath,
                generator: generator,
                lifecycle: lifecycle
            )

            return try await packageTool(
                displayName: setup.displayName,
                executableName: setup.executableName,
                bundleIdentifier: setup.bundleIdentifier,
                packageRootURL: setup.layout.packageRootURL,
                settings: setup.settings,
                iconPrompt: setup.iconPrompt,
                iconTask: iconTask,
                lifecycle: lifecycle
            )
        } catch is CancellationError {
            if !lifecycle.preservesCreatedPackageOnCancellation {
                try? context.fileClient.removeItemIfExists(setup.layout.packageRootURL)
            }
            throw CancellationError()
        }
    }

    private func contentGenerationPrompt(
        for prompt: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool,
        lifecycle: ToolGenerationLifecycle
    ) async throws -> String {
        try await lifecycle.updatePhase(.generating, .refiningPrompt, nil)
        try Task.checkCancellation()
        guard context.promptRefinementEnabled else {
            return prompt
        }

        let refinedPrompt = await context.promptRefinementClient.refinePrompt(
            userPrompt: prompt,
            invoker: context.languageModelInvoker,
            appKind: appKind,
            sandboxEnabled: sandboxEnabled
        )
        try Task.checkCancellation()
        guard let refinedPrompt else {
            return prompt
        }
        try await lifecycle.updatePendingPrompt(refinedPrompt)
        return refinedPrompt
    }

    private func editTool(
        prompt: String,
        existingTool: Tool,
        settings: ToolGenerationSettings,
        lifecycle: ToolGenerationLifecycle
    ) async throws -> ToolGenerationResult {
        let layout = ToolPackageLayout(
            packageRootURL: existingTool.packageRootURL,
            executableName: existingTool.executableName
        )
        let contentViewPath = layout.contentViewSourcePath
        let startingPhase = existingTool.isGenerationReady
            ? ToolGenerationPhase.planning
            : (existingTool.generationPhase ?? .generatingEditDiff)
        if !existingTool.isGenerationReady,
           startingPhase == .packaging || startingPhase == .completed {
            return try await packageTool(
                displayName: existingTool.name,
                executableName: existingTool.executableName,
                bundleIdentifier: existingTool.bundleIdentifier,
                packageRootURL: existingTool.packageRootURL,
                settings: settings,
                iconPrompt: nil,
                lifecycle: lifecycle
            )
        }
        let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        let existingAppEntrySource = try context.readIfPresent(
            layout.appEntrySourcePath,
            packageRootURL: layout.packageRootURL
        )
        let backup = try context.versionBackupClient.stageCurrentVersion(
            layout.packageRootURL,
            contentViewPath,
            existingTool.generationSettings(defaults: settings)
        )

        AgentDiagnosticsLog.append(
            """
            Tool generation started.
            mode: edit
            displayName: \(existingTool.name)
            executableName: \(existingTool.executableName)
            packageRoot: \(existingTool.packageRootURL.path)
            phase: \(startingPhase.rawValue)
            prompt: \(AgentDiagnosticsLog.compact(prompt, limit: 240))
            editableFile: \(contentViewPath)
            """
        )

        do {
            try Task.checkCancellation()
            // The model only edits ContentView.swift; Ironsmith owns the fixed app scene wrapper.
            try context.write(
                layout.fixedAppEntrySource(displayName: existingTool.name, settings: settings),
                to: layout.appEntrySourcePath,
                packageRootURL: layout.packageRootURL
            )
            if context.pipelineConfiguration.codingAgent == .codex {
                try await generateWithCodexAgent(
                    displayName: existingTool.name,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    userPrompt: prompt,
                    settings: settings,
                    lifecycle: lifecycle
                )
                try Task.checkCancellation()
                try await lifecycle.updatePhase(.generating, .packaging, nil)
                _ = try await context.appBundleClient.buildInternalApp(
                    ToolAppBundleRequest(
                        displayName: existingTool.name,
                        executableName: existingTool.executableName,
                        bundleIdentifier: existingTool.bundleIdentifier,
                        packageRootURL: existingTool.packageRootURL,
                        settings: settings
                    )
                )
                try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
                try context.versionBackupClient.promoteStagedVersion(backup)
                return ToolGenerationResult(
                    toolName: existingTool.name,
                    executableName: existingTool.executableName,
                    bundleIdentifier: existingTool.bundleIdentifier,
                    settings: settings,
                    packageRootURL: existingTool.packageRootURL
                )
            }
            let generator = editGenerator(
                userPrompt: prompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle,
                resumePartialPatch: startingPhase == .generatingEditDiff,
                resumePartialSource: startingPhase == .generatingSource,
                useCurrentSourceOnFirstAttempt: startingPhase == .repairing || startingPhase == .generatingRepairDiff,
                resumePartialRepairPatch: startingPhase == .generatingRepairDiff
            )
            try await compileGeneratedTool(
                displayName: existingTool.name,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                failureRecovery: .preserveCurrentSource,
                maximumGenerationAttempts: editGenerationAttempts(),
                lifecycle: lifecycle
            )
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .packaging, nil)
            _ = try await context.appBundleClient.buildInternalApp(
                ToolAppBundleRequest(
                    displayName: existingTool.name,
                    executableName: existingTool.executableName,
                    bundleIdentifier: existingTool.bundleIdentifier,
                    packageRootURL: existingTool.packageRootURL,
                    settings: settings
                )
            )
            try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
            try context.versionBackupClient.promoteStagedVersion(backup)
        } catch {
            let isCancellation = IronsmithErrorPresentation.isCancellation(error) || Task.isCancelled
            try? context.write(existingAppEntrySource, to: layout.appEntrySourcePath, packageRootURL: layout.packageRootURL)
            AgentDiagnosticsLog.append(
                """
                Preserved current ContentView.swift after \(isCancellation ? "interrupted" : "failed") edit.
                packageRoot: \(existingTool.packageRootURL.path)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 800))
                """
            )
            throw error
        }

        let binDirectory = try await context.processClient.showBinPath(existingTool.packageRootURL)
        let binaryURL = binDirectory.appendingPathComponent(existingTool.executableName)
        await context.processClient.stripQuarantine(binaryURL)

        return ToolGenerationResult(
            toolName: existingTool.name,
            executableName: existingTool.executableName,
            bundleIdentifier: existingTool.bundleIdentifier,
            settings: settings,
            packageRootURL: existingTool.packageRootURL
        )
    }

    private func compileGeneratedTool(
        displayName: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        generator: ContentViewCandidateGenerator,
        failureRecovery: ContentViewBuildRepairLoop.FailureRecovery = .restoreBestCandidate,
        maximumGenerationAttempts: Int? = nil,
        lifecycle: ToolGenerationLifecycle
    ) async throws {
        try await lifecycle.updatePhase(.generating, .repairing, nil)
        let repairLoop = ContentViewBuildRepairLoop(
            context: context,
            layout: layout,
            displayName: displayName,
            contentViewPath: contentViewPath,
            regenerationThreshold: ToolGenerationRepairPolicy.regenerationThreshold,
            maximumGenerationAttempts: maximumGenerationAttempts
                ?? context.pipelineConfiguration.maximumGenerationAttempts,
            lifecycle: lifecycle
        )
        let effectiveFailureRecovery: ContentViewBuildRepairLoop.FailureRecovery
        switch failureRecovery {
        case .restoreOriginalSource,
             .restoreOriginalSourceAfterFailurePreservingInterruptedSource:
            effectiveFailureRecovery = failureRecovery
        case .restoreBestCandidate, .preserveCurrentSource:
            effectiveFailureRecovery = context.pipelineConfiguration.restoresBestCandidateOnFailure
                ? failureRecovery
                : .preserveCurrentSource
        }
        try await repairLoop.run(
            generator: generator,
            failureRecovery: effectiveFailureRecovery
        )
    }

    private func generateWithCodexAgent(
        displayName: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        userPrompt: String,
        settings: ToolGenerationSettings,
        lifecycle: ToolGenerationLifecycle
    ) async throws {
        guard let authentication = context.codexAgentAuthentication else {
            throw CodexAgentError.missingAuthenticationForRuntime
        }

        try await lifecycle.updatePhase(.generating, .generatingSource, nil)
        AgentDiagnosticsLog.append(
            """
            Codex coding agent started.
            displayName: \(displayName)
            executableName: \(layout.executableName)
            packageRoot: \(layout.packageRootURL.path)
            prompt: \(AgentDiagnosticsLog.compact(userPrompt, limit: 240))
            """
        )
        let protectedFileBaselines = try codexProtectedFileBaselines(layout: layout)

        let request = CodexAgentRequest(
            packageRootURL: layout.packageRootURL,
            executableName: layout.executableName,
            displayName: displayName,
            appKind: settings.appKind,
            sandboxEnabled: settings.sandboxEnabled,
            userPrompt: userPrompt,
            modelIdentifier: context.codingAgentModelIdentifier,
            reasoningEffort: context.reasoningEffort,
            authentication: authentication
        ) { event in
            await Self.handleCodexAgentEvent(event, lifecycle: lifecycle)
        }

        do {
            let result: CodexAgentResult
            do {
                result = try await context.codexAgentClient.run(request)
                await context.languageModelInvoker.recordInvocationCompleted()
            } catch {
                await context.languageModelInvoker.recordInvocationCompleted()
                throw error
            }
            try Task.checkCancellation()
            try validateCodexProtectedFiles(
                layout: layout,
                baselines: protectedFileBaselines
            )
            try await verifyCodexGeneratedSource(
                layout: layout,
                contentViewPath: contentViewPath,
                lifecycle: lifecycle
            )
            AgentDiagnosticsLog.append(
                """
                Codex coding agent completed.
                packageRoot: \(layout.packageRootURL.path)
                transcript: \(result.transcriptURL.path)
                """
            )
        } catch {
            AgentDiagnosticsLog.append(
                """
                Codex coding agent failed.
                packageRoot: \(layout.packageRootURL.path)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 1_500))
                """
            )
            throw error
        }
    }

    private func codexProtectedFileBaselines(layout: ToolPackageLayout) throws -> [String: String] {
        [
            "Package.swift": try context.readIfPresent(
                "Package.swift",
                packageRootURL: layout.packageRootURL
            ),
            layout.appEntrySourcePath: try context.readIfPresent(
                layout.appEntrySourcePath,
                packageRootURL: layout.packageRootURL
            ),
        ]
    }

    private static func handleCodexAgentEvent(
        _ event: CodexAgentEvent,
        lifecycle: ToolGenerationLifecycle
    ) async {
        if let summary = event.diagnosticSummary {
            AgentDiagnosticsLog.append(summary)
        }

        do {
            switch event {
            case .commandExecution, .fileChange, .webSearch, .todoList:
                try await lifecycle.updatePhase(.generating, .repairing, nil)
            case .agentMessage:
                try await lifecycle.updatePhase(.generating, .generatingSource, nil)
            case .turnCompleted:
                try await lifecycle.updatePhase(.generating, .repairing, nil)
            case .error(let message):
                try await lifecycle.updatePhase(.generating, .generatingSource, message)
            case .threadStarted, .turnStarted:
                break
            }
        } catch {
            AgentDiagnosticsLog.append(
                """
                Codex progress update failed.
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
        }
    }

    private func validateCodexProtectedFiles(
        layout: ToolPackageLayout,
        baselines: [String: String]
    ) throws {
        var changedBaselinePaths: [String] = []
        for path in baselines.keys.sorted() {
            guard let baseline = baselines[path] else { continue }
            let current = try context.readIfPresent(path, packageRootURL: layout.packageRootURL)
            if current != baseline {
                changedBaselinePaths.append(path)
            }
        }

        let allowedSwiftPaths: Set<String> = [
            layout.appEntrySourcePath,
            layout.contentViewSourcePath,
        ]
        let disallowedSwiftPaths = try swiftSourcePaths(in: layout)
            .filter { !allowedSwiftPaths.contains($0) }
            .sorted()

        guard let violation = (changedBaselinePaths + disallowedSwiftPaths).first else {
            return
        }

        var cleanupError: Error?
        for path in changedBaselinePaths {
            do {
                try context.write(
                    baselines[path] ?? "",
                    to: path,
                    packageRootURL: layout.packageRootURL
                )
            } catch {
                cleanupError = cleanupError ?? error
            }
        }
        for path in disallowedSwiftPaths {
            do {
                let url = try context.packageFileURL(
                    for: path,
                    packageRootURL: layout.packageRootURL
                )
                try context.fileClient.removeItemIfExists(url)
            } catch {
                cleanupError = cleanupError ?? error
            }
        }

        if let cleanupError {
            throw cleanupError
        }
        throw CodexAgentError.protectedFileChanged(violation)
    }

    private func swiftSourcePaths(in layout: ToolPackageLayout) throws -> [String] {
        guard context.fileClient.fileExists(layout.sourceDirectoryURL) else {
            return []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: layout.sourceDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let packageRootPath = layout.packageRootURL.standardizedFileURL.path
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(packageRootPath + "/") else { continue }
            paths.append(String(standardizedPath.dropFirst(packageRootPath.count + 1)))
        }
        return paths
    }

    private func verifyCodexGeneratedSource(
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle
    ) async throws {
        let contentViewURL = try layout.packageFileURL(for: contentViewPath)
        guard context.fileClient.fileExists(contentViewURL) else {
            throw CodexAgentError.missingContentView
        }

        let sourceBeforeCleanup = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        guard !sourceBeforeCleanup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAgentError.missingContentView
        }

        try await lifecycle.updatePhase(.generating, .repairing, nil)
        try await ContentViewBuildRepairLoop.cleanContentViewSource(
            contentViewPath,
            layout: layout,
            context: context
        )

        let result = try await context.processClient.build(layout.packageRootURL)
        guard result.succeeded else {
            let diagnostics = SwiftPackageProcessClient.parseDiagnostics(
                in: result.combinedOutput,
                packageRootURL: layout.packageRootURL
            )
            let contentViewErrors = ContentViewRepairSupport.actionableErrors(
                from: diagnostics,
                contentViewPath: contentViewPath
            )
            try await lifecycle.updateRepairErrorCount(
                contentViewErrors.isEmpty ? nil : contentViewErrors.count
            )
            AgentDiagnosticsLog.append(
                """
                Codex-generated source failed final verification.
                packageRoot: \(layout.packageRootURL.path)
                contentViewErrorCount: \(contentViewErrors.count)
                diagnostics:
                \(AgentDiagnosticsLog.renderDiagnostics(contentViewErrors, limit: AgentDiagnosticsLog.buildFailureDiagnosticLimit, includeSupportingLines: true, supportingLineLimit: AgentDiagnosticsLog.repairRequestSupportingLineLimit))
                """
            )
            throw ToolGenerationError.compileFailed(
                SwiftPackageProcessClient.compilerExcerpt(from: result.combinedOutput)
            )
        }

        let source = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        if ContentViewSourceCleanup.isPlaceholderScaffold(source) {
            throw ToolGenerationError.compileFailed(
                "ContentView.swift compiled but only contains the placeholder Generated App scaffold."
            )
        }
        try await lifecycle.updateRepairErrorCount(nil)
    }

    private func editGenerationAttempts() -> Int {
        guard context.repairStrategy.usesModelRepair else {
            return context.pipelineConfiguration.maximumGenerationAttempts
        }
        return max(
            context.pipelineConfiguration.maximumGenerationAttempts,
            ToolGenerationRepairPolicy.minimumEditPatchGenerationAttempts
        )
    }

    private func generateIconAssets(
        displayName: String,
        iconPrompt: String?,
        layout: ToolPackageLayout,
        imageGenerationProvider: ToolImageGenerationProvider
    ) async throws {
        do {
            try Task.checkCancellation()
            _ = try await context.iconClient.ensureIconAssets(
                ToolIconRequest(
                    displayName: displayName,
                    iconPrompt: iconPrompt,
                    layout: layout,
                    imageProvider: imageGenerationProvider
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AgentDiagnosticsLog.append(
                """
                Early icon generation failed; packaging can retry.
                displayName: \(displayName)
                packageRoot: \(layout.packageRootURL.path)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
        }
    }

    private func createGenerator(
        userPrompt: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool,
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle,
        resumePartialSource: Bool,
        useCurrentSourceOnFirstAttempt: Bool,
        resumePartialRepairPatch: Bool
    ) -> ContentViewCandidateGenerator {
        var didUseCurrentSource = false
        var didAttemptContinuation = false
        let originalPrompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            sandboxEnabled: sandboxEnabled,
            appKind: appKind
        )

        return ContentViewCandidateGenerator(
            modeDescription: resumePartialSource ? "continue create" : "create"
        ) { session in
            if useCurrentSourceOnFirstAttempt && !didUseCurrentSource {
                didUseCurrentSource = true
                if resumePartialRepairPatch {
                    let currentSource = try context.readIfPresent(
                        contentViewPath,
                        packageRootURL: layout.packageRootURL
                    )
                    try? applyCompletedPendingPatchBlocksAndClearDraft(
                        layout: layout,
                        contentViewPath: contentViewPath,
                        originalSource: currentSource,
                        maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn
                    )
                }
                let currentSource = try context.readIfPresent(
                    contentViewPath,
                    packageRootURL: layout.packageRootURL
                )
                if !currentSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
            }

            if resumePartialSource && !didAttemptContinuation {
                didAttemptContinuation = true
                let partialSource = try context.readIfPresent(
                    ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
                if !partialSource.isEmpty {
                    do {
                        try await continueSourceDraft(
                            partialSource: partialSource,
                            originalPrompt: originalPrompt,
                            layout: layout,
                            contentViewPath: contentViewPath,
                            lifecycle: lifecycle,
                            session: session
                        )
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        AgentDiagnosticsLog.append(
                            """
                            Source continuation failed; requesting a fresh source file.
                            packageRoot: \(layout.packageRootURL.path)
                            error:
                            \(AgentDiagnosticsLog.renderError(error, limit: 800))
                            """
                        )
                    }
                }
            }

            try await regenerateCreatedContentView(
                userPrompt: userPrompt,
                appKind: appKind,
                sandboxEnabled: sandboxEnabled,
                layout: layout,
                contentViewPath: contentViewPath,
                lifecycle: lifecycle,
                session: session
            )
        }
    }

    private func editGenerator(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        lifecycle: ToolGenerationLifecycle,
        resumePartialPatch: Bool,
        resumePartialSource: Bool,
        useCurrentSourceOnFirstAttempt: Bool,
        resumePartialRepairPatch: Bool
    ) -> ContentViewCandidateGenerator {
        if resumePartialSource || (!context.repairStrategy.usesModelRepair && !useCurrentSourceOnFirstAttempt) {
            return wholeFileEditGenerator(
                userPrompt: userPrompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle,
                resumePartialSource: resumePartialSource
            )
        }

        var didApplyResumedPatchDraft = false
        var didUseCurrentSource = false
        var currentExistingSource = existingSource
        var previousPatchFailure: String?

        return ContentViewCandidateGenerator(
            modeDescription: "edit",
            instructions: ToolGenerationPrompts.searchReplaceEditInstructions,
            retriesInvalidCandidates: true,
            invalidCandidateFallback: context.pipelineConfiguration
                .fallsBackToWholeFileEditAfterInvalidInitialPatch
                ? ContentViewCandidateGenerator.InvalidCandidateFallback(
                    threshold: ToolGenerationRepairPolicy.invalidInitialEditPatchesBeforeFullFileEdit,
                    modeDescription: "edit whole-file fallback"
                ) { session in
                    try await regenerateEditedContentView(
                        userPrompt: userPrompt,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        existingSource: existingSource,
                        lifecycle: lifecycle,
                        session: session
                    )
                }
                : nil
        ) { session in
            if useCurrentSourceOnFirstAttempt && !didUseCurrentSource {
                didUseCurrentSource = true
                if resumePartialRepairPatch {
                    let currentSource = try context.readIfPresent(
                        contentViewPath,
                        packageRootURL: layout.packageRootURL
                    )
                    try? applyCompletedPendingPatchBlocksAndClearDraft(
                        layout: layout,
                        contentViewPath: contentViewPath,
                        originalSource: currentSource,
                        maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn
                    )
                }
                currentExistingSource = try context.readIfPresent(
                    contentViewPath,
                    packageRootURL: layout.packageRootURL
                )
                if !currentExistingSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
            }

            if resumePartialPatch && !didApplyResumedPatchDraft {
                didApplyResumedPatchDraft = true
                let partialPatch = try context.readIfPresent(
                    ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
                if !partialPatch.isEmpty {
                    try? applyCompletedPendingPatchBlocksAndClearDraft(
                        layout: layout,
                        contentViewPath: contentViewPath,
                        originalSource: currentExistingSource,
                        maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn
                    )
                    currentExistingSource = try context.readIfPresent(
                        contentViewPath,
                        packageRootURL: layout.packageRootURL
                    )
                }
            }

            if !context.repairStrategy.usesModelRepair {
                try await regenerateEditedContentView(
                    userPrompt: userPrompt,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    existingSource: existingSource,
                    lifecycle: lifecycle,
                    session: session
                )
                return
            }

            do {
                try await regenerateEditedContentViewPatch(
                    userPrompt: userPrompt,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    existingSource: currentExistingSource,
                    maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn,
                    previousPatchFailure: previousPatchFailure,
                    lifecycle: lifecycle,
                    session: session
                )
                previousPatchFailure = nil
            } catch {
                previousPatchFailure = AgentDiagnosticsLog.renderError(error, limit: 800)
                throw error
            }
        }
    }

    private func wholeFileEditGenerator(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        lifecycle: ToolGenerationLifecycle,
        resumePartialSource: Bool
    ) -> ContentViewCandidateGenerator {
        var didAttemptContinuation = false
        let originalPrompt = ToolGenerationPrompts.singleFileEditPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource
        )

        return ContentViewCandidateGenerator(
            modeDescription: resumePartialSource ? "continue edit source" : "edit"
        ) { session in
            if resumePartialSource && !didAttemptContinuation {
                didAttemptContinuation = true
                let partialSource = try context.readIfPresent(
                    ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
                if !partialSource.isEmpty {
                    try await continueSourceDraft(
                        partialSource: partialSource,
                        originalPrompt: originalPrompt,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        lifecycle: lifecycle,
                        session: session
                    )
                    return
                }
            }

            try await regenerateEditedContentView(
                userPrompt: userPrompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle,
                session: session
            )
        }
    }

    private func continueSourceDraft(
        partialSource: String,
        originalPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.sourceContinuationPrompt(
            originalPrompt: originalPrompt,
            partialSource: partialSource
        )
        do {
            try await lifecycle.updatePhase(.generating, .generatingSource, nil)
            let continuation = try await context.languageModelInvoker.respond(
                stage: .codingAgent,
                in: session,
                to: prompt,
                generating: String.self
            ) { partialContinuation in
                try context.write(
                    partialSource + partialContinuation,
                    to: ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            try context.write(
                partialSource + continuation,
                to: contentViewPath,
                packageRootURL: layout.packageRootURL
            )
        } catch {
            try trimPendingSourceDraftToCleanBoundary(layout: layout)
            throw error
        }
    }

    private func packageTool(
        displayName: String,
        executableName: String,
        bundleIdentifier: String,
        packageRootURL: URL,
        settings: ToolGenerationSettings,
        iconPrompt: String?,
        iconTask: Task<Void, Error>? = nil,
        lifecycle: ToolGenerationLifecycle
    ) async throws -> ToolGenerationResult {
        let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
        try Task.checkCancellation()
        let binDirectory = try await context.processClient.showBinPath(packageRootURL)
        let binaryURL = binDirectory.appendingPathComponent(executableName)
        await context.processClient.stripQuarantine(binaryURL)

        try Task.checkCancellation()
        if let iconTask {
            try await lifecycle.updatePhase(.generating, .waitingForIcon, nil)
            try await iconTask.value
        }
        try Task.checkCancellation()
        try await lifecycle.updatePhase(.generating, .packaging, nil)
        _ = try await context.appBundleClient.buildInternalApp(
            ToolAppBundleRequest(
                displayName: displayName,
                executableName: executableName,
                bundleIdentifier: bundleIdentifier,
                packageRootURL: packageRootURL,
                settings: settings,
                iconPrompt: iconPrompt
            )
        )

        try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
        return ToolGenerationResult(
            toolName: displayName,
            executableName: executableName,
            bundleIdentifier: bundleIdentifier,
            settings: settings,
            packageRootURL: packageRootURL
        )
    }

    private func trimPendingSourceDraftToCleanBoundary(layout: ToolPackageLayout) throws {
        let draft = try context.readIfPresent(
            ToolPackageLayout.pendingContentViewDraftPath,
            packageRootURL: layout.packageRootURL
        )
        guard !draft.isEmpty else { return }
        let trimmed = Self.sourcePrefixAtCleanBoundary(draft)
        try context.write(
            trimmed,
            to: ToolPackageLayout.pendingContentViewDraftPath,
            packageRootURL: layout.packageRootURL
        )
    }

    private static func sourcePrefixAtCleanBoundary(_ source: String) -> String {
        let trimmedRight = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRight.isEmpty else { return "" }
        let lastLine = trimmedRight.components(separatedBy: .newlines).last ?? trimmedRight
        if isCleanTrailingSourceLine(lastLine) {
            return trimmedRight
        }
        guard let lastNewline = trimmedRight.lastIndex(of: "\n") else {
            return ""
        }
        return String(trimmedRight[..<lastNewline]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCleanTrailingSourceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let quoteCount = trimmed.filter { $0 == "\"" }.count
        if !quoteCount.isMultiple(of: 2) { return false }
        if trimmed.hasPrefix("import "), trimmed.split(separator: " ").count >= 2 { return true }
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed.hasSuffix(")") || trimmed.hasSuffix("]") {
            return true
        }
        if trimmed.hasSuffix(",") || trimmed.hasSuffix(";") { return true }
        return false
    }

    private func applyCompletedPendingPatchBlocksAndClearDraft(
        layout: ToolPackageLayout,
        contentViewPath: String,
        originalSource: String,
        maximumPatchBlocks: Int
    ) throws {
        defer {
            try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
        }
        let draft = try context.readIfPresent(
            ToolPackageLayout.pendingContentViewDraftPath,
            packageRootURL: layout.packageRootURL
        )
        guard !draft.isEmpty else { return }
        if context.pipelineConfiguration.codingAgent == .ironsmithFlame {
            let application = try ContentViewRepairSupport.applySearchReplacePatchBestEffort(
                draft,
                to: originalSource,
                maximumPatchBlocks: maximumPatchBlocks
            )
            try context.write(application.source, to: contentViewPath, packageRootURL: layout.packageRootURL)
            AgentDiagnosticsLog.append(
                """
                Applied completed edit patch blocks from interrupted draft.
                packageRoot: \(layout.packageRootURL.path)
                \(application.logSummary)
                """
            )
        } else {
            guard let application = try ContentViewRepairSupport.applyCompletedSearchReplacePatchBlocks(
                draft,
                to: originalSource,
                maximumPatchBlocks: maximumPatchBlocks
            ) else {
                AgentDiagnosticsLog.append(
                    """
                    Cleared interrupted edit patch draft with no completed patch blocks.
                    packageRoot: \(layout.packageRootURL.path)
                    """
                )
                return
            }
            try context.write(application.source, to: contentViewPath, packageRootURL: layout.packageRootURL)
            AgentDiagnosticsLog.append(
                """
                Applied completed edit patch blocks from interrupted draft.
                packageRoot: \(layout.packageRootURL.path)
                appliedBlockCount: \(application.appliedBlockCount)
                """
            )
        }
    }

    private func regenerateCreatedContentView(
        userPrompt: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool,
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            sandboxEnabled: sandboxEnabled,
            appKind: appKind
        )
        let draftPath = ToolPackageLayout.pendingContentViewDraftPath
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingSource, nil)
            let response = try await context.languageModelInvoker.respond(
                stage: .codingAgent,
                in: session,
                to: prompt,
                generating: String.self
            ) { partialSource in
                try context.write(
                    partialSource,
                    to: draftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            try Task.checkCancellation()
            try context.write(
                response,
                to: contentViewPath,
                packageRootURL: layout.packageRootURL
            )
        } catch {
            AgentDiagnosticsLog.append(
                """
                ContentView source generation request failed.
                packageRoot: \(layout.packageRootURL.path)
                mode: create
                error:
                \(AgentDiagnosticsLog.renderError(error))
                """
            )
            try? trimPendingSourceDraftToCleanBoundary(layout: layout)
            throw error
        }
    }

    private func regenerateEditedContentView(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileEditPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource
        )
        let draftPath = ToolPackageLayout.pendingContentViewDraftPath
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingSource, nil)
            let response = try await context.languageModelInvoker.respond(
                stage: .codingAgent,
                in: session,
                to: prompt,
                generating: String.self
            ) { partialSource in
                try context.write(
                    partialSource,
                    to: draftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            try Task.checkCancellation()
            try context.write(
                response,
                to: contentViewPath,
                packageRootURL: layout.packageRootURL
            )
        } catch {
            AgentDiagnosticsLog.append(
                """
                ContentView source generation request failed.
                packageRoot: \(layout.packageRootURL.path)
                mode: edit
                error:
                \(AgentDiagnosticsLog.renderError(error))
                """
            )
            try? trimPendingSourceDraftToCleanBoundary(layout: layout)
            throw error
        }
    }

    private func regenerateEditedContentViewPatch(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        maximumPatchBlocks: Int,
        previousPatchFailure: String?,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileEditPatchPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumPatchBlocks: maximumPatchBlocks,
            previousPatchFailure: previousPatchFailure
        )
        let draftPath = ToolPackageLayout.pendingContentViewDraftPath
        let response: String
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingEditDiff, nil)
            response = try await context.languageModelInvoker.respond(
                stage: .codingAgent,
                in: session,
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
        } catch {
            AgentDiagnosticsLog.append(
                """
                ContentView edit patch request failed.
                packageRoot: \(layout.packageRootURL.path)
                mode: edit
                error:
                \(AgentDiagnosticsLog.renderError(error))
                """
            )
            throw error
        }

        let sanitizedPatch = ContentViewRepairSupport.sanitizedSearchReplacePatchSummary(response)
        try Task.checkCancellation()
        AgentDiagnosticsLog.append(
            """
            Model edit patch proposed.
            packageRoot: \(layout.packageRootURL.path)
            rawCharacters: \(response.count)
            sanitizedPatch:
            \(sanitizedPatch)
            """
        )
        let editedSource: String
        do {
            if context.pipelineConfiguration.codingAgent == .ironsmithFlame {
                let application = try ContentViewRepairSupport.applySearchReplacePatchBestEffort(
                    sanitizedPatch,
                    to: existingSource,
                    maximumPatchBlocks: maximumPatchBlocks
                )
                editedSource = application.source
                if !application.skippedBlocks.isEmpty {
                    AgentDiagnosticsLog.append(
                        """
                        Model edit patch partially applied.
                        packageRoot: \(layout.packageRootURL.path)
                        \(application.logSummary)
                        """
                    )
                }
            } else {
                editedSource = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                    sanitizedPatch,
                    to: existingSource,
                    maximumPatchBlocks: maximumPatchBlocks
                )
            }
        } catch {
            throw error
        }
        AgentDiagnosticsLog.append(
            """
            Model edit patch accepted.
            packageRoot: \(layout.packageRootURL.path)
            maximumPatchBlocks: \(maximumPatchBlocks)
            """
        )
        try context.write(
            editedSource,
            to: contentViewPath,
            packageRootURL: layout.packageRootURL
        )
        try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
    }
}
