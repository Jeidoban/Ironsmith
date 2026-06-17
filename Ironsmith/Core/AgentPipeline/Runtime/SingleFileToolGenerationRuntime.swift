import AnyLanguageModel
import Foundation

struct SingleFileToolGenerationRuntime {
    let context: ToolGenerationRuntimeContext

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

        if let existingTool, !existingTool.isGenerationReady {
            return try await resumeTool(
                prompt: trimmedPrompt,
                existingTool: existingTool,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                lifecycle: lifecycle,
                status: status
            )
        }

        if let existingTool {
            return try await editTool(
                prompt: trimmedPrompt,
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

    private func createTool(
        prompt: String,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        status("Planning app")
        try await lifecycle.updatePhase(.generating, .planning, nil)
        try Task.checkCancellation()
        let metadata = await context.metadataClient.suggestMetadata(
            userPrompt: prompt,
            languageModel: context.metadataLanguageModel,
            generationOptions: context.generationOptions
        )
        try Task.checkCancellation()
        let promptRefinement = await contentGenerationPrompt(for: prompt, sandboxEnabled: sandboxEnabled)
        let contentGenerationPrompt = promptRefinement.prompt
        try Task.checkCancellation()
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

        AgentDiagnosticsLog.append(
            """
            Tool generation started.
            mode: create
            displayName: \(displayName)
            executableName: \(executableName)
            packageRoot: \(packageRootURL.path)
            prompt: \(AgentDiagnosticsLog.compact(prompt, limit: 240))
            """
        )

        do {
            try Task.checkCancellation()
            try context.fileClient.createDirectory(layout.sourceDirectoryURL)

            status("Preparing \(displayName)")
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
                prompt,
                promptRefinement.refinedPrompt
            )

            let generator = ContentViewCandidateGenerator(modeDescription: "create") { session in
                try await regenerateCreatedContentView(
                    userPrompt: contentGenerationPrompt,
                    sandboxEnabled: sandboxEnabled,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    lifecycle: lifecycle,
                    session: session
                )
            }
            try await compileGeneratedTool(
                displayName: displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                lifecycle: lifecycle,
                status: status
            )

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
                    promptSummary: prompt,
                    iconPrompt: metadata.iconPrompt
                )
            )

            return ToolGenerationResult(
                toolName: displayName,
                executableName: executableName,
                bundleIdentifier: bundleIdentifier,
                sandboxEnabled: sandboxEnabled,
                packageRootURL: packageRootURL,
                manifest: manifest
            )
        } catch is CancellationError {
            if !lifecycle.preservesCreatedPackageOnCancellation {
                try? context.fileClient.removeItemIfExists(packageRootURL)
            }
            throw CancellationError()
        }
    }

    private func contentGenerationPrompt(for prompt: String, sandboxEnabled: Bool) async -> (
        prompt: String,
        refinedPrompt: String?
    ) {
        guard context.promptRefinementEnabled else {
            return (prompt, nil)
        }

        let refinedPrompt = await context.promptRefinementClient.refinePrompt(
            userPrompt: prompt,
            languageModel: context.languageModel,
            generationOptions: context.generationOptions,
            sandboxEnabled: sandboxEnabled
        )
        return (refinedPrompt ?? prompt, refinedPrompt)
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
        let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        let backup = try context.versionBackupClient.stageCurrentVersion(layout.packageRootURL, contentViewPath)

        AgentDiagnosticsLog.append(
            """
            Tool generation started.
            mode: edit
            displayName: \(manifest.displayName)
            executableName: \(manifest.executableName)
            packageRoot: \(existingTool.packageRootURL.path)
            prompt: \(AgentDiagnosticsLog.compact(prompt, limit: 240))
            editableFile: \(contentViewPath)
            """
        )

        do {
            try Task.checkCancellation()
            try await lifecycle.updatePhase(.generating, .generatingEditDiff, nil)
            try context.writeManifest(manifest, packageRootURL: layout.packageRootURL)
            let generator: ContentViewCandidateGenerator
            if context.repairStrategy.usesModelRepair {
                generator = ContentViewCandidateGenerator(
                    modeDescription: "edit",
                    initialStatusVerb: "Editing",
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
                            userPrompt: prompt,
                            layout: layout,
                            contentViewPath: contentViewPath,
                            existingSource: existingSource,
                            lifecycle: lifecycle,
                            session: session
                        )
                    }
                ) { session in
                    try await regenerateEditedContentViewDiff(
                        userPrompt: prompt,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        existingSource: existingSource,
                        maximumDiffHunks: context.repairStrategy.maxInitialEditHunks,
                        lifecycle: lifecycle,
                        session: session
                    )
                }
            } else {
                generator = ContentViewCandidateGenerator(
                    modeDescription: "edit",
                    initialStatusVerb: "Editing",
                    retryStatusVerb: "Editing"
                ) { session in
                    try await regenerateEditedContentView(
                        userPrompt: prompt,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        existingSource: existingSource,
                        lifecycle: lifecycle,
                        session: session
                    )
                }
            }
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
                    resourcePermissions: resourcePermissions,
                    promptSummary: prompt
                )
            )
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

    private func resumeTool(
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
        let mode = existingTool.generationMode ?? .create
        let phase = existingTool.generationPhase ?? .planning
        let userPrompt = existingTool.pendingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? existingTool.pendingPrompt ?? prompt
            : prompt
        let refinedPrompt = existingTool.pendingRefinedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? existingTool.pendingRefinedPrompt ?? userPrompt
            : userPrompt

        AgentDiagnosticsLog.append(
            """
            Tool generation resumed.
            mode: \(mode.rawValue)
            phase: \(phase.rawValue)
            displayName: \(manifest.displayName)
            executableName: \(manifest.executableName)
            packageRoot: \(existingTool.packageRootURL.path)
            """
        )

        switch phase {
        case .initializing, .planning:
            return try await resumeFromPlanning(
                mode: mode,
                userPrompt: userPrompt,
                refinedPrompt: refinedPrompt,
                existingTool: existingTool,
                manifest: manifest,
                layout: layout,
                contentViewPath: contentViewPath,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                lifecycle: lifecycle,
                status: status
            )

        case .generatingSource:
            return try await resumeSourceGeneration(
                mode: mode,
                userPrompt: userPrompt,
                refinedPrompt: refinedPrompt,
                existingTool: existingTool,
                manifest: manifest,
                layout: layout,
                contentViewPath: contentViewPath,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                lifecycle: lifecycle,
                status: status
            )

        case .generatingEditDiff:
            return try await resumeEditDiffGeneration(
                userPrompt: userPrompt,
                existingTool: existingTool,
                manifest: manifest,
                layout: layout,
                contentViewPath: contentViewPath,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                lifecycle: lifecycle,
                status: status
            )

        case .generatingRepairDiff, .repairing:
            try await compileGeneratedTool(
                displayName: manifest.displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: resumedRepairGenerator(
                    mode: mode,
                    userPrompt: userPrompt,
                    refinedPrompt: refinedPrompt,
                    sandboxEnabled: sandboxEnabled,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    existingSource: try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL),
                    lifecycle: lifecycle
                ),
                failureRecovery: mode == .edit
                    ? .restoreOriginalSource(try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL))
                    : .restoreBestCandidate,
                lifecycle: lifecycle,
                status: status
            )
            return try await packageResumedTool(
                existingTool,
                manifest: manifest,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                prompt: userPrompt,
                lifecycle: lifecycle,
                status: status
            )

        case .packaging, .completed:
            return try await packageResumedTool(
                existingTool,
                manifest: manifest,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                prompt: userPrompt,
                lifecycle: lifecycle,
                status: status
            )
        }
    }

    private func resumeFromPlanning(
        mode: ToolGenerationMode,
        userPrompt: String,
        refinedPrompt: String,
        existingTool: Tool,
        manifest: ToolManifest,
        layout: ToolPackageLayout,
        contentViewPath: String,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        switch mode {
        case .create:
            let generator = ContentViewCandidateGenerator(modeDescription: "resume create") { session in
                try await regenerateCreatedContentView(
                    userPrompt: refinedPrompt,
                    sandboxEnabled: sandboxEnabled,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    lifecycle: lifecycle,
                    session: session
                )
            }
            try await compileGeneratedTool(
                displayName: manifest.displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                lifecycle: lifecycle,
                status: status
            )
        case .edit:
            let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
            let backup = try context.versionBackupClient.stageCurrentVersion(layout.packageRootURL, contentViewPath)
            do {
                let generator = editGenerator(
                    userPrompt: userPrompt,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    existingSource: existingSource,
                    lifecycle: lifecycle
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
                try context.versionBackupClient.promoteStagedVersion(backup)
            } catch {
                try? context.write(existingSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
                try? context.versionBackupClient.discardStagedVersion(backup)
                throw error
            }
        }

        return try await packageResumedTool(
            existingTool,
            manifest: manifest,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions,
            prompt: userPrompt,
            lifecycle: lifecycle,
            status: status
        )
    }

    private func resumeSourceGeneration(
        mode: ToolGenerationMode,
        userPrompt: String,
        refinedPrompt: String,
        existingTool: Tool,
        manifest: ToolManifest,
        layout: ToolPackageLayout,
        contentViewPath: String,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let partialSource = try context.readIfPresent(
            ToolPackageLayout.pendingContentViewDraftPath,
            packageRootURL: layout.packageRootURL
        )
        var didAttemptContinuation = false
        let basePrompt = mode == .create
            ? ToolGenerationPrompts.singleFileCreatePrompt(
                userPrompt: refinedPrompt,
                executableName: layout.executableName,
                sandboxEnabled: sandboxEnabled
            )
            : ToolGenerationPrompts.singleFileEditPrompt(
                userPrompt: userPrompt,
                executableName: layout.executableName,
                existingSource: try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
            )

        let writeContinuationOrFreshCandidate: (LanguageModelSession) async throws -> Void = { session in
            if !didAttemptContinuation, !partialSource.isEmpty {
                didAttemptContinuation = true
                try await continueSourceDraft(
                    partialSource: partialSource,
                    originalPrompt: basePrompt,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    lifecycle: lifecycle,
                    session: session
                )
                return
            }

            switch mode {
            case .create:
                try await regenerateCreatedContentView(
                    userPrompt: refinedPrompt,
                    sandboxEnabled: sandboxEnabled,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    lifecycle: lifecycle,
                    session: session
                )
            case .edit:
                let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
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

        if mode == .edit {
            let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
            let backup = try context.versionBackupClient.stageCurrentVersion(layout.packageRootURL, contentViewPath)
            do {
                try await compileGeneratedTool(
                    displayName: manifest.displayName,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    generator: ContentViewCandidateGenerator(
                        modeDescription: "resume source",
                        initialStatusVerb: "Continuing",
                        retryStatusVerb: "Editing",
                        writeFreshCandidate: writeContinuationOrFreshCandidate
                    ),
                    failureRecovery: .restoreOriginalSource(existingSource),
                    lifecycle: lifecycle,
                    status: status
                )
                try context.versionBackupClient.promoteStagedVersion(backup)
            } catch {
                try? context.write(existingSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
                try? context.versionBackupClient.discardStagedVersion(backup)
                throw error
            }
        } else {
            try await compileGeneratedTool(
                displayName: manifest.displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: ContentViewCandidateGenerator(
                    modeDescription: "resume source",
                    initialStatusVerb: "Continuing",
                    retryStatusVerb: "Regenerating",
                    writeFreshCandidate: writeContinuationOrFreshCandidate
                ),
                lifecycle: lifecycle,
                status: status
            )
        }

        return try await packageResumedTool(
            existingTool,
            manifest: manifest,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions,
            prompt: userPrompt,
            lifecycle: lifecycle,
            status: status
        )
    }

    private func resumeEditDiffGeneration(
        userPrompt: String,
        existingTool: Tool,
        manifest: ToolManifest,
        layout: ToolPackageLayout,
        contentViewPath: String,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let existingSource = try context.readIfPresent(contentViewPath, packageRootURL: layout.packageRootURL)
        let partialDiff = try context.readIfPresent(
            ToolPackageLayout.pendingContentViewDraftPath,
            packageRootURL: layout.packageRootURL
        )
        let originalPrompt = ToolGenerationPrompts.singleFileEditDiffPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumDiffHunks: context.repairStrategy.maxInitialEditHunks
        )
        var didAttemptContinuation = false
        let backup = try context.versionBackupClient.stageCurrentVersion(layout.packageRootURL, contentViewPath)
        do {
            let generator = ContentViewCandidateGenerator(
                modeDescription: "resume edit diff",
                initialStatusVerb: "Continuing",
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
                if !didAttemptContinuation, !partialDiff.isEmpty {
                    didAttemptContinuation = true
                    try await continueDiffDraft(
                        partialDiff: partialDiff,
                        originalPrompt: originalPrompt,
                        originalSource: existingSource,
                        maximumDiffHunks: context.repairStrategy.maxInitialEditHunks,
                        layout: layout,
                        contentViewPath: contentViewPath,
                        phase: .generatingEditDiff,
                        lifecycle: lifecycle,
                        session: session
                    )
                    return
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
            try await compileGeneratedTool(
                displayName: manifest.displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                failureRecovery: .restoreOriginalSource(existingSource),
                lifecycle: lifecycle,
                status: status
            )
            try context.versionBackupClient.promoteStagedVersion(backup)
        } catch {
            try? context.write(existingSource, to: contentViewPath, packageRootURL: layout.packageRootURL)
            try? context.versionBackupClient.discardStagedVersion(backup)
            throw error
        }

        return try await packageResumedTool(
            existingTool,
            manifest: manifest,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions,
            prompt: userPrompt,
            lifecycle: lifecycle,
            status: status
        )
    }

    private func resumedRepairGenerator(
        mode: ToolGenerationMode,
        userPrompt: String,
        refinedPrompt: String,
        sandboxEnabled: Bool,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        lifecycle: ToolGenerationLifecycle
    ) -> ContentViewCandidateGenerator {
        switch mode {
        case .create:
            ContentViewCandidateGenerator(modeDescription: "resume repair") { session in
                try await regenerateCreatedContentView(
                    userPrompt: refinedPrompt,
                    sandboxEnabled: sandboxEnabled,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    lifecycle: lifecycle,
                    session: session
                )
            }
        case .edit:
            editGenerator(
                userPrompt: userPrompt,
                layout: layout,
                contentViewPath: contentViewPath,
                existingSource: existingSource,
                lifecycle: lifecycle
            )
        }
    }

    private func editGenerator(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        lifecycle: ToolGenerationLifecycle
    ) -> ContentViewCandidateGenerator {
        if context.repairStrategy.usesModelRepair {
            return ContentViewCandidateGenerator(
                modeDescription: "edit",
                initialStatusVerb: "Editing",
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

        return ContentViewCandidateGenerator(
            modeDescription: "edit",
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
    }

    private func continueDiffDraft(
        partialDiff: String,
        originalPrompt: String,
        originalSource: String,
        maximumDiffHunks: Int?,
        layout: ToolPackageLayout,
        contentViewPath: String,
        phase: ToolGenerationPhase,
        lifecycle: ToolGenerationLifecycle,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.diffContinuationPrompt(
            originalPrompt: originalPrompt,
            partialDiff: partialDiff
        )
        try await lifecycle.updatePhase(.generating, phase, nil)
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
    }

    private func packageResumedTool(
        _ tool: Tool,
        manifest: ToolManifest,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
        prompt: String,
        lifecycle: ToolGenerationLifecycle,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let layout = ToolPackageLayout(
            packageRootURL: tool.packageRootURL,
            executableName: manifest.executableName
        )
        try Task.checkCancellation()
        let binDirectory = try await context.processClient.showBinPath(tool.packageRootURL)
        let binaryURL = binDirectory.appendingPathComponent(manifest.executableName)
        await context.processClient.stripQuarantine(binaryURL)

        try Task.checkCancellation()
        status("Packaging \(manifest.displayName)")
        try await lifecycle.updatePhase(.generating, .packaging, nil)
        _ = try await context.appBundleClient.buildInternalApp(
            ToolAppBundleRequest(
                displayName: manifest.displayName,
                executableName: manifest.executableName,
                bundleIdentifier: tool.bundleIdentifier,
                packageRootURL: tool.packageRootURL,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                promptSummary: prompt
            )
        )

        try? context.fileClient.removeItemIfExists(layout.pendingContentViewDraftURL)
        return ToolGenerationResult(
            toolName: manifest.displayName,
            executableName: manifest.executableName,
            bundleIdentifier: tool.bundleIdentifier,
            sandboxEnabled: sandboxEnabled,
            packageRootURL: tool.packageRootURL,
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
