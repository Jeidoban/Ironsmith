import Foundation

enum CodexAgentAuthentication: Equatable, Sendable {
    case apiKey(String)
    case chatGPTLogin
}

nonisolated struct CodexAgentRequest: Sendable {
    let packageRootURL: URL
    let executableName: String
    let displayName: String
    let appKind: ToolAppKind
    let sandboxEnabled: Bool
    let userPrompt: String
    let modelIdentifier: String
    let authentication: CodexAgentAuthentication
    let onEvent: @Sendable (CodexAgentEvent) async -> Void

    init(
        packageRootURL: URL,
        executableName: String,
        displayName: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool,
        userPrompt: String,
        modelIdentifier: String,
        authentication: CodexAgentAuthentication,
        onEvent: @escaping @Sendable (CodexAgentEvent) async -> Void = { _ in }
    ) {
        self.packageRootURL = packageRootURL
        self.executableName = executableName
        self.displayName = displayName
        self.appKind = appKind
        self.sandboxEnabled = sandboxEnabled
        self.userPrompt = userPrompt
        self.modelIdentifier = modelIdentifier
        self.authentication = authentication
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
    case commandExecution(command: String, status: String?, exitCode: Int?)
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
        case .commandExecution(let command, let status, let exitCode):
            var summary = "Codex command"
            if let status, !status.isEmpty {
                summary += " \(status)"
            }
            if let exitCode {
                summary += " (exit \(exitCode))"
            }
            return "\(summary): \(AgentDiagnosticsLog.compact(command, limit: 500))"
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
                command: command,
                status: stringValue(in: item, keys: ["status"]),
                exitCode: intValue(item["exit_code"])
            )
        default:
            return nil
        }
    }

    private static func message(in object: [String: Any]) -> String? {
        stringValue(in: object, keys: ["message", "text", "detail", "error"])
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

nonisolated struct CodexAgentClient: Sendable {
    var run: @Sendable (CodexAgentRequest) async throws -> CodexAgentResult
}

extension CodexAgentClient {
    nonisolated static func live(
        cliClient: CodexCLIClient = .live(),
        openAICodexAuthClient: OpenAICodexAuthClient = .live(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Self {
        Self { request in
            let openAIAPIKey: String?
            switch request.authentication {
            case .apiKey(let apiKey):
                openAIAPIKey = apiKey
            case .chatGPTLogin:
                _ = try await openAICodexAuthClient.validCredential()
                openAIAPIKey = nil
            }

            let transcriptWriter = try CodexAgentTranscriptWriter(
                packageRootURL: request.packageRootURL
            )
            let swiftBuildWorkspace = try CodexAgentSwiftBuildWorkspace.create(
                temporaryDirectory: temporaryDirectory
            )
            defer {
                try? swiftBuildWorkspace.remove()
            }
            var environment = swiftBuildWorkspace.environment
            if let openAIAPIKey {
                environment["OPENAI_API_KEY"] = openAIAPIKey
            }

            var arguments = [
                "exec",
                "--json",
                "--sandbox",
                "workspace-write",
                "--cd",
                request.packageRootURL.path,
                "--skip-git-repo-check",
            ]
            if let model = modelArgument(from: request.modelIdentifier) {
                arguments.append(contentsOf: ["--model", model])
            }
            arguments.append(
                prompt(for: request, temporaryWorkspaceURL: swiftBuildWorkspace.rootURL)
            )

            let result = try await cliClient.runStreaming(
                arguments,
                environment,
                { line in
                    await transcriptWriter.writeLine(line)
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
            await transcriptWriter.close()

            let transcriptURL = transcriptWriter.url
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
        temporaryWorkspaceURL: URL
    ) -> String {
        """
        You are Codex running inside Ironsmith.
        Build the requested macOS SwiftUI app by editing this generated Swift package.

        User request:
        \(request.userPrompt)

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
        - Use // MARK: - to separate sections of code.
        """
    }

    nonisolated private static func modelArgument(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OpenAICodexBackend.rawCodexModelIdentifier(from: trimmed) ?? trimmed
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
            return "Codex currently supports OpenAI models only."
        case .missingAuthenticationForRuntime:
            return "Codex authentication was not prepared for this generation."
        case .commandFailed(let status, let stderr, let transcriptURL):
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

private actor CodexAgentTranscriptWriter {
    let url: URL
    private let fileHandle: FileHandle

    init(
        packageRootURL: URL
    ) throws {
        let directoryURL = packageRootURL.appendingPathComponent(".codex", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileName = "agent-\(Self.timestamp())-\(UUID().uuidString.lowercased()).jsonl"
        let url = directoryURL.appendingPathComponent(fileName)
        fileManager.createFile(atPath: url.path, contents: nil)
        self.url = url
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    func writeLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            AgentDiagnosticsLog.append(
                """
                Failed to write Codex JSONL transcript.
                path: \(url.path)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
        }
    }

    func close() {
        try? fileHandle.close()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}
