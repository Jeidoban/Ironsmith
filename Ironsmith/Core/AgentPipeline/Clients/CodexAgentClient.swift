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
            return trimmed.isEmpty ? nil : "Codex: \(AgentDiagnosticsLog.compact(trimmed, limit: 500))"
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
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        swiftCacheDirectoryCandidates: [URL] = defaultSwiftCacheDirectoryCandidates()
    ) -> Self {
        Self { request in
            var environment: [String: String] = [:]
            switch request.authentication {
            case .apiKey(let apiKey):
                environment["OPENAI_API_KEY"] = apiKey
            case .chatGPTLogin:
                _ = try await openAICodexAuthClient.validCredential()
            }

            let transcriptWriter = try CodexAgentTranscriptWriter(
                packageRootURL: request.packageRootURL
            )

            var arguments = [
                "exec",
                "--json",
                "--sandbox",
                "workspace-write",
                "--cd",
                request.packageRootURL.path,
                "--skip-git-repo-check",
            ]
            for directory in existingDirectories(swiftCacheDirectoryCandidates) {
                arguments.append(contentsOf: ["--add-dir", directory.path])
            }
            if let model = modelArgument(from: request.modelIdentifier) {
                arguments.append(contentsOf: ["--model", model])
            }
            arguments.append(prompt(for: request))

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

    nonisolated static func prompt(for request: CodexAgentRequest) -> String {
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
        - Use normal swift build when you need to check compilation.
        - Do not inspect or modify Swift cache directories except through normal build commands.
        - Keep working until ContentView.swift exists, is complete, and swift build succeeds.
        """
    }

    nonisolated static func defaultSwiftCacheDirectoryCandidates(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".swiftpm", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("org.swift.swiftpm", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("swift-package", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("swift-build", isDirectory: true),
            homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Developer", isDirectory: true)
                .appendingPathComponent("Xcode", isDirectory: true)
                .appendingPathComponent("DerivedData", isDirectory: true)
                .appendingPathComponent("ModuleCache.noindex", isDirectory: true),
        ]
    }

    nonisolated private static func existingDirectories(
        _ candidates: [URL]
    ) -> [URL] {
        candidates.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    nonisolated private static func modelArgument(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OpenAICodexBackend.rawCodexModelIdentifier(from: trimmed) ?? trimmed
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
            return "Codex changed \(path), but Ironsmith only allows Codex to edit ContentView.swift."
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
