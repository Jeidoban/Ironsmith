import Foundation

nonisolated struct CodexCLIProcessRequest: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectoryURL: URL
}

nonisolated struct CodexCLIProcessResult: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var terminationStatus: Int32

    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

nonisolated struct CodexCLIClient: Sendable {
    var run: @Sendable (_ arguments: [String]) async throws -> CodexCLIProcessResult
    var runStreaming: @Sendable (
        _ arguments: [String],
        _ environmentOverrides: [String: String],
        _ onStdoutLine: @escaping @Sendable (String) async -> Void,
        _ onStderrLine: @escaping @Sendable (String) async -> Void
    ) async throws -> CodexCLIProcessResult
    var runStreamingToFile: @Sendable (
        _ arguments: [String],
        _ environmentOverrides: [String: String],
        _ stdoutURL: URL,
        _ onStdoutLine: @escaping @Sendable (String) async -> Void,
        _ onStderrLine: @escaping @Sendable (String) async -> Void
    ) async throws -> CodexCLIProcessResult

    init(
        run: @escaping @Sendable (_ arguments: [String]) async throws -> CodexCLIProcessResult
    ) {
        self.run = run
        self.runStreaming = { arguments, _, _, _ in
            try await run(arguments)
        }
        self.runStreamingToFile = { arguments, _, _, _, _ in
            try await run(arguments)
        }
    }

    init(
        run: @escaping @Sendable (_ arguments: [String]) async throws -> CodexCLIProcessResult,
        runStreaming: @escaping @Sendable (
            _ arguments: [String],
            _ environmentOverrides: [String: String],
            _ onStdoutLine: @escaping @Sendable (String) async -> Void,
            _ onStderrLine: @escaping @Sendable (String) async -> Void
        ) async throws -> CodexCLIProcessResult,
        runStreamingToFile: (@Sendable (
            _ arguments: [String],
            _ environmentOverrides: [String: String],
            _ stdoutURL: URL,
            _ onStdoutLine: @escaping @Sendable (String) async -> Void,
            _ onStderrLine: @escaping @Sendable (String) async -> Void
        ) async throws -> CodexCLIProcessResult)? = nil
    ) {
        self.run = run
        self.runStreaming = runStreaming
        self.runStreamingToFile = runStreamingToFile ?? { arguments, environmentOverrides, stdoutURL, onStdoutLine, onStderrLine in
            let writer = try CodexCLIOutputFileWriter(url: stdoutURL)
            do {
                let result = try await runStreaming(
                    arguments,
                    environmentOverrides,
                    { line in
                        await writer.writeLine(line)
                        await onStdoutLine(line)
                    },
                    onStderrLine
                )
                await writer.close()
                return result
            } catch {
                await writer.close()
                throw error
            }
        }
    }
}

