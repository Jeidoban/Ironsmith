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
        let manifest: ToolManifest
        let iconPrompt: String?
    }

    func generateTool(
        for prompt: String,
        existingTool: Tool? = nil,
        sandboxEnabled: Bool = true,
        sandboxPermissions: GeneratedAppSandboxPermissions = .default,
        resourcePermissions: GeneratedAppResourcePermissions = .none,
        lifecycle: ToolGenerationLifecycle = .noop,
        status: @escaping @MainActor (String) -> Void
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
                    sandboxEnabled: sandboxEnabled,
                    sandboxPermissions: sandboxPermissions,
                    resourcePermissions: resourcePermissions,
                    lifecycle: lifecycle,
                    status: status
                )
            }
            return try await editTool(
                prompt: effectivePrompt,
                existingTool: existingTool,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                lifecycle: lifecycle,
                status: status
            )
        }

        return try await createTool(
            prompt: trimmedPrompt,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions,
            lifecycle: lifecycle,
            status: status
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

    private func loadCreateSetup(for tool: Tool) throws -> CreateToolSetup {
        let manifest = try context.loadManifest(at: tool.agentManifestURL)
        let layout = ToolPackageLayout(
            packageRootURL: tool.packageRootURL,
            executableName: manifest.executableName
        )
        return CreateToolSetup(
            displayName: manifest.displayName,
            executableName: manifest.executableName,
            bundleIdentifier: tool.bundleIdentifier,
            layout: layout,
            contentViewPath: manifest.files.first?.path ?? layout.sourcePath(for: layout.defaultContentViewFileName),
            manifest: manifest,
            iconPrompt: nil
        )
    }

    private func prepareNewCreateSetup(
        metadata: ToolMetadataSuggestion,
        prompt: String,
        sandboxEnabled: Bool,
        lifecycle: ToolGenerationLifecycle
    ) async throws -> CreateToolSetup {
        let displayName = metadata.displayName
        let executableName = ToolNameSanitizer.executableName(from: displayName)
        let bundleIdentifier = ToolBundleIdentifier.make(executableName: executableName)
        let packageRootURL = try context.makeUniquePackageRoot(displayName: displayName)
        let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
        let contentViewPath = layout.sourcePath(for: layout.defaultContentViewFileName)
        let manifest = ToolManifest(
            displayName: displayName,
            executableName: executableName,
            files: [
                ToolManifestFile(
                    path: contentViewPath,
                    description: "Primary SwiftUI screen and supporting app logic."
                )
            ]
        )

        try context.fileClient.createDirectory(layout.sourceDirectoryURL)
        try context.write(layout.packageManifestContent(), to: "Package.swift", packageRootURL: layout.packageRootURL)
        try context.write(layout.fixedAppEntrySource(), to: layout.appEntrySourcePath, packageRootURL: layout.packageRootURL)
        try context.writeManifest(manifest, packageRootURL: layout.packageRootURL)
        try await lifecycle.prepareCreatedTool(
            ToolGenerationPreparedTool(
                name: displayName,
                executableName: executableName,
                bundleIdentifier: bundleIdentifier,
                sandboxEnabled: sandboxEnabled,
                packageRootURL: packageRootURL,
                manifest: manifest
            ),
            prompt
        )

        return CreateToolSetup(
            displayName: displayName,
            executableName: executableName,
            bundleIdentifier: bundleIdentifier,
            layout: layout,
            contentViewPath: contentViewPath,
            manifest: manifest,
            iconPrompt: metadata.iconPrompt
        )
    }

    private func createTool(
        prompt: String,
        existingTool: Tool? = nil,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let startingPhase = existingTool?.generationPhase ?? .initializing
        let setup: CreateToolSetup
        if let existingTool, let resumedSetup = try? loadCreateSetup(for: existingTool) {
            setup = resumedSetup
        } else {
            status("Naming app")
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
                sandboxEnabled: sandboxEnabled,
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
                    sandboxEnabled: sandboxEnabled,
                    lifecycle: lifecycle
                )
            }

            if startingPhase == .packaging || startingPhase == .completed {
                return try await packageTool(
                    displayName: setup.displayName,
                    executableName: setup.executableName,
                    bundleIdentifier: setup.bundleIdentifier,
                    packageRootURL: setup.layout.packageRootURL,
                    manifest: setup.manifest,
                    sandboxEnabled: sandboxEnabled,
                    sandboxPermissions: sandboxPermissions,
                    resourcePermissions: resourcePermissions,
                    iconPrompt: setup.iconPrompt,
                    lifecycle: lifecycle,
                    status: status
                )
            }

            let generator = createGenerator(
                userPrompt: contentPrompt,
                sandboxEnabled: sandboxEnabled,
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
                lifecycle: lifecycle,
                status: status
            )

            return try await packageTool(
                displayName: setup.displayName,
                executableName: setup.executableName,
                bundleIdentifier: setup.bundleIdentifier,
                packageRootURL: setup.layout.packageRootURL,
                manifest: setup.manifest,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                iconPrompt: setup.iconPrompt,
                lifecycle: lifecycle,
                status: status
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
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let manifest = try context.loadManifest(at: existingTool.agentManifestURL)
        let layout = ToolPackageLayout(
            packageRootURL: existingTool.packageRootURL,
            executableName: manifest.executableName
        )
        let contentViewPath = manifest.files.first?.path ?? layout.sourcePath(for: layout.defaultContentViewFileName)
        let startingPhase = existingTool.isGenerationReady
            ? ToolGenerationPhase.planning
            : (existingTool.generationPhase ?? .generatingEditDiff)
        if !existingTool.isGenerationReady,
           startingPhase == .packaging || startingPhase == .completed {
            return try await packageTool(
                displayName: manifest.displayName,
                executableName: manifest.executableName,
                bundleIdentifier: existingTool.bundleIdentifier,
                packageRootURL: existingTool.packageRootURL,
                manifest: manifest,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                iconPrompt: nil,
                lifecycle: lifecycle,
                status: status
            )
        }
        let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        let backup = try context.versionBackupClient.stageCurrentVersion(layout.packageRootURL, contentViewPath)

        AgentDiagnosticsLog.append(
            """
            Tool generation started.
            mode: edit
            displayName: \(manifest.displayName)
            executableName: \(manifest.executableName)
            packageRoot: \(existingTool.packageRootURL.path)
            phase: \(startingPhase.rawValue)
            prompt: \(AgentDiagnosticsLog.compact(prompt, limit: 240))
            editableFile: \(contentViewPath)
            """
        )

        do {
            try Task.checkCancellation()
            try context.writeManifest(manifest, packageRootURL: layout.packageRootURL)
            let generator = editGenerator(
                userPrompt: prompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle,
                resumePartialDiff: startingPhase == .generatingEditDiff,
                resumePartialSource: startingPhase == .generatingSource
            )
            try await compileGeneratedTool(
                displayName: manifest.displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                failureRecovery: .restoreOriginalSource(existingSource),
                lifecycle: lifecycle,
                status: status
            )
            try Task.checkCancellation()
            status("Packaging \(manifest.displayName)")
            try await lifecycle.updatePhase(.generating, .packaging, nil)
            _ = try await context.appBundleClient.buildInternalApp(
                ToolAppBundleRequest(
                    displayName: manifest.displayName,
                    executableName: manifest.executableName,
                    bundleIdentifier: existingTool.bundleIdentifier,
                    packageRootURL: existingTool.packageRootURL,
                    sandboxEnabled: sandboxEnabled,
                    sandboxPermissions: sandboxPermissions,
                    resourcePermissions: resourcePermissions
                )
            )
            try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
            try context.versionBackupClient.promoteStagedVersion(backup)
        } catch {
            try? context.write(existingSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
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
        let binaryURL = binDirectory.appendingPathComponent(manifest.executableName)
        await context.processClient.stripQuarantine(binaryURL)

        return ToolGenerationResult(
            toolName: manifest.displayName,
            executableName: manifest.executableName,
            bundleIdentifier: existingTool.bundleIdentifier,
            sandboxEnabled: sandboxEnabled,
            packageRootURL: existingTool.packageRootURL,
            manifest: manifest
        )
    }

    private func compileGeneratedTool(
        displayName: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        generator: ContentViewCandidateGenerator,
        failureRecovery: ContentViewBuildRepairLoop.FailureRecovery = .restoreBestCandidate,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        try await lifecycle.updatePhase(.generating, .repairing, nil)
        let repairLoop = ContentViewBuildRepairLoop(
            context: context,
            layout: layout,
            displayName: displayName,
            contentViewPath: contentViewPath,
            regenerationThreshold: ToolGenerationRepairPolicy.regenerationThreshold,
            maximumGenerationAttempts: ToolGenerationRepairPolicy.maximumGenerationAttempts,
            lifecycle: lifecycle
        )
        try await repairLoop.run(
            generator: generator,
            failureRecovery: failureRecovery,
            status: status
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
            sandboxEnabled: sandboxEnabled
        )

        return ContentViewCandidateGenerator(
            modeDescription: resumePartialSource ? "continue create" : "create",
            initialStatusVerb: resumePartialSource ? "Continuing" : "Generating",
            retryStatusVerb: "Regenerating"
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
        resumePartialDiff: Bool,
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
        let originalPrompt = ToolGenerationPrompts.singleFileEditDiffPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumDiffHunks: context.repairStrategy.maxInitialEditHunks
        )

        return ContentViewCandidateGenerator(
            modeDescription: resumePartialDiff ? "continue edit diff" : "edit",
            initialStatusVerb: resumePartialDiff ? "Continuing" : "Editing",
            retryStatusVerb: "Editing",
            instructions: ToolGenerationPrompts.diffEditInstructions,
            retriesInvalidCandidates: true,
            invalidCandidateFallback: ContentViewCandidateGenerator.InvalidCandidateFallback(
                threshold: ToolGenerationRepairPolicy.invalidInitialEditDiffsBeforeFullFileEdit,
                modeDescription: "edit whole-file fallback",
                initialStatusVerb: "Editing",
                retryStatusVerb: "Editing"
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
        ) { session in
            if resumePartialDiff && !didAttemptContinuation {
                didAttemptContinuation = true
                let partialDiff = try context.readIfPresent(
                    ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
                if !partialDiff.isEmpty {
                    try await continueDiffDraft(
                        partialDiff: partialDiff,
                        originalPrompt: originalPrompt,
                        originalSource: existingSource,
                        maximumDiffHunks: context.repairStrategy.maxInitialEditHunks,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        lifecycle: lifecycle,
                        session: session
                    )
                    return
                }
            }

            try await regenerateEditedContentViewDiff(
                userPrompt: userPrompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                maximumDiffHunks: context.repairStrategy.maxInitialEditHunks,
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
            modeDescription: resumePartialSource ? "continue edit source" : "edit",
            initialStatusVerb: resumePartialSource ? "Continuing" : "Editing",
            retryStatusVerb: "Editing"
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

    private func continueDiffDraft(
        partialDiff: String,
        originalPrompt: String,
        originalSource: String,
        maximumDiffHunks: Int?,
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.diffContinuationPrompt(
            originalPrompt: originalPrompt,
            partialDiff: partialDiff
        )
        do {
            try await lifecycle.updatePhase(.generating, .generatingEditDiff, nil)
            let continuation = try await context.streamText(in: session, to: prompt) { partialContinuation in
                try context.write(
                    partialDiff + partialContinuation,
                    to: ToolPackageLayout.pendingContentViewDraftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            let sanitizedDiff = ContentViewRepairSupport.sanitizedRepairDiffSummary(partialDiff + continuation)
            let editedSource = try ContentViewRepairSupport.applyValidatedDiff(
                sanitizedDiff,
                to: originalSource,
                maximumHunks: maximumDiffHunks
            )
            try context.write(
                editedSource,
                to: contentViewPath,
                packageRootURL: layout.packageRootURL
            )
        } catch {
            try trimPendingDiffDraftToLastValidPrefix(
                layout: layout,
                originalSource: originalSource,
                maximumDiffHunks: maximumDiffHunks
            )
            throw error
        }
    }

    private func packageTool(
        displayName: String,
        executableName: String,
        bundleIdentifier: String,
        packageRootURL: URL,
        manifest: ToolManifest,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        iconPrompt: String?,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
        try Task.checkCancellation()
        let binDirectory = try await context.processClient.showBinPath(packageRootURL)
        let binaryURL = binDirectory.appendingPathComponent(executableName)
        await context.processClient.stripQuarantine(binaryURL)

        try Task.checkCancellation()
        status("Packaging \(displayName)")
        try await lifecycle.updatePhase(.generating, .packaging, nil)
        _ = try await context.appBundleClient.buildInternalApp(
            ToolAppBundleRequest(
                displayName: displayName,
                executableName: executableName,
                bundleIdentifier: bundleIdentifier,
                packageRootURL: packageRootURL,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                iconPrompt: iconPrompt
            )
        )

        try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
        return ToolGenerationResult(
            toolName: displayName,
            executableName: executableName,
            bundleIdentifier: bundleIdentifier,
            sandboxEnabled: sandboxEnabled,
            packageRootURL: packageRootURL,
            manifest: manifest
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

    private func trimPendingDiffDraftToLastValidPrefix(
        layout: ToolPackageLayout,
        originalSource: String,
        maximumDiffHunks: Int?
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
            guard candidate.contains("@@") else { continue }
            let sanitizedDiff = ContentViewRepairSupport.sanitizedRepairDiffSummary(candidate)
            if (try? ContentViewRepairSupport.applyValidatedDiff(
                sanitizedDiff,
                to: originalSource,
                maximumHunks: maximumDiffHunks
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
        sandboxEnabled: Bool,
        layout: ToolPackageLayout,
        contentViewPath: String,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            sandboxEnabled: sandboxEnabled
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

    private func regenerateEditedContentViewDiff(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        maximumDiffHunks: Int?,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileEditDiffPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumDiffHunks: maximumDiffHunks
        )
        let draftPath = ToolPackageLayout.pendingContentViewDraftPath
        let response: String
        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingEditDiff, nil)
            response = try await context.streamText(in: session, to: prompt) { partialDiff in
                try context.write(
                    partialDiff,
                    to: draftPath,
                    packageRootURL: layout.packageRootURL
                )
            }
            try Task.checkCancellation()
        } catch {
            AgentDiagnosticsLog.append(
                """
                ContentView edit diff request failed.
                packageRoot: \(layout.packageRootURL.path)
                mode: edit
                error:
                \(AgentDiagnosticsLog.renderError(error))
                """
            )
            try? trimPendingDiffDraftToLastValidPrefix(
                layout: layout,
                originalSource: existingSource,
                maximumDiffHunks: maximumDiffHunks
            )
            throw error
        }

        let sanitizedDiff = ContentViewRepairSupport.sanitizedRepairDiffSummary(response)
        try Task.checkCancellation()
        AgentDiagnosticsLog.append(
            """
            Model edit diff proposed.
            packageRoot: \(layout.packageRootURL.path)
            rawCharacters: \(response.count)
            sanitizedDiff:
            \(AgentDiagnosticsLog.compactMultiline(sanitizedDiff, limit: AgentDiagnosticsLog.repairDiffLimit))
            """
        )
        let editedSource = try ContentViewRepairSupport.applyValidatedDiff(
            sanitizedDiff,
            to: existingSource,
            maximumHunks: maximumDiffHunks
        )
        AgentDiagnosticsLog.append(
            """
            Model edit diff accepted.
            packageRoot: \(layout.packageRootURL.path)
            maxDiffHunks: \(maximumDiffHunks.map(String.init) ?? "unlimited")
            """
        )
        try context.write(
            editedSource,
            to: contentViewPath,
            packageRootURL: layout.packageRootURL
        )
    }
}
