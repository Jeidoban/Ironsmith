import Foundation

struct ToolGenerationClient {
    var generateTool: (
        _ prompt: String,
        _ existingTool: Tool?,
        _ sandboxEnabled: Bool,
        _ sandboxPermissions: GeneratedAppSandboxPermissions,
        _ resourcePermissions: GeneratedAppResourcePermissions,
        _ languageModelContext: AgentLanguageModelContext,
        _ status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult

    init(
        _ generateTool: @escaping (
            _ prompt: String,
            _ existingTool: Tool?,
            _ sandboxEnabled: Bool,
            _ sandboxPermissions: GeneratedAppSandboxPermissions,
            _ resourcePermissions: GeneratedAppResourcePermissions,
            _ languageModelContext: AgentLanguageModelContext,
            _ status: @escaping @MainActor (String) -> Void
        ) async throws -> ToolGenerationResult
    ) {
        self.generateTool = generateTool
    }

    static func live(
        toolsDirectoryURL: URL = IronsmithPaths.toolsDirectory,
        fileClient: AgentFileClient = .live,
        processClient: SwiftPackageProcessClient = .live,
        appBundleClient: ToolAppBundleClient = .live(),
        metadataClient: ToolMetadataClient = .live(),
        promptRefinementClient: ToolPromptRefinementClient = .live(),
        versionBackupClient: ToolVersionBackupClient = .live
    ) -> Self {
        Self { prompt, existingTool, sandboxEnabled, sandboxPermissions, resourcePermissions, languageModelContext, status in
            let context = ToolGenerationRuntimeContext(
                languageModel: languageModelContext.languageModel,
                metadataLanguageModel: languageModelContext.metadataLanguageModel,
                generationOptions: languageModelContext.options,
                repairStrategy: languageModelContext.repairStrategy,
                toolsDirectoryURL: toolsDirectoryURL,
                fileClient: fileClient,
                processClient: processClient,
                appBundleClient: appBundleClient,
                metadataClient: metadataClient,
                promptRefinementClient: promptRefinementClient,
                promptRefinementEnabled: languageModelContext.promptRefinementEnabled,
                versionBackupClient: versionBackupClient,
                afterLanguageModelInvocation: languageModelContext.afterLanguageModelInvocation
            )
            let runtime = SingleFileToolGenerationRuntime(context: context)
            return try await runtime.generateTool(
                for: prompt,
                existingTool: existingTool,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                status: status
            )
        }
    }
}

struct ToolRunnerClient {
    var runTool: (_ tool: Tool) async throws -> Void

    static func live(appBundleClient: ToolAppBundleClient = .live()) -> Self {
        Self { tool in
            let request = ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(tool)
            if !appBundleClient.appExists(request.internalAppBundleURL) {
                _ = try await appBundleClient.buildInternalApp(request)
            }
            try await appBundleClient.launchApp(request.internalAppBundleURL)
        }
    }
}

struct ToolBuildClient {
    var buildTool: (_ tool: Tool) async throws -> Void

    static func live(appBundleClient: ToolAppBundleClient = .live()) -> Self {
        Self { tool in
            _ = try await appBundleClient.buildInternalApp(
                ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(tool)
            )
        }
    }
}

struct ToolExportClient {
    var exportTool: (_ tool: Tool) async throws -> URL

    static func live(
        appBundleClient: ToolAppBundleClient = .live(),
        applicationsDirectoryURL: URL = ToolAppBundleClient.applicationsDirectoryURL
    ) -> Self {
        Self { tool in
            try await appBundleClient.exportApp(
                ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(tool),
                applicationsDirectoryURL
            )
        }
    }
}