extension CodexCLIClient {
    nonisolated static func live(
        codexHomeDirectory: URL = IronsmithPaths.codexHomeDirectory,
        executableURL: URL? = nil,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runProcess: @escaping @Sendable (CodexCLIProcessRequest) async throws -> CodexCLIProcessResult = { request in
            try await Self.runProcess(request)
        }
    ) -> Self {
        Self(
            run: { arguments in
                let request = try makeRequest(
                    arguments: arguments,
                    codexHomeDirectory: codexHomeDirectory,
                    executableURL: executableURL,
                    bundleResourceURL: bundleResourceURL,
                    environment: environment
                )
                return try await runProcess(request)
            },
            runStreaming: { arguments, environmentOverrides, onStdoutLine, onStderrLine in
                let request = try makeRequest(
                    arguments: arguments,
                    codexHomeDirectory: codexHomeDirectory,
                    executableURL: executableURL,
                    bundleResourceURL: bundleResourceURL,
                    environment: environment.merging(environmentOverrides) { _, override in override }
                )
                return try await runProcessStreaming(
                    request,
                    onStdoutLine: onStdoutLine,
                    onStderrLine: onStderrLine
                )
            },
            runStreamingToFile: { arguments, environmentOverrides, stdoutURL, onStdoutLine, onStderrLine in
                let request = try makeRequest(
                    arguments: arguments,
                    codexHomeDirectory: codexHomeDirectory,
                    executableURL: executableURL,
                    bundleResourceURL: bundleResourceURL,
                    environment: environment.merging(environmentOverrides) { _, override in override }
                )
                return try await runProcessStreamingToFile(
                    request,
                    stdoutURL: stdoutURL,
                    onStdoutLine: onStdoutLine,
                    onStderrLine: onStderrLine
                )
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(
            run: { _ in
                throw OpenAICodexAuthClientError.missingCodexBinary("Codex CLI is not configured.")
            },
            runStreaming: { _, _, _, _ in
                throw OpenAICodexAuthClientError.missingCodexBinary("Codex CLI is not configured.")
            },
            runStreamingToFile: { _, _, _, _, _ in
                throw OpenAICodexAuthClientError.missingCodexBinary("Codex CLI is not configured.")
            }
        )
    }

    nonisolated static func makeRequest(
        arguments: [String],
        codexHomeDirectory: URL,
        executableURL: URL?,
        bundleResourceURL: URL?,
        environment: [String: String]
    ) throws -> CodexCLIProcessRequest {
        try FileManager.default.createDirectory(
            at: codexHomeDirectory,
            withIntermediateDirectories: true
        )

        let resolvedExecutableURL = try executableURL ?? bundledExecutableURL(resourceURL: bundleResourceURL)
        var resolvedEnvironment = environment
        resolvedEnvironment["CODEX_HOME"] = codexHomeDirectory.path

        return CodexCLIProcessRequest(
            executableURL: resolvedExecutableURL,
            arguments: arguments,
            environment: resolvedEnvironment,
            currentDirectoryURL: codexHomeDirectory
        )
    }

    nonisolated static func bundledExecutableURL(resourceURL: URL? = Bundle.main.resourceURL) throws -> URL {
        guard let resourceURL else {
            throw OpenAICodexAuthClientError.missingCodexBinary("Could not locate app resources.")
        }

        let vendorURL = resourceURL
            .appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent("vendor", isDirectory: true)

        let candidates = [
            vendorURL.appendingPathComponent("codex"),
            vendorURL
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex"),
        ]
        guard let executableURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw OpenAICodexAuthClientError.missingCodexBinary("Missing Codex binary in \(vendorURL.path).")
        }
        return executableURL
    }

    nonisolated static func bundledVersion(resourceURL: URL? = Bundle.main.resourceURL) -> String? {
        guard let resourceURL else { return nil }
        let versionURL = resourceURL
            .appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent("version.txt")
        guard let version = try? String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty
        else {
            return nil
        }
        return version
    }

    nonisolated private static func runProcess(_ request: CodexCLIProcessRequest) async throws -> CodexCLIProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = request.executableURL
            process.arguments = request.arguments
            process.environment = request.environment
            process.currentDirectoryURL = request.currentDirectoryURL

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: CodexCLIProcessResult(
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? "",
                        terminationStatus: process.terminationStatus
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func runProcessStreaming(
        _ request: CodexCLIProcessRequest,
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void
    ) async throws -> CodexCLIProcessResult {
        let processReference = CodexCLIProcessReference()
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()

                process.executableURL = request.executableURL
                process.arguments = request.arguments
                process.environment = request.environment
                process.currentDirectoryURL = request.currentDirectoryURL
                process.standardOutput = stdout
                process.standardError = stderr

                guard !processReference.set(process) else {
                    throw CancellationError()
                }
                defer { processReference.clear(process) }

                try process.run()
                async let stdoutText = readLines(
                    from: stdout.fileHandleForReading,
                    onLine: onStdoutLine
                )
                async let stderrText = readLines(
                    from: stderr.fileHandleForReading,
                    onLine: onStderrLine
                )

                process.waitUntilExit()

                return CodexCLIProcessResult(
                    stdout: try await stdoutText,
                    stderr: try await stderrText,
                    terminationStatus: process.terminationStatus
                )
            }

            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            processReference.terminate()
        }
    }

