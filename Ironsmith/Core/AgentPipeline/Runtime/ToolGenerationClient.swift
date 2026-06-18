import Foundation

struct ToolGenerationPreparedTool {
    let name: String
    let executableName: String
    let bundleIdentifier: String
    let sandboxEnabled: Bool
    let packageRootURL: URL
    let manifest: ToolManifest
}

struct ToolGenerationLifecycle {
    let preservesCreatedPackageOnCancellation: Bool
    nonisolated(unsafe) let prepareCreatedTool: (
        _ preparedTool: ToolGenerationPreparedTool,
        _ prompt: String
    ) async throws -> Void
    nonisolated(unsafe) let updatePendingPrompt: (_ prompt: String) async throws -> Void
    nonisolated(unsafe) let updatePhase: (
        _ state: ToolGenerationState,
        _ phase: ToolGenerationPhase?,
        _ errorSummary: String?
    ) async throws -> Void

    nonisolated init(
        preservesCreatedPackageOnCancellation: Bool = false,
        prepareCreatedTool: @escaping (
            _ preparedTool: ToolGenerationPreparedTool,
            _ prompt: String
        ) async throws -> Void = { _, _ in },
        updatePendingPrompt: @escaping (_ prompt: String) async throws -> Void = { _ in },
        updatePhase: @escaping (
            _ state: ToolGenerationState,
            _ phase: ToolGenerationPhase?,
            _ errorSummary: String?
        ) async throws -> Void = { _, _, _ in }
    ) {
        self.preservesCreatedPackageOnCancellation = preservesCreatedPackageOnCancellation
        self.prepareCreatedTool = prepareCreatedTool
        self.updatePendingPrompt = updatePendingPrompt
        self.updatePhase = updatePhase
    }

    nonisolated static var noop: ToolGenerationLifecycle {
        ToolGenerationLifecycle()
    }
}

struct ToolGenerationClient {
    private var generateToolWithLifecycle: (
        _ prompt: String,
        _ existingTool: Tool?,
        _ sandboxEnabled: Bool,
        _ sandboxPermissions: GeneratedAppSandboxPermissions,
        _ resourcePermissions: GeneratedAppResourcePermissions,
        _ languageModelContext: AgentLanguageModelContext,
        _ lifecycle: ToolGenerationLifecycle,
        _ status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult

    func generateTool(
        _ prompt: String,
        _ existingTool: Tool?,
        _ sandboxEnabled: Bool,
        _ sandboxPermissions: GeneratedAppSandboxPermissions,
        _ resourcePermissions: GeneratedAppResourcePermissions,
        _ languageModelContext: AgentLanguageModelContext,
        lifecycle: ToolGenerationLifecycle = .noop,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> ToolGenerationResult {
        try await generateToolWithLifecycle(
            prompt,
            existingTool,
            sandboxEnabled,
            sandboxPermissions,
            resourcePermissions,
            languageModelContext,
            lifecycle,
            status
        )
    }

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
        self.generateToolWithLifecycle = {
            prompt,
            existingTool,
            sandboxEnabled,
            sandboxPermissions,
            resourcePermissions,
            languageModelContext,
            _,
            status in
            try await generateTool(
                prompt,
                existingTool,
                sandboxEnabled,
                sandboxPermissions,
                resourcePermissions,
                languageModelContext,
                status
            )
        }
    }

    init(
        withLifecycle generateTool: @escaping (
            _ prompt: String,
            _ existingTool: Tool?,
            _ sandboxEnabled: Bool,
            _ sandboxPermissions: GeneratedAppSandboxPermissions,
            _ resourcePermissions: GeneratedAppResourcePermissions,
            _ languageModelContext: AgentLanguageModelContext,
            _ lifecycle: ToolGenerationLifecycle,
            _ status: @escaping @MainActor (String) -> Void
        ) async throws -> ToolGenerationResult
    ) {
        self.generateToolWithLifecycle = generateTool
    }

    static func live(
        toolsDirectoryURL: URL = IronsmithPaths.toolsDirectory,
        fileClient: AgentFileClient = .live,
        processClient: SwiftPackageProcessClient = .live,
        appBundleClient: ToolAppBundleClient = .live(),
        iconClient: ToolIconClient = .live(),
        metadataClient: ToolMetadataClient = .live(),
        promptRefinementClient: ToolPromptRefinementClient = .live(),
        versionBackupClient: ToolVersionBackupClient = .live
    ) -> Self {
        Self(withLifecycle: { prompt, existingTool, sandboxEnabled, sandboxPermissions, resourcePermissions, languageModelContext, lifecycle, status in
            let context = ToolGenerationRuntimeContext(
                languageModel: languageModelContext.languageModel,
                metadataLanguageModel: languageModelContext.metadataLanguageModel,
                generationOptions: languageModelContext.options,
                repairStrategy: languageModelContext.repairStrategy,
                toolsDirectoryURL: toolsDirectoryURL,
                fileClient: fileClient,
                processClient: processClient,
                appBundleClient: appBundleClient,
                iconClient: iconClient,
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
                lifecycle: lifecycle,
                status: status
            )
        })
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
