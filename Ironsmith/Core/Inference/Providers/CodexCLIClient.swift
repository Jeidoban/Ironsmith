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
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(
            run: { _ in
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
}
