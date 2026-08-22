import Foundation
import Darwin

nonisolated struct CustomCodingAgentRequest: Sendable {
    let agent: CustomCodingAgent
    let packageRootURL: URL
    let prompt: String
    let onOutput: @Sendable (CustomCodingAgentOutput) async -> Void

    init(
        agent: CustomCodingAgent,
        packageRootURL: URL,
        prompt: String,
        onOutput: @escaping @Sendable (CustomCodingAgentOutput) async -> Void = { _ in }
    ) {
        self.agent = agent
        self.packageRootURL = packageRootURL
        self.prompt = prompt
        self.onOutput = onOutput
    }
}

nonisolated struct CustomCodingAgentOutput: Codable, Equatable, Sendable {
    enum Stream: String, Codable, Sendable {
        case stdout
        case stderr
    }

    let timestamp: Date
    let runner: String
    let stream: Stream
    let text: String
}

nonisolated struct CustomCodingAgentResult: Equatable, Sendable {
    let terminationStatus: Int32
    let transcriptURL: URL
}

nonisolated enum CustomCodingAgentTestError: LocalizedError, Equatable {
    case commandFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status):
            "The coding agent test exited with status \(status)."
        }
    }
}

nonisolated struct CustomCodingAgentTestClient: Sendable {
    static let prompt = "This is a test, respond only with 'Test successful!'"

    var run: @Sendable (
        _ agent: CustomCodingAgent,
        _ onOutput: @escaping @Sendable (CustomCodingAgentOutput) async -> Void
    ) async throws -> Void

    static func live(
        agentClient: CustomCodingAgentClient = .live,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Self {
        Self { agent, onOutput in
            let packageRootURL = temporaryDirectory.appendingPathComponent(
                "ironsmith-custom-agent-test-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: packageRootURL,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: packageRootURL) }

            do {
                _ = try await agentClient.run(
                    CustomCodingAgentRequest(
                        agent: agent,
                        packageRootURL: packageRootURL,
                        prompt: prompt,
                        onOutput: onOutput
                    )
                )
            } catch CustomCodingAgentError.commandFailed(let status, _) {
                throw CustomCodingAgentTestError.commandFailed(status: status)
            }
        }
    }
}

enum CustomCodingAgentError: LocalizedError {
    case commandFailed(status: Int32, transcriptURL: URL)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let transcriptURL):
            "The custom coding agent exited with status \(status). Transcript: \(transcriptURL.path)"
        }
    }
}

