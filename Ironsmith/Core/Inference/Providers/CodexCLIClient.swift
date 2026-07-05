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
    var signIn: @Sendable () async throws -> Void
    var signOut: @Sendable () async throws -> Void
    var loginStatus: @Sendable () async throws -> CodexCLIProcessResult
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
            signIn: {
                let request = try makeRequest(
                    command: ["login"],
                    codexHomeDirectory: codexHomeDirectory,
                    executableURL: executableURL,
                    bundleResourceURL: bundleResourceURL,
                    environment: environment
                )
                let result = try await runProcess(request)
                try validate(result)
            },
            signOut: {
                let request = try makeRequest(
                    command: ["logout"],
                    codexHomeDirectory: codexHomeDirectory,
                    executableURL: executableURL,
                    bundleResourceURL: bundleResourceURL,
                    environment: environment
                )
                let result = try await runProcess(request)
                try validate(result)
            },
            loginStatus: {
                let request = try makeRequest(
                    command: ["login", "status"],
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
            signIn: { throw OpenAICodexAuthClientError.missingCodexBinary("Codex CLI is not configured.") },
            signOut: {},
            loginStatus: {
                throw OpenAICodexAuthClientError.missingCodexBinary("Codex CLI is not configured.")
            }
        )
    }

    nonisolated static func makeRequest(
        command: [String],
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
            arguments: command,
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
            .appendingPathComponent(currentTargetTriple, isDirectory: true)

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

    nonisolated private static var currentTargetTriple: String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #elseif arch(x86_64)
        return "x86_64-apple-darwin"
        #else
        return "unsupported-apple-darwin"
        #endif
    }

    nonisolated private static func validate(_ result: CodexCLIProcessResult) throws {
        guard result.terminationStatus == 0 else {
            throw OpenAICodexAuthClientError.codexCommandFailed(sanitizedOutput(result.combinedOutput))
        }
    }

    nonisolated private static func sanitizedOutput(_ output: String) -> String {
        var sanitized = output
        for key in ["OPENAI_API_KEY", "access_token", "refresh_token", "id_token"] {
            sanitized = sanitized.replacingOccurrences(
                of: #""\#(key)"\s*:\s*"[^"]+""#,
                with: #""\#(key)": "[redacted]""#,
                options: .regularExpression
            )
        }
        sanitized = sanitized.replacingOccurrences(
            of: #"Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            with: "[jwt-redacted]",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"rt\.[A-Za-z0-9._-]+"#,
            with: "rt.[redacted]",
            options: .regularExpression
        )
        return sanitized
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
