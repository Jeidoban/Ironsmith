import Foundation

nonisolated struct ToolGenerationPreparedTool {
    let name: String
    let executableName: String
    let bundleIdentifier: String
    let settings: ToolGenerationSettings
    let packageRootURL: URL

    init(
        name: String,
        executableName: String,
        bundleIdentifier: String,
        settings: ToolGenerationSettings,
        packageRootURL: URL
    ) {
        self.name = name
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.settings = settings
        self.packageRootURL = packageRootURL
    }
}

struct ToolGenerationLifecycle {
    let preservesCreatedPackageOnCancellation: Bool
    nonisolated(unsafe) let prepareCreatedTool: (
        _ preparedTool: ToolGenerationPreparedTool,
        _ prompt: String
    ) async throws -> Void
    nonisolated(unsafe) let updatePendingPrompt: (_ prompt: String) async throws -> Void
    nonisolated(unsafe) let updateRepairErrorCount: (_ count: Int?) async throws -> Void
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
        updateRepairErrorCount: @escaping (_ count: Int?) async throws -> Void = { _ in },
        updatePhase: @escaping (
            _ state: ToolGenerationState,
            _ phase: ToolGenerationPhase?,
            _ errorSummary: String?
        ) async throws -> Void = { _, _, _ in }
    ) {
        self.preservesCreatedPackageOnCancellation = preservesCreatedPackageOnCancellation
        self.prepareCreatedTool = prepareCreatedTool
        self.updatePendingPrompt = updatePendingPrompt
        self.updateRepairErrorCount = updateRepairErrorCount
        self.updatePhase = updatePhase
    }

    nonisolated static var noop: ToolGenerationLifecycle {
        ToolGenerationLifecycle()
    }
}

nonisolated struct ToolGenerationRequest {
    let prompt: String
    let existingTool: Tool?
    let settings: ToolGenerationSettings
    let languageModelContext: AgentLanguageModelContext
    let imageGenerationProvider: ToolImageGenerationProvider
    let lifecycle: ToolGenerationLifecycle

    init(
        prompt: String,
        existingTool: Tool? = nil,
        settings: ToolGenerationSettings,
        languageModelContext: AgentLanguageModelContext,
        imageGenerationProvider: ToolImageGenerationProvider = .disabled,
        lifecycle: ToolGenerationLifecycle = .noop
    ) {
        self.prompt = prompt
        self.existingTool = existingTool
        self.settings = settings
        self.languageModelContext = languageModelContext
        self.imageGenerationProvider = imageGenerationProvider
        self.lifecycle = lifecycle
    }
}

struct ToolGenerationClient {
    private var generate: (ToolGenerationRequest) async throws -> ToolGenerationResult

    func generateTool(_ request: ToolGenerationRequest) async throws -> ToolGenerationResult {
        try await generate(request)
    }

    init(
        _ generate: @escaping (ToolGenerationRequest) async throws -> ToolGenerationResult
    ) {
        self.generate = generate
    }

    @MainActor
    static func live(
        dependencies: ToolGenerationRuntimeDependencies? = nil
    ) -> Self {
        let dependencies = dependencies ?? .live()
        return Self { request in
            let context = ToolGenerationRuntimeContext(
                languageModelContext: request.languageModelContext,
                dependencies: dependencies
            )
            let runtime = SingleFileToolGenerationRuntime(context: context)
            return try await runtime.generateTool(
                for: request.prompt,
                existingTool: request.existingTool,
                settings: request.settings,
                imageGenerationProvider: request.imageGenerationProvider,
                lifecycle: request.lifecycle
            )
        }
    }
}

struct ToolRunnerClient {
    var runTool: (_ tool: Tool) async throws -> Void
    var quitTool: (_ tool: Tool) async throws -> Void
    var isToolRunning: (_ tool: Tool) async -> Bool

    init(
        _ runTool: @escaping (_ tool: Tool) async throws -> Void,
        quitTool: @escaping (_ tool: Tool) async throws -> Void = { _ in },
        isToolRunning: @escaping (_ tool: Tool) async -> Bool = { _ in false }
    ) {
        self.runTool = runTool
        self.quitTool = quitTool
        self.isToolRunning = isToolRunning
    }

    static func live(appBundleClient: ToolAppBundleClient = .live()) -> Self {
        Self(
            { tool in
                let request = ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(tool)
                if !appBundleClient.appExists(request.internalAppBundleURL)
                    || needsQuitOnCloseRebuild(request)
                {
                    _ = try await appBundleClient.buildInternalApp(request)
                }
                try await appBundleClient.launchApp(request.internalAppBundleURL)
            },
            quitTool: { tool in
                try await appBundleClient.terminateApp(tool.appBundleURL)
            },
            isToolRunning: { tool in
                await appBundleClient.isAppRunning(tool.appBundleURL)
            }
        )
    }

    private static func needsQuitOnCloseRebuild(_ request: ToolAppBundleRequest) -> Bool {
        guard request.appKind == .window else { return false }
        guard appEntrySourceSupportsQuitOnClose(request) else { return true }

        let plistURL = request.internalAppBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else {
            return true
        }
        return dictionary["IronsmithQuitOnLastWindowClose"] as? Bool != true
    }

    private static func appEntrySourceSupportsQuitOnClose(_ request: ToolAppBundleRequest) -> Bool {
        guard let appEntryURL = try? request.layout.packageFileURL(for: request.layout.appEntrySourcePath),
              let source = try? String(contentsOf: appEntryURL, encoding: .utf8)
        else {
            return false
        }
        return source.contains("applicationShouldTerminateAfterLastWindowClosed")
            && source.contains("IronsmithQuitOnLastWindowClose")
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