nonisolated struct CustomCodingAgentClient: Sendable {
    var run: @Sendable (CustomCodingAgentRequest) async throws -> CustomCodingAgentResult

    nonisolated static let live = Self { request in
        let transcript = try CustomCodingAgentTranscriptFile(
            packageRootURL: request.packageRootURL,
            agentName: request.agent.name
        )
        let writer = try CustomCodingAgentTranscriptWriter(url: transcript.url)
        let processReference = CustomCodingAgentProcessReference()

        let result = try await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                let process = Process()
                let stdoutURL = transcript.url.appendingPathExtension("stdout")
                let stderrURL = transcript.url.appendingPathExtension("stderr")
                try Data().write(to: stdoutURL, options: .atomic)
                try Data().write(to: stderrURL, options: .atomic)
                let stdout = try FileHandle(forWritingTo: stdoutURL)
                let stderr = try FileHandle(forWritingTo: stderrURL)
                let tailCompletion = CustomCodingAgentTailCompletion()
                defer {
                    try? stdout.close()
                    try? stderr.close()
                    tailCompletion.finish()
                    try? FileManager.default.removeItem(at: stdoutURL)
                    try? FileManager.default.removeItem(at: stderrURL)
                }
                let stdin = request.agent.promptDelivery == .standardInput ? Pipe() : nil

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = shellArguments(for: request)
                process.environment = ProcessInfo.processInfo.environment
                process.currentDirectoryURL = request.packageRootURL
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = stdin

                guard !processReference.set(process) else {
                    throw CancellationError()
                }
                defer { processReference.clear(process) }

                try process.run()
                processReference.didLaunch(process)

                let stdoutTask = Task.detached(priority: .utility) {
                    try await tailLines(
                        from: stdoutURL,
                        completion: tailCompletion
                    ) { line in
                        let output = CustomCodingAgentOutput(
                            timestamp: .now,
                            runner: request.agent.name,
                            stream: .stdout,
                            text: line
                        )
                        await writer.append(output)
                        await request.onOutput(output)
                    }
                }

                let stderrTask = Task.detached(priority: .utility) {
                    try await tailLines(
                        from: stderrURL,
                        completion: tailCompletion
                    ) { line in
                        let output = CustomCodingAgentOutput(
                            timestamp: .now,
                            runner: request.agent.name,
                            stream: .stderr,
                            text: line
                        )
                        await writer.append(output)
                        await request.onOutput(output)
                    }
                }
                let stdinTask = Task.detached(priority: .utility) {
                    try writeStandardInput(
                        request.prompt,
                        to: stdin?.fileHandleForWriting
                    )
                }

                try await stdinTask.value
                process.waitUntilExit()
                try? stdout.close()
                try? stderr.close()
                tailCompletion.finish()
                _ = try await (stdoutTask.value, stderrTask.value)
                await writer.close()
                return process.terminationStatus
            }
            let status = try await task.value
            try Task.checkCancellation()
            return status
        } onCancel: {
            processReference.terminate()
        }

        guard result == 0 else {
            throw CustomCodingAgentError.commandFailed(
                status: result,
                transcriptURL: transcript.url
            )
        }
        return CustomCodingAgentResult(
            terminationStatus: result,
            transcriptURL: transcript.url
        )
    }

    nonisolated static let unconfigured = Self { _ in
        throw CocoaError(.executableNotLoadable)
    }

    nonisolated static func shellArguments(for request: CustomCodingAgentRequest) -> [String] {
        switch request.agent.promptDelivery {
        case .placeholder:
            let command = request.agent.command.replacingOccurrences(
                of: "{{prompt}}",
                with: #""$1""#
            )
            return ["-lc", command, request.agent.name, request.prompt]
        case .standardInput:
            return ["-lc", request.agent.command]
        }
    }

    nonisolated private static func writeStandardInput(
        _ prompt: String,
        to handle: FileHandle?
    ) throws {
        guard let handle else { return }
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(prompt.utf8))
    }

    nonisolated private static func tailLines(
        from url: URL,
        completion: CustomCodingAgentTailCompletion,
        onLine: @escaping @Sendable (String) async -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineData = Data()

        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                if completion.isFinished {
                    if !lineData.isEmpty {
                        await onLine(String(decoding: lineData, as: UTF8.self))
                    }
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            for byte in data {
                if byte == 10 {
                    let line = String(decoding: lineData, as: UTF8.self)
                    await onLine(line.hasSuffix("\r") ? String(line.dropLast()) : line)
                    lineData.removeAll(keepingCapacity: true)
                } else {
                    lineData.append(byte)
                }
            }
        }
    }
}

private final class CustomCodingAgentTailCompletion: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var finished = false

    nonisolated init() {}

    nonisolated func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    nonisolated var isFinished: Bool {
        lock.lock()
        let value = finished
        lock.unlock()
        return value
    }
}

