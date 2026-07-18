import Foundation

nonisolated struct CodexAgentCustomResponsesProvider: Equatable, Sendable {
    let configurationIdentifier: String
    let sessionProviderIdentifier: String
    let displayName: String
    let baseURL: URL
    let authenticationEnvironmentVariable: String?
    let authenticationToken: String?
}

nonisolated enum CodexAgentToolCompatibility: String, Codable, Equatable, Sendable {
    case openAINative = "openai_native"
    case portable

    static func resolved(
        modelIdentifier: String,
        authentication: CodexAgentAuthentication
    ) -> Self {
        switch authentication {
        case .apiKey, .chatGPTLogin:
            return .openAINative
        case .customResponsesProvider:
            return isOpenAIModelIdentifier(modelIdentifier) ? .openAINative : .portable
        }
    }

    private static func isOpenAIModelIdentifier(_ identifier: String) -> Bool {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ToolModelFamily.resolved(identifier: normalized) == .openAI
    }
}

enum CodexAgentAuthentication: Equatable, Sendable {
    case apiKey(String)
    case chatGPTLogin
    case customResponsesProvider(CodexAgentCustomResponsesProvider)
}

nonisolated struct CodexAgentRequest: Sendable {
    let packageRootURL: URL
    let executableName: String
    let displayName: String
    let appKind: ToolAppKind
    let sandboxEnabled: Bool
    let userPrompt: String
    let modelIdentifier: String
    let reasoningEffort: ToolReasoningEffort
    let authentication: CodexAgentAuthentication
    let supportsImageInput: Bool
    let onEvent: @Sendable (CodexAgentEvent) async -> Void

    var toolCompatibility: CodexAgentToolCompatibility {
        CodexAgentToolCompatibility.resolved(
            modelIdentifier: modelIdentifier,
            authentication: authentication
        )
    }

    var sessionProviderIdentifier: String {
        switch authentication {
        case .apiKey:
            return "openai-api"
        case .chatGPTLogin:
            return "openai-chatgpt"
        case .customResponsesProvider(let provider):
            return provider.sessionProviderIdentifier
        }
    }

    init(
        packageRootURL: URL,
        executableName: String,
        displayName: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool,
        userPrompt: String,
        modelIdentifier: String,
        reasoningEffort: ToolReasoningEffort = .default,
        authentication: CodexAgentAuthentication,
        supportsImageInput: Bool = true,
        onEvent: @escaping @Sendable (CodexAgentEvent) async -> Void = { _ in }
    ) {
        self.packageRootURL = packageRootURL
        self.executableName = executableName
        self.displayName = displayName
        self.appKind = appKind
        self.sandboxEnabled = sandboxEnabled
        self.userPrompt = userPrompt
        self.modelIdentifier = modelIdentifier
        self.reasoningEffort = reasoningEffort
        self.authentication = authentication
        self.supportsImageInput = supportsImageInput
        self.onEvent = onEvent
    }
}

nonisolated struct CodexAgentResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
    let transcriptURL: URL
}

