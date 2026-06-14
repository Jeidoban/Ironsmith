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
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ToolGenerationError.emptyPrompt
        }

        if let existingTool {
            return try await editTool(
                prompt: trimmedPrompt,
                existingTool: existingTool,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                status: status
            )
        }

        return try await createTool(
            prompt: trimmedPrompt,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions,
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
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        status("Planning app")
        try Task.checkCancellation()
        let metadata = await context.metadataClient.suggestMetadata(
            userPrompt: prompt,
            languageModel: context.metadataLanguageModel,
            generationOptions: context.generationOptions
        )
        try Task.checkCancellation()
        let contentGenerationPrompt = await contentGenerationPrompt(for: prompt, sandboxEnabled: sandboxEnabled)
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

            let generator = ContentViewCandidateGenerator(modeDescription: "create") { session in
                try await regenerateCreatedContentView(
                    userPrompt: contentGenerationPrompt,
                    sandboxEnabled: sandboxEnabled,
                    layout: layout,
                    contentViewPath: contentViewPath,
                    session: session
                )
            }
            try await compileGeneratedTool(
                displayName: displayName,
                layout: layout,
                contentViewPath: contentViewPath,
                generator: generator,
                status: status
            )

            try Task.checkCancellation()
            let binDirectory = try await context.processClient.showBinPath(packageRootURL)
            let binaryURL = binDirectory.appendingPathComponent(executableName)
            await context.processClient.stripQuarantine(binaryURL)

            try Task.checkCancellation()
            status("Packaging \(displayName)")
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
            try? context.fileClient.removeItemIfExists(packageRootURL)
            throw CancellationError()
        }
    }

    private func contentGenerationPrompt(for prompt: String, sandboxEnabled: Bool) async -> String {
        guard context.promptRefinementEnabled else {
            return prompt
        }

        let refinedPrompt = await context.promptRefinementClient.refinePrompt(
            userPrompt: prompt,
            languageModel: context.languageModel,
            generationOptions: context.generationOptions,
            sandboxEnabled: sandboxEnabled
        )
        return refinedPrompt ?? prompt
    }

    private func editTool(
        prompt: String,
        existingTool: Tool,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions,
        resourcePermissions: GeneratedAppResourcePermissions,
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
                status: status
            )
            try Task.checkCancellation()
            status("Packaging \(manifest.displayName)")
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

    private func compileGeneratedTool(
        displayName: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        generator: ContentViewCandidateGenerator,
        failureRecovery: ContentViewBuildRepairLoop.FailureRecovery = .restoreBestCandidate,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        let repairLoop = ContentViewBuildRepairLoop(
            context: context,
            layout: layout,
            displayName: displayName,
            contentViewPath: contentViewPath,
            regenerationThreshold: ToolGenerationRepairPolicy.regenerationThreshold,
            maximumGenerationAttempts: ToolGenerationRepairPolicy.maximumGenerationAttempts
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
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            sandboxEnabled: sandboxEnabled
        )
        let response: LanguageModelSession.Response<String>
        do {
            try Task.checkCancellation()
            response = try await context.respond(in: session, to: prompt)
            try Task.checkCancellation()
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
        try context.write(
            response.content,
            to: contentViewPath,
            packageRootURL: layout.packageRootURL
        )
    }

    private func regenerateEditedContentView(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileEditPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource
        )
        let response: LanguageModelSession.Response<String>
        do {
            try Task.checkCancellation()
            response = try await context.respond(in: session, to: prompt)
            try Task.checkCancellation()
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
        try context.write(
            response.content,
            to: contentViewPath,
            packageRootURL: layout.packageRootURL
        )
    }

    private func regenerateEditedContentViewDiff(
        userPrompt: String,
        layout: ToolPackageLayout,
        contentViewPath: String,
        existingSource: String,
        maximumDiffHunks: Int?,
        session: LanguageModelSession
    ) async throws {
        let prompt = ToolGenerationPrompts.singleFileEditDiffPrompt(
            userPrompt: userPrompt,
            executableName: layout.executableName,
            existingSource: existingSource,
            maximumDiffHunks: maximumDiffHunks
        )
        let response: LanguageModelSession.Response<String>
        do {
            try Task.checkCancellation()
            response = try await context.respond(in: session, to: prompt)
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

        let sanitizedDiff = ContentViewRepairSupport.sanitizedRepairDiffSummary(response.content)
        try Task.checkCancellation()
        AgentDiagnosticsLog.append(
            """
            Model edit diff proposed.
            packageRoot: \(layout.packageRootURL.path)
            rawCharacters: \(response.content.count)
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