    nonisolated private static func runProcessStreamingToFile(
        _ request: CodexCLIProcessRequest,
        stdoutURL: URL,
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void
    ) async throws -> CodexCLIProcessResult {
        let processReference = CodexCLIProcessReference()
        let tailCompletion = CodexCLIFileTailCompletion()
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                try prepareOutputFile(at: stdoutURL)

                let process = Process()
                let stdout = try FileHandle(forWritingTo: stdoutURL)
                let stderr = Pipe()

                process.executableURL = request.executableURL
                process.arguments = request.arguments
                process.environment = request.environment
                process.currentDirectoryURL = request.currentDirectoryURL
                process.standardOutput = stdout
                process.standardError = stderr

                guard !processReference.set(process) else {
                    throw CancellationError()
                }
                defer { processReference.clear(process) }

                let stdoutTask = Task.detached(priority: .utility) {
                    try await tailLines(
                        from: stdoutURL,
                        completion: tailCompletion,
                        onLine: onStdoutLine
                    )
                }

                do {
                    try process.run()
                } catch {
                    try? stdout.close()
                    tailCompletion.finish()
                    _ = try? await stdoutTask.value
                    throw error
                }

                async let stderrText = readLines(
                    from: stderr.fileHandleForReading,
                    onLine: onStderrLine
                )

                process.waitUntilExit()
                try? stdout.close()
                tailCompletion.finish()

                return CodexCLIProcessResult(
                    stdout: try await stdoutTask.value,
                    stderr: try await stderrText,
                    terminationStatus: process.terminationStatus
                )
            }

            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            processReference.terminate()
            tailCompletion.finish()
        }
    }

    nonisolated fileprivate static func prepareOutputFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
    }

    nonisolated private static func readLines(
        from handle: FileHandle,
        onLine: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        var allData = Data()
        var lineData = Data()
        for try await byte in handle.bytes {
            allData.append(byte)
            if byte == 10 {
                let line = String(data: lineData, encoding: .utf8) ?? ""
                await onLine(line.trimmingTrailingCarriageReturn())
                lineData.removeAll(keepingCapacity: true)
            } else {
                lineData.append(byte)
            }
        }
        if !lineData.isEmpty {
            let line = String(data: lineData, encoding: .utf8) ?? ""
            await onLine(line.trimmingTrailingCarriageReturn())
        }
        return String(data: allData, encoding: .utf8) ?? ""
    }

    nonisolated private static func tailLines(
        from url: URL,
        completion: CodexCLIFileTailCompletion,
        onLine: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var allData = Data()
        var lineData = Data()

        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty {
                if completion.isFinished {
                    if !lineData.isEmpty {
                        let line = String(data: lineData, encoding: .utf8) ?? ""
                        await onLine(line.trimmingTrailingCarriageReturn())
                    }
                    return String(data: allData, encoding: .utf8) ?? ""
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            for byte in data {
                allData.append(byte)
                if byte == 10 {
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    await onLine(line.trimmingTrailingCarriageReturn())
                    lineData.removeAll(keepingCapacity: true)
                } else {
                    lineData.append(byte)
                }
            }
        }
    }
}

private actor CodexCLIOutputFileWriter {
    private let fileHandle: FileHandle

    init(url: URL) throws {
        try CodexCLIClient.prepareOutputFile(at: url)
        self.fileHandle = try FileHandle(forWritingTo: url)
    }

    func writeLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        try? fileHandle.write(contentsOf: data)
    }

    func close() {
        try? fileHandle.close()
    }
}

private final class CodexCLIFileTailCompletion: @unchecked Sendable {
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

private final class CodexCLIProcessReference: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var shouldTerminate = false

    nonisolated init() {}

    nonisolated func set(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let shouldTerminate = shouldTerminate
        lock.unlock()
        return shouldTerminate
    }

    nonisolated func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    nonisolated func terminate() {
        lock.lock()
        shouldTerminate = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }
}

private extension String {
    nonisolated func trimmingTrailingCarriageReturn() -> String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}