nonisolated struct CodexAgentSwiftBuildWorkspace: Equatable, Sendable {
    let rootURL: URL

    var homeURL: URL {
        rootURL.appendingPathComponent("home", isDirectory: true)
    }

    var cacheURL: URL {
        rootURL.appendingPathComponent("cache", isDirectory: true)
    }

    var clangModuleCacheURL: URL {
        rootURL.appendingPathComponent("clang-module-cache", isDirectory: true)
    }

    var swiftModuleCacheURL: URL {
        rootURL.appendingPathComponent("swift-module-cache", isDirectory: true)
    }

    var temporaryDirectoryURL: URL {
        rootURL.appendingPathComponent("tmp", isDirectory: true)
    }

    var directories: [URL] {
        [
            rootURL,
            homeURL,
            cacheURL,
            clangModuleCacheURL,
            swiftModuleCacheURL,
            temporaryDirectoryURL,
        ]
    }

    var environment: [String: String] {
        [
            "HOME": homeURL.path,
            "XDG_CACHE_HOME": cacheURL.path,
            "CLANG_MODULE_CACHE_PATH": clangModuleCacheURL.path,
            "SWIFTPM_MODULECACHE_OVERRIDE": swiftModuleCacheURL.path,
            "SWIFT_MODULE_CACHE_PATH": swiftModuleCacheURL.path,
        ]
    }

    static func create(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> Self {
        let workspace = Self(
            rootURL: temporaryDirectory.appendingPathComponent(
                "ironsmith-codex-swift-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        for directory in workspace.directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return workspace
    }

    func remove(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

}

nonisolated enum CodexAgentEvent: Equatable, Sendable {
    case threadStarted(String?)
    case turnStarted
    case turnCompleted
    case agentMessage(String)
    case commandExecution(id: String?, command: String, status: String?, exitCode: Int?)
    case fileChange(id: String?, changes: [CodexAgentFileChange], status: String?)
    case webSearch(id: String?, search: CodexAgentWebSearch, status: String?)
    case todoList(id: String?, items: [CodexAgentTodoItem], status: String?)
    case error(String)

    var diagnosticSummary: String? {
        switch self {
        case .threadStarted(let id):
            return "Codex thread started\(id.map { ": \($0)" } ?? "")."
        case .turnStarted:
            return "Codex turn started."
        case .turnCompleted:
            return "Codex turn completed."
        case .agentMessage(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? nil : "Codex: \(AgentDiagnosticsLog.compact(trimmed, limit: 500))"
        case .commandExecution(_, let command, let status, let exitCode):
            guard status != "in_progress" else { return nil }
            var summary = "Codex command"
            if let status = CodexAgentStatusFormatter.displayText(status) {
                summary += " \(status)"
            }
            if let exitCode {
                summary += " (exit \(exitCode))"
            }
            return "\(summary): \(AgentDiagnosticsLog.compact(command, limit: 500))"
        case .fileChange(_, let changes, let status):
            guard status != "in_progress" else { return nil }
            let changeSummary =
                changes
                .map { $0.diagnosticSummary }
                .joined(separator: ", ")
            guard !changeSummary.isEmpty else { return nil }
            var summary = "Codex file change"
            if let status = CodexAgentStatusFormatter.displayText(status) {
                summary += " \(status)"
            }
            return "\(summary): \(AgentDiagnosticsLog.compact(changeSummary, limit: 500))"
        case .webSearch(_, let search, let status):
            guard status != "in_progress" else { return nil }
            var summary = "Codex web search"
            if let status = CodexAgentStatusFormatter.displayText(status) {
                summary += " \(status)"
            }
            return
                "\(summary): \(AgentDiagnosticsLog.compact(search.diagnosticSummary, limit: 500))"
        case .todoList(_, let items, let status):
            guard status != "in_progress" else { return nil }
            let completedCount = items.count(where: \.completed)
            var summary = "Codex todo list"
            if let status = CodexAgentStatusFormatter.displayText(status) {
                summary += " \(status)"
            }
            return "\(summary): \(completedCount)/\(items.count) completed"
        case .error(let message):
            return "Codex error: \(AgentDiagnosticsLog.compact(message, limit: 500))"
        }
    }

    static func parse(jsonLine line: String) -> CodexAgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return nil
        }

        switch type {
        case "thread.started":
            return .threadStarted(stringValue(in: object, keys: ["thread_id", "threadId", "id"]))
        case "turn.started":
            return .turnStarted
        case "turn.completed":
            return .turnCompleted
        case "error":
            return .error(message(in: object) ?? "Codex reported an error.")
        case "item.started", "item.completed":
            return itemEvent(object)
        case "item.updated":
            guard let item = object["item"] as? [String: Any],
                stringValue(in: item, keys: ["type"]) == "todo_list"
            else {
                return nil
            }
            return itemEvent(object)
        default:
            return nil
        }
    }

    private static func itemEvent(_ object: [String: Any]) -> CodexAgentEvent? {
        guard let item = object["item"] as? [String: Any],
            let itemType = stringValue(in: item, keys: ["type"])
        else {
            return nil
        }

        switch itemType {
        case "agent_message":
            guard let text = stringValue(in: item, keys: ["text"]) else { return nil }
            return .agentMessage(text)
        case "command_execution":
            guard let command = stringValue(in: item, keys: ["command"]) else { return nil }
            return .commandExecution(
                id: stringValue(in: item, keys: ["id"]),
                command: command,
                status: stringValue(in: item, keys: ["status"]),
                exitCode: intValue(item["exit_code"])
            )
        case "file_change":
            let changes = fileChanges(in: item)
            guard !changes.isEmpty else { return nil }
            return .fileChange(
                id: stringValue(in: item, keys: ["id"]),
                changes: changes,
                status: stringValue(in: item, keys: ["status"])
            )
        case "web_search":
            return .webSearch(
                id: stringValue(in: item, keys: ["id"]),
                search: webSearch(in: item),
                status: stringValue(in: item, keys: ["status"]) ?? status(fromEnvelope: object)
            )
        case "todo_list":
            let items = todoItems(in: item)
            guard !items.isEmpty else { return nil }
            return .todoList(
                id: stringValue(in: item, keys: ["id"]),
                items: items,
                status: stringValue(in: item, keys: ["status"]) ?? status(fromEnvelope: object)
            )
        default:
            return nil
        }
    }

    private static func fileChanges(in object: [String: Any]) -> [CodexAgentFileChange] {
        guard let changes = object["changes"] as? [[String: Any]] else { return [] }
        return changes.compactMap { change in
            guard let path = stringValue(in: change, keys: ["path"]) else { return nil }
            return CodexAgentFileChange(
                path: path,
                kind: stringValue(in: change, keys: ["kind"])
            )
        }
    }

    private static func webSearch(in object: [String: Any]) -> CodexAgentWebSearch {
        let action = object["action"] as? [String: Any]
        let queries = action?["queries"] as? [String] ?? []
        return CodexAgentWebSearch(
            query: stringValue(in: object, keys: ["query"]),
            actionType: action.flatMap { stringValue(in: $0, keys: ["type"]) },
            actionQuery: action.flatMap { stringValue(in: $0, keys: ["query"]) },
            queries: queries
        )
    }

    private static func todoItems(in object: [String: Any]) -> [CodexAgentTodoItem] {
        guard let items = object["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let text = stringValue(in: item, keys: ["text"]) else { return nil }
            return CodexAgentTodoItem(
                text: text,
                completed: item["completed"] as? Bool ?? false
            )
        }
    }

    private static func message(in object: [String: Any]) -> String? {
        stringValue(in: object, keys: ["message", "text", "detail", "error"])
    }

    private static func status(fromEnvelope object: [String: Any]) -> String? {
        switch stringValue(in: object, keys: ["type"]) {
        case "item.started", "item.updated":
            return "in_progress"
        case "item.completed":
            return "completed"
        default:
            return nil
        }
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }
}

nonisolated struct CodexAgentTodoItem: Equatable, Sendable {
    let text: String
    let completed: Bool
}

nonisolated struct CodexAgentFileChange: Equatable, Sendable {
    let path: String
    let kind: String?

    var diagnosticSummary: String {
        if let kind, !kind.isEmpty {
            return
                "\(CodexAgentStatusFormatter.displayText(kind) ?? kind) \(CodexAgentPathDisplay.compact(path))"
        }
        return CodexAgentPathDisplay.compact(path)
    }
}

nonisolated struct CodexAgentWebSearch: Equatable, Sendable {
    let query: String?
    let actionType: String?
    let actionQuery: String?
    let queries: [String]

    var displayText: String {
        normalized(actionQuery)
            ?? normalized(query)
            ?? queries.first.flatMap { normalized($0) }
            ?? "Web search"
    }

    var diagnosticSummary: String {
        displayText
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum CodexAgentStatusFormatter {
    static func displayText(_ status: String?) -> String? {
        guard let status, !status.isEmpty else { return nil }
        switch status {
        case "in_progress":
            return "In progress"
        default:
            return
                status
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}

nonisolated enum CodexAgentPathDisplay {
    static func compact(_ path: String) -> String {
        if let range = path.range(of: "/Sources/") {
            return "Sources/" + String(path[range.upperBound...])
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

nonisolated struct CodexAgentClient: Sendable {
    var run: @Sendable (CodexAgentRequest) async throws -> CodexAgentResult
}

nonisolated private enum CodexAgentAttachmentAccess {
    case readOnly
    case denied

    var filesystemAccess: String {
        switch self {
        case .readOnly: "read"
        case .denied: "deny"
        }
    }
}

extension CodexAgentClient {
    nonisolated private static let portableToolArguments = [
        "-c", #"web_search="disabled""#,
        "-c", "apps._default.enabled=false",
        "--disable", "apps",
        "--disable", "tool_suggest",
        "--disable", "multi_agent",
        "--disable", "image_generation",
        "--disable", "computer_use",
        "--disable", "browser_use",
        "--disable", "browser_use_external",
        "--disable", "in_app_browser",
    ]

    nonisolated static func live(
        cliClient: CodexCLIClient = .live(),
        openAICodexAuthClient: OpenAICodexAuthClient = .live(),
        attachmentStorage: ToolPromptAttachmentStorage = .live,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Self {
        Self { request in
            var customProviderArguments: [String] = []
            switch request.authentication {
            case .apiKey:
                break
            case .chatGPTLogin:
                _ = try await openAICodexAuthClient.validCredential()
            case .customResponsesProvider(let provider):
                customProviderArguments = configurationArguments(for: provider)
            }

            let latestSession = CodexAgentTranscriptReader.latestSession(
                for: request.packageRootURL,
                providerIdentifier: request.sessionProviderIdentifier,
                toolCompatibility: request.toolCompatibility
            )
            let layout = ToolPackageLayout(
                packageRootURL: request.packageRootURL,
                executableName: request.executableName
            )
            let storedAttachments = try attachmentStorage.currentRun(layout)
            let exposedAttachments = request.supportsImageInput ? storedAttachments : []
            let storedRunContainsImages = storedAttachments.contains(where: \.isImage)
            let resumeSession = latestSession.flatMap { session in
                !request.supportsImageInput
                    && (session.containsImageContext || storedRunContainsImages) ? nil : session
            }
            let containsImageContext =
                (resumeSession?.containsImageContext ?? false)
                || exposedAttachments.contains(where: \.isImage)
            let transcriptFile = try CodexAgentTranscriptFile(
                packageRootURL: request.packageRootURL,
                providerIdentifier: request.sessionProviderIdentifier,
                toolCompatibility: request.toolCompatibility,
                containsImageContext: containsImageContext
            )
            let swiftBuildWorkspace = try CodexAgentSwiftBuildWorkspace.create(
                temporaryDirectory: temporaryDirectory
            )
            defer {
                try? swiftBuildWorkspace.remove()
            }
            let attachmentAccess: CodexAgentAttachmentAccess =
                exposedAttachments.isEmpty ? .denied : .readOnly
            var environment = swiftBuildWorkspace.environment
            switch request.authentication {
            case .apiKey(let apiKey):
                environment["CODEX_API_KEY"] = apiKey
            case .chatGPTLogin:
                break
            case .customResponsesProvider(let provider):
                if let environmentVariable = provider.authenticationEnvironmentVariable,
                    let token = provider.authenticationToken,
                    !token.isEmpty
                {
                    environment[environmentVariable] = token
                }
            }

            var arguments = ["exec"]
            arguments.append(contentsOf: attachmentPermissionArguments(attachmentAccess))
            arguments.append(contentsOf: customProviderArguments)
            if request.toolCompatibility == .portable {
                arguments.append(contentsOf: portableToolArguments)
            }
            arguments.append(contentsOf: [
                "--json",
                "--cd",
                request.packageRootURL.path,
                "--skip-git-repo-check",
            ])
            if let model = modelArgument(from: request.modelIdentifier) {
                arguments.append(contentsOf: ["--model", model])
            }
            if request.reasoningEffort != .default {
                arguments.append(contentsOf: [
                    "-c", "model_reasoning_effort=\(tomlString(request.reasoningEffort.rawValue))",
                ])
            }
            if let resumeSession {
                arguments.append("resume")
                for attachment in exposedAttachments where attachment.isImage {
                    arguments.append(contentsOf: ["--image", attachment.url.path])
                }
                arguments.append(resumeSession.threadID)
            } else {
                for attachment in exposedAttachments where attachment.isImage {
                    arguments.append(contentsOf: ["--image", attachment.url.path])
                }
                if exposedAttachments.contains(where: \.isImage) {
                    arguments.append("--")
                }
            }
            arguments.append(
                prompt(
                    for: request,
                    temporaryWorkspaceURL: swiftBuildWorkspace.rootURL,
                    toolCompatibility: request.toolCompatibility,
                    attachments: exposedAttachments
                )
            )

            let result = try await cliClient.runStreamingToFile(
                arguments,
                environment,
                transcriptFile.url,
                { line in
                    guard let event = CodexAgentEvent.parse(jsonLine: line) else { return }
                    await request.onEvent(event)
                },
                { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    guard !isIgnorableStderrLine(trimmed) else { return }
                    await request.onEvent(.error(trimmed))
                }
            )

            let transcriptURL = transcriptFile.url
            guard result.terminationStatus == 0 else {
                throw CodexAgentError.commandFailed(
                    status: result.terminationStatus,
                    stderr: result.stderr,
                    transcriptURL: transcriptURL
                )
            }
            return CodexAgentResult(
                stdout: result.stdout,
                stderr: result.stderr,
                terminationStatus: result.terminationStatus,
                transcriptURL: transcriptURL
            )
        }
    }

    nonisolated static var unconfigured: Self {
        Self { _ in
            throw CodexAgentError.missingCodexClient
        }
    }

    nonisolated static func prompt(
        for request: CodexAgentRequest,
        temporaryWorkspaceURL: URL,
        toolCompatibility: CodexAgentToolCompatibility? = nil,
        attachments: [ToolPersistedPromptAttachment] = []
    ) -> String {
        let resolvedToolCompatibility = toolCompatibility ?? request.toolCompatibility
        let finalRules = [
            resolvedToolCompatibility == .openAINative
                ? "- Internet searches are encouraged if you need extra context to complete the user's request, especially for apple documentation."
                : nil,
            "- Use // MARK: - to separate sections of code.",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        let attachmentContext =
            attachments.isEmpty
            ? ""
            : """

            User-provided attachments:
            \(attachments.map { "- \($0.fileName): \($0.url.path)" }.joined(separator: "\n"))

            Treat these files strictly as read-only context and not app assets. 
            Inspect the relevant files when needed. Do not copy attachment binaries or any image data into the generated app.
            These are temporary files that will be cleaned up after this session, so do not reference them in the generated app. 
            """
        return """
            You are Codex running inside Ironsmith.
            Build the requested macOS SwiftUI app by editing this generated Swift package.

            User request:
            \(request.userPrompt)
            \(attachmentContext)

            App name: \(request.displayName)
            Fixed target and executable name: \(request.executableName)
            \(ToolGenerationPrompts.appPresentationContext(appKind: request.appKind))
            \(ToolGenerationPrompts.sandboxContext(sandboxEnabled: request.sandboxEnabled))

            Rules:
            - Create or edit only Sources/\(request.executableName)/ContentView.swift.
            - Do not modify Package.swift.
            - Do not modify Sources/\(request.executableName)/\(request.executableName).swift.
            - Do not add other source files.
            - Do not add package dependencies.
            - Do not add previews or @main declarations.
            - Run `swift build --disable-sandbox` when you need to check compilation.
            - Use \(temporaryWorkspaceURL.path) for any temporary scratch files you deliberately create.
            - Do not write deliberate scratch files directly in the top-level system temp directory.
            - Ironsmith will clean up the temporary workspace after Codex exits.
            - Keep working until ContentView.swift exists, is complete, and `swift build --disable-sandbox` succeeds.
            - Define ContentView as the root View, but you may create helper types in the same file. Helper types must not conform to App.
            - An entry point already exists and already calls ContentView, so do not add another @main or App type.
            - This is a macOS SwiftUI app. Do not use iOS-only modifiers.
            - This is a local only app. Do not add or imply a separate backend service, custom server component, account system, iCloud/CloudKit integration, push notifications, analytics, subscriptions, or cross-device sync.
            - Make the app feel native to macOS.
            - Games, drawing canvases, and highly visual toys may use custom graphics and game-like UI, but they should still use sensible macOS window sizing, pointer and keyboard behavior, and local-only state.
            - Apple frameworks and APIs are allowed and encouraged over custom solutions, but do not add any third-party dependencies.
            \(finalRules)
            """
    }

    nonisolated private static func modelArgument(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OpenAICodexBackend.rawCodexModelIdentifier(from: trimmed) ?? trimmed
    }

    nonisolated private static func configurationArguments(
        for provider: CodexAgentCustomResponsesProvider
    ) -> [String] {
        let prefix = "model_providers.\(provider.configurationIdentifier)"
        var arguments = [
            "-c", "model_provider=\(tomlString(provider.configurationIdentifier))",
            "-c", "\(prefix).name=\(tomlString(provider.displayName))",
            "-c", "\(prefix).base_url=\(tomlString(provider.baseURL.absoluteString))",
            "-c", "\(prefix).wire_api=\(tomlString("responses"))",
            "-c", "\(prefix).requires_openai_auth=false",
        ]
        if let environmentVariable = provider.authenticationEnvironmentVariable {
            arguments.append(contentsOf: [
                "-c", "\(prefix).env_key=\(tomlString(environmentVariable))",
            ])
        }
        return arguments
    }

    nonisolated private static func attachmentPermissionArguments(
        _ access: CodexAgentAttachmentAccess
    ) -> [String] {
        [
            "-c",
            #"default_permissions="ironsmith-workspace""#,
            "-c",
            #"permissions.ironsmith-workspace={ extends = ":workspace", filesystem = { ":workspace_roots" = { ".ironsmith/attachments/current-run" = "\#(access.filesystemAccess)" } } }"#,
        ]
    }

    nonisolated private static func tomlString(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private static func isIgnorableStderrLine(_ line: String) -> Bool {
        line.contains("FSEventsPurgeEventsForDeviceUpToEventId")
            || line.contains("f2d_purge_events_for_device_up_to_event_id_rpc() failed")
            || line.contains("purging events up to event id")
    }
}

enum CodexAgentError: LocalizedError, Equatable {
    case missingCodexClient
    case unsupportedProvider
    case missingAuthenticationForRuntime
    case commandFailed(status: Int32, stderr: String, transcriptURL: URL)
    case protectedFileChanged(String)
    case missingContentView

    var errorDescription: String? {
        switch self {
        case .missingCodexClient:
            return "Codex is not configured."
        case .unsupportedProvider:
            return "Codex is not supported by the selected provider API."
        case .missingAuthenticationForRuntime:
            return "Codex authentication was not prepared for this generation."
        case .commandFailed(let status, let stderr, let transcriptURL):
            if status == 1 {
                return
                    "Codex couldn't continue. You might be out of Codex usage. Check your usage in Codex and try again after it resets. Transcript: \(transcriptURL.path)"
            }
            let output = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty {
                return "Codex exited with status \(status). Transcript: \(transcriptURL.path)"
            }
            return
                "Codex exited with status \(status): \(AgentDiagnosticsLog.compact(redactSecrets(output), limit: 1_500)). Transcript: \(transcriptURL.path)"
        case .protectedFileChanged(let path):
            return
                "Codex changed \(path), but Ironsmith only allows Codex to edit ContentView.swift."
        case .missingContentView:
            return "Codex did not create ContentView.swift."
        }
    }

    private func redactSecrets(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?:sk|rk|sess|rt)\.[A-Za-z0-9_\-.]+"#,
                with: "[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"Bearer\s+[A-Za-z0-9_\-.]+"#,
                with: "Bearer [redacted]",
                options: .regularExpression
            )
    }
}

nonisolated private struct CodexAgentTranscriptFile: Sendable {
    let url: URL

    init(
        packageRootURL: URL,
        providerIdentifier: String,
        toolCompatibility: CodexAgentToolCompatibility,
        containsImageContext: Bool = false
    ) throws {
        let directoryURL = packageRootURL.appendingPathComponent(".codex", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileName = "agent-\(Self.timestamp())-\(UUID().uuidString.lowercased()).jsonl"
        let url = directoryURL.appendingPathComponent(fileName)
        try Data().write(to: url, options: .atomic)
        try CodexAgentTranscriptReader.writeMetadata(
            CodexAgentSessionMetadata(
                providerIdentifier: providerIdentifier,
                toolCompatibility: toolCompatibility,
                transcriptFileName: fileName,
                containsImageContext: containsImageContext
            ),
            for: url
        )
        self.url = url
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}
