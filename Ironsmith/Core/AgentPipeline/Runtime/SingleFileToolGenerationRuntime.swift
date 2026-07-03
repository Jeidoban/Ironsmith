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
                languageModel: context.metadataLanguageModel,
                generationOptions: context.generationOptions
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
            if startingPhase == .initializing || startingPhase == .planning || startingPhase == .generatingIcon {
                try await generateIconAssets(
                    displayName: setup.displayName,
                    iconPrompt: setup.iconPrompt,
                    layout: setup.layout,
                    lifecycle: lifecycle
                )
            }

            let contentPrompt: String
            if startingPhase == .generatingSource
                || startingPhase == .generatingRepairDiff
                || startingPhase == .repairing
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

            if startingPhase == .packaging || startingPhase == .completed {
                return try await packageTool(
                    displayName: setup.displayName,
                    executableName: setup.executableName,
                    bundleIdentifier: setup.bundleIdentifier,
                    packageRootURL: setup.layout.packageRootURL,
                    settings: setup.settings,
                    iconPrompt: setup.iconPrompt,
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
                useCurrentSourceOnFirstAttempt: startingPhase == .repairing || startingPhase == .generatingRepairDiff
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
            languageModel: context.languageModel,
            generationOptions: context.generationOptions,
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
            let generator = editGenerator(
                userPrompt: prompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle,
                resumePartialPatch: startingPhase == .generatingEditDiff,
                resumePartialSource: startingPhase == .generatingSource
            )
            try await compileGeneratedTool(
                displayName: existingTool.name,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                failureRecovery: .restoreOriginalSource(existingSource),
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
            try? context.write(existingSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
            try? context.write(existingAppEntrySource, to: layout.appEntrySourcePath, packageRootURL: layout.packageRootURL)
            try? context.versionBackupClient.discardStagedVersion(backup)
            AgentDiagnosticsLog.append(
                """
                Restored original ContentView.swift after edit failure.
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
        lifecycle: ToolGenerationLifecycle
    ) async throws {
        try await lifecycle.updatePhase(.generating, .repairing, nil)
        let repairLoop = ContentViewBuildRepairLoop(
            context: context,
            layout: layout,
            displayName: displayName,
            contentViewPath: contentViewPath,
            regenerationThreshold: ToolGenerationRepairPolicy.regenerationThreshold,
            maximumGenerationAttempts: context.pipelineConfiguration.maximumGenerationAttempts,
            lifecycle: lifecycle
        )
        let effectiveFailureRecovery: ContentViewBuildRepairLoop.FailureRecovery
        switch failureRecovery {
        case .restoreOriginalSource:
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

    private func generateIconAssets(
        displayName: String,
        iconPrompt: String?,
        layout: ToolPackageLayout,
        lifecycle: ToolGenerationLifecycle
    ) async throws {
        try await lifecycle.updatePhase(.generating, .generatingIcon, nil)
        do {
            try Task.checkCancellation()
            _ = try await context.iconClient.ensureIconAssets(
                ToolIconRequest(
                    displayName: displayName,
                    iconPrompt: iconPrompt,
                    layout: layout
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
        useCurrentSourceOnFirstAttempt: Bool
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
        resumePartialSource: Bool
    ) -> ContentViewCandidateGenerator {
        if resumePartialSource || !context.repairStrategy.usesModelRepair {
            return wholeFileEditGenerator(
                userPrompt: userPrompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle,
                resumePartialSource: resumePartialSource
            )
        }

        var didAttemptContinuation = false
        let originalPrompt = ToolGenerationPrompts.singleFileEditPatchPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn
        )

        return ContentViewCandidateGenerator(
            modeDescription: resumePartialPatch ? "continue edit patch" : "edit",
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
            if resumePartialPatch && !didAttemptContinuation {
                didAttemptContinuation = true
                let partialPatch = try context.readIfPresent(
                    ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
                if !partialPatch.isEmpty {
                    try await continuePatchDraft(
                        partialPatch: partialPatch,
                        originalPrompt: originalPrompt,
                        originalSource: existingSource,
                        maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        lifecycle: lifecycle,
                        session: session
                    )
                }
                return
            }

            try await regenerateEditedContentViewPatch(
                userPrompt: userPrompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                maximumPatchBlocks: context.repairStrategy.maxPatchBlocksPerTurn,
                lifecycle: lifecycle,
                session: session
            )
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
            let continuation = try await context.streamText(in: session, to: prompt) { partialContinuation in
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

    private func continuePatchDraft(
        partialPatch: String,
        originalPrompt: String,
        originalSource: String,
        maximumPatchBlocks: Int,
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.patchContinuationPrompt(
            originalPrompt: originalPrompt,
            partialPatch: partialPatch
        )
        do {
            try await lifecycle.updatePhase(.generating, .generatingEditDiff, nil)
            let continuation = try await context.streamText(in: session, to: prompt) { partialContinuation in
                try context.write(
                    partialPatch + partialContinuation,
                    to: ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            let sanitizedPatch = ContentViewRepairSupport.sanitizedSearchReplacePatchSummary(partialPatch + continuation)
            let editedSource = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                sanitizedPatch,
                to: originalSource,
                maximumPatchBlocks: maximumPatchBlocks
            )
            try context.write(
                editedSource,
                to: contentViewPath,
                packageRootURL: layout.packageRootURL
            )
        } catch {
            try trimPendingPatchDraftToLastValidPrefix(
                layout: layout,
                originalSource: originalSource,
                maximumPatchBlocks: maximumPatchBlocks
            )
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
        lifecycle: ToolGenerationLifecycle
    ) async throws -> ToolGenerationResult {
        let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
        try Task.checkCancellation()
        let binDirectory = try await context.processClient.showBinPath(packageRootURL)
        let binaryURL = binDirectory.appendingPathComponent(executableName)
        await context.processClient.stripQuarantine(binaryURL)

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

    private func trimPendingPatchDraftToLastValidPrefix(
        layout: ToolPackageLayout,
        originalSource: String,
        maximumPatchBlocks: Int
    ) throws {
        let draft = try context.readIfPresent(
            ToolPackageLayout.pendingContentViewDraftPath,
            packageRootURL: layout.packageRootURL
        )
        guard !draft.isEmpty else { return }
        let lines = draft.components(separatedBy: .newlines)
        for endIndex in stride(from: lines.count, through: 0, by: -1) {
            let candidate = lines.prefix(endIndex).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.contains("<<<<<<< SEARCH") else { continue }
            let sanitizedPatch = ContentViewRepairSupport.sanitizedSearchReplacePatchSummary(candidate)
            if (try? ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                sanitizedPatch,
                to: originalSource,
                maximumPatchBlocks: maximumPatchBlocks
            )) != nil {
                try context.write(
                    candidate,
                    to: ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
                return
            }
        }
        try context.write("", to: ToolPackageLayout.pendingContentViewDraftPath, packageRootURL: layout.packageRootURL)
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
            let response = try await context.streamText(in: session, to: prompt) { partialSource in
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
            let response = try await context.streamText(in: session, to: prompt) { partialSource in
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
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileEditPatchPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumPatchBlocks: maximumPatchBlocks
        )
        let draftPath = ToolPackageLayout.pendingContentViewDraftPath
        let response: String
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingEditDiff, nil)
            response = try await context.streamText(in: session, to: prompt) { partialPatch in
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
            try? trimPendingPatchDraftToLastValidPrefix(
                layout: layout,
                originalSource: existingSource,
                maximumPatchBlocks: maximumPatchBlocks
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
            \(AgentDiagnosticsLog.compactMultiline(sanitizedPatch, limit: AgentDiagnosticsLog.repairPatchLimit))
            """
        )
        let editedSource = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            sanitizedPatch,
            to: existingSource,
            maximumPatchBlocks: maximumPatchBlocks
        )
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
    }
}