private final class CustomCodingAgentProcessReference: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var processGroupID: pid_t?
    nonisolated(unsafe) private var shouldTerminate = false

    nonisolated init() {}

    nonisolated func set(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let shouldTerminate = shouldTerminate
        lock.unlock()
        return shouldTerminate
    }

    nonisolated func didLaunch(_ process: Process) {
        let pid = process.processIdentifier
        let groupWasCreated = pid > 0 && setpgid(pid, pid) == 0
        lock.lock()
        if self.process === process, groupWasCreated {
            processGroupID = pid
        }
        let shouldTerminate = shouldTerminate
        lock.unlock()
        if shouldTerminate {
            terminateRunningProcess(process, groupID: groupWasCreated ? pid : nil)
        }
    }

    nonisolated func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            processGroupID = nil
        }
        lock.unlock()
    }

    nonisolated func terminate() {
        lock.lock()
        shouldTerminate = true
        let process = process
        let groupID = processGroupID
        lock.unlock()
        guard let process else { return }
        terminateRunningProcess(process, groupID: groupID)
    }

    nonisolated private func terminateRunningProcess(_ process: Process, groupID: pid_t?) {
        let pid = process.processIdentifier
        if let groupID {
            _ = Darwin.kill(-groupID, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            if let groupID {
                _ = Darwin.kill(-groupID, SIGKILL)
            } else {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }
}

nonisolated enum CustomCodingAgentPrompt {
    static func compose(
        userPrompt: String,
        displayName: String,
        executableName: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool,
        attachments: [ToolPersistedPromptAttachment]
    ) -> String {
        let attachmentContext = attachments.isEmpty ? "" : """

            User-provided attachments:
            \(attachments.map { "- \($0.fileName): \($0.url.path)" }.joined(separator: "\n"))

            Treat these files strictly as read-only context. Do not modify them, copy binary data into the app, or reference their temporary paths from generated code.
            """
        return """
            You are a coding agent running inside Ironsmith.
            Build the requested macOS SwiftUI app by editing this generated Swift package.

            User request:
            \(userPrompt)
            \(attachmentContext)

            App name: \(displayName)
            Fixed target and executable name: \(executableName)
            \(ToolGenerationPrompts.appPresentationContext(appKind: appKind))
            \(ToolGenerationPrompts.sandboxContext(sandboxEnabled: sandboxEnabled))

            Rules:
            - Create or edit only Sources/\(executableName)/ContentView.swift.
            - Do not modify Package.swift or Sources/\(executableName)/\(executableName).swift.
            - Do not add other source files or package dependencies.
            - Do not add previews, @main declarations, or App-conforming helper types.
            - Keep working until ContentView.swift is complete and `swift build --disable-sandbox` succeeds.
            - Define ContentView as the root View. Helper types may live in the same file.
            - This is a macOS SwiftUI app. Do not use iOS-only modifiers.
            - Keep the app local-only; do not add a backend, accounts, analytics, subscriptions, push notifications, or cloud sync.
            - Make the app feel native to macOS and prefer Apple frameworks over custom or third-party solutions.
            - Use // MARK: - to separate sections of code.
            """
    }
}

nonisolated enum CustomCodingAgentTranscriptReader {
    static func directoryURL(for packageRootURL: URL) -> URL {
        ToolPackageLayout.customAgentTranscriptsDirectoryURL(for: packageRootURL)
    }

    static func latestTranscriptURL(
        for packageRootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let directoryURL = directoryURL(for: packageRootURL)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lhs > rhs
            }
            .first
    }

    static func hasTranscript(for packageRootURL: URL) -> Bool {
        latestTranscriptURL(for: packageRootURL) != nil
    }

    static func entries(for packageRootURL: URL) throws -> [CustomCodingAgentOutput] {
        guard let url = latestTranscriptURL(for: packageRootURL) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.split(separator: "\n").compactMap { line in
            try? decoder.decode(CustomCodingAgentOutput.self, from: Data(line.utf8))
        }
    }

    static func displayEntries(for packageRootURL: URL) throws -> [CustomCodingAgentOutput] {
        displayEntries(from: try entries(for: packageRootURL))
    }

    static func displayEntries(
        from entries: [CustomCodingAgentOutput]
    ) -> [CustomCodingAgentOutput] {
        entries.flatMap { entry -> [CustomCodingAgentOutput] in
            guard entry.stream == .stdout,
                  let event = try? JSONDecoder().decode(
                      ClaudeStreamEvent.self,
                      from: Data(entry.text.utf8)
                  ),
                  event.isClaudeStreamEvent
            else {
                return [entry]
            }

            guard event.type == "assistant" else { return [] }
            return event.message?.content.compactMap { block in
                let displayText: String? = switch block.type {
                case "text": block.text
                case "thinking": block.thinking
                default: nil
                }
                guard let text = displayText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { return nil }
                return CustomCodingAgentOutput(
                    timestamp: entry.timestamp,
                    runner: entry.runner,
                    stream: entry.stream,
                    text: text
                )
            } ?? []
        }
    }
}

private nonisolated struct ClaudeStreamEvent: Decodable {
    struct Message: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let thinking: String?
        }

        let role: String
        let content: [Content]
    }

    let type: String
    let subtype: String?
    let sessionID: String?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case sessionID = "session_id"
        case message
    }

    var isClaudeStreamEvent: Bool {
        switch type {
        case "assistant":
            message?.role == "assistant"
        case "system", "user", "result":
            sessionID != nil
        default:
            false
        }
    }
}

private nonisolated struct CustomCodingAgentTranscriptFile: Sendable {
    let url: URL

    init(packageRootURL: URL, agentName: String) throws {
        let directoryURL = CustomCodingAgentTranscriptReader.directoryURL(for: packageRootURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        url = directoryURL.appendingPathComponent(
            "\(ToolNameSanitizer.slug(from: agentName))-\(timestamp)-\(UUID().uuidString.lowercased()).jsonl"
        )
        try Data().write(to: url, options: .atomic)
    }
}

private actor CustomCodingAgentTranscriptWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func append(_ output: CustomCodingAgentOutput) {
        guard var data = try? encoder.encode(output) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}
