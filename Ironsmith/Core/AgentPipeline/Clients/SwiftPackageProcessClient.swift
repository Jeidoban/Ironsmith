import AppKit
import Foundation

enum SwiftCompilerDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
    case note
}

struct SwiftCompilerDiagnostic: Codable, Equatable, Sendable {
    let relativePath: String?
    let line: Int
    let column: Int
    let severity: SwiftCompilerDiagnosticSeverity
    let message: String
    let supportingLines: [String]

    var renderedText: String {
        var lines = ["\(line):\(column): \(severity.rawValue): \(message)"]
        lines.append(contentsOf: supportingLines)
        return lines.joined(separator: "\n")
    }

    func matchesProblem(_ other: SwiftCompilerDiagnostic) -> Bool {
        severity == other.severity && message == other.message
    }
}

struct SwiftPackageBuildResult: Codable, Equatable, Sendable {
    let succeeded: Bool
    let stdout: String
    let stderr: String
    let terminationStatus: Int32

    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct SwiftPackageProcessClient: Sendable {
    var build: @Sendable (URL) async throws -> SwiftPackageBuildResult
    var buildRelease: @Sendable (URL) async throws -> SwiftPackageBuildResult
    var showBinPath: @Sendable (URL) async throws -> URL
    var showReleaseBinPath: @Sendable (URL) async throws -> URL
    var launch: @Sendable (URL) async throws -> Void
    var launchApp: @Sendable (URL) async throws -> Void
    var stripQuarantine: @Sendable (URL) async -> Void
    var formatSwiftSource: @Sendable (URL) async -> SwiftPackageBuildResult
    var signAdHoc: @Sendable (_ appBundleURL: URL, _ entitlementsURL: URL?) async throws -> SwiftPackageBuildResult
    var verifyCodeSignature: @Sendable (URL) async throws -> SwiftPackageBuildResult

    init(
        build: @escaping @Sendable (URL) async throws -> SwiftPackageBuildResult,
        buildRelease: (@Sendable (URL) async throws -> SwiftPackageBuildResult)? = nil,
        showBinPath: @escaping @Sendable (URL) async throws -> URL,
        showReleaseBinPath: (@Sendable (URL) async throws -> URL)? = nil,
        launch: @escaping @Sendable (URL) async throws -> Void,
        launchApp: (@Sendable (URL) async throws -> Void)? = nil,
        stripQuarantine: @escaping @Sendable (URL) async -> Void,
        formatSwiftSource: @escaping @Sendable (URL) async -> SwiftPackageBuildResult = { _ in
            SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        },
        signAdHoc: @escaping @Sendable (_ appBundleURL: URL, _ entitlementsURL: URL?) async throws -> SwiftPackageBuildResult = { _, _ in
            SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        },
        verifyCodeSignature: @escaping @Sendable (URL) async throws -> SwiftPackageBuildResult = { _ in
            SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }
    ) {
        self.build = build
        self.buildRelease = buildRelease ?? build
        self.showBinPath = showBinPath
        self.showReleaseBinPath = showReleaseBinPath ?? showBinPath
        self.launch = launch
        self.launchApp = launchApp ?? launch
        self.stripQuarantine = stripQuarantine
        self.formatSwiftSource = formatSwiftSource
        self.signAdHoc = signAdHoc
        self.verifyCodeSignature = verifyCodeSignature
    }

    nonisolated static let live = SwiftPackageProcessClient(
        build: { packageRootURL in
            let result = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
                arguments: ["build", "--package-path", packageRootURL.path],
                currentDirectoryURL: packageRootURL
            )
            return SwiftPackageBuildResult(
                succeeded: result.terminationStatus == 0,
                stdout: result.stdout,
                stderr: result.stderr,
                terminationStatus: result.terminationStatus
            )
        },
        buildRelease: { packageRootURL in
            let result = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
                arguments: ["build", "-c", "release", "--package-path", packageRootURL.path],
                currentDirectoryURL: packageRootURL
            )
            return SwiftPackageBuildResult(
                succeeded: result.terminationStatus == 0,
                stdout: result.stdout,
                stderr: result.stderr,
                terminationStatus: result.terminationStatus
            )
        },
        showBinPath: { packageRootURL in
            let result = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
                arguments: ["build", "--show-bin-path", "--package-path", packageRootURL.path],
                currentDirectoryURL: packageRootURL
            )

            guard result.terminationStatus == 0 else {
                throw SwiftPackageProcessError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }

            let path = result.stdout
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let path, !path.isEmpty else {
                throw SwiftPackageProcessError.missingBinPath
            }

            return URL(fileURLWithPath: path, isDirectory: true)
        },
        showReleaseBinPath: { packageRootURL in
            let result = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/swift"),
                arguments: ["build", "-c", "release", "--show-bin-path", "--package-path", packageRootURL.path],
                currentDirectoryURL: packageRootURL
            )

            guard result.terminationStatus == 0 else {
                throw SwiftPackageProcessError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }

            let path = result.stdout
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let path, !path.isEmpty else {
                throw SwiftPackageProcessError.missingBinPath
            }

            return URL(fileURLWithPath: path, isDirectory: true)
        },
        launch: { binaryURL in
            let process = Process()
            process.executableURL = binaryURL
            process.currentDirectoryURL = binaryURL.deletingLastPathComponent()
            try process.run()
        },
        launchApp: { appBundleURL in
            try await launchAppBundle(appBundleURL)
        },
        stripQuarantine: { binaryURL in
            _ = try? await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-d", "com.apple.quarantine", binaryURL.path],
                currentDirectoryURL: binaryURL.deletingLastPathComponent()
            )
        },
        formatSwiftSource: { sourceURL in
            do {
                let result = try await runProcess(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: [
                        "swift-format",
                        "format",
                        "--in-place",
                        "--no-color-diagnostics",
                        sourceURL.path
                    ],
                    currentDirectoryURL: sourceURL.deletingLastPathComponent()
                )
                return SwiftPackageBuildResult(
                    succeeded: result.terminationStatus == 0,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    terminationStatus: result.terminationStatus
                )
            } catch {
                return SwiftPackageBuildResult(
                    succeeded: false,
                    stdout: "",
                    stderr: error.localizedDescription,
                    terminationStatus: 1
                )
            }
        },
        signAdHoc: { appBundleURL, entitlementsURL in
            let result = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: Self.adHocCodeSignArguments(
                    appBundleURL: appBundleURL,
                    entitlementsURL: entitlementsURL
                ),
                currentDirectoryURL: appBundleURL.deletingLastPathComponent()
            )
            return SwiftPackageBuildResult(
                succeeded: result.terminationStatus == 0,
                stdout: result.stdout,
                stderr: result.stderr,
                terminationStatus: result.terminationStatus
            )
        },
        verifyCodeSignature: { appBundleURL in
            let result = try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", appBundleURL.path],
                currentDirectoryURL: appBundleURL.deletingLastPathComponent()
            )
            return SwiftPackageBuildResult(
                succeeded: result.terminationStatus == 0,
                stdout: result.stdout,
                stderr: result.stderr,
                terminationStatus: result.terminationStatus
            )
        }
    )

    static func adHocCodeSignArguments(appBundleURL: URL, entitlementsURL: URL?) -> [String] {
        var arguments = ["--force", "--sign", "-", "--options", "runtime"]
        if let entitlementsURL {
            arguments.append(contentsOf: ["--entitlements", entitlementsURL.path])
        }
        arguments.append(appBundleURL.path)
        return arguments
    }

    static func firstActionableSwiftFile(in output: String, packageRootURL: URL) -> String? {
        let escapedRoot = NSRegularExpression.escapedPattern(for: packageRootURL.standardizedFileURL.path)
        let absolutePattern = "\(escapedRoot)/([^:\\n]+\\.swift):\\d+:\\d+:"
        if let relative = firstCapture(in: output, pattern: absolutePattern) {
            return relative
        }

        return firstCapture(in: output, pattern: "((?:Sources|Tests)/[^:\\n]+\\.swift):\\d+:\\d+:")
    }

    static func compilerExcerpt(from output: String, limit: Int = 3_500) -> String {
        guard output.count > limit else { return output }
        return String(output.prefix(limit))
    }

    static func diagnostics(
        for relativePath: String,
        in output: String,
        packageRootURL: URL
    ) -> String {
        let rendered = parseDiagnostics(in: output, packageRootURL: packageRootURL)
            .filter { $0.relativePath == relativePath }
            .map(\.renderedText)

        guard !rendered.isEmpty else {
            return compilerExcerpt(from: output)
        }

        return rendered.joined(separator: "\n\n")
    }

    static func parseDiagnostics(
        in output: String,
        packageRootURL: URL
    ) -> [SwiftCompilerDiagnostic] {
        let packageRootPath = packageRootURL.standardizedFileURL.path
        let lines = output.components(separatedBy: .newlines)
        var diagnostics: [SwiftCompilerDiagnostic] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard let header = diagnosticHeader(from: line, packageRootPath: packageRootPath) else {
                index += 1
                continue
            }

            index += 1
            var supportingLines: [String] = []
            while index < lines.count {
                let continuation = lines[index]
                if diagnosticHeader(from: continuation, packageRootPath: packageRootPath) != nil || isBuildProgressLine(continuation) {
                    break
                }
                if continuation.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[#") {
                    break
                }
                if !continuation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    supportingLines.append(continuation)
                }
                index += 1
            }

            diagnostics.append(
                SwiftCompilerDiagnostic(
                    relativePath: header.relativePath,
                    line: header.line,
                    column: header.column,
                    severity: header.severity,
                    message: header.message,
                    supportingLines: supportingLines
                )
            )
        }

        return diagnostics
    }

    private static func firstCapture(in output: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let captureRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[captureRange])
    }

    private static func isSwiftDiagnosticHeader(_ line: String) -> Bool {
        diagnosticHeader(from: line, packageRootPath: nil) != nil
    }

    private static func isBuildProgressLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") || trimmed.hasPrefix("Build ") || trimmed.hasPrefix("Compile ")
    }

    private static func diagnosticHeader(
        from line: String,
        packageRootPath: String?
    ) -> (relativePath: String?, line: Int, column: Int, severity: SwiftCompilerDiagnosticSeverity, message: String)? {
        let pattern = #"(.+\.swift):(\d+):(\d+):\s+(error|warning|note):\s+(.+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges == 6 else {
            return nil
        }

        guard
            let pathRange = Range(match.range(at: 1), in: line),
            let lineRange = Range(match.range(at: 2), in: line),
            let columnRange = Range(match.range(at: 3), in: line),
            let severityRange = Range(match.range(at: 4), in: line),
            let messageRange = Range(match.range(at: 5), in: line),
            let lineNumber = Int(line[lineRange]),
            let columnNumber = Int(line[columnRange]),
            let severity = SwiftCompilerDiagnosticSeverity(rawValue: String(line[severityRange]))
        else {
            return nil
        }

        let absolutePath = String(line[pathRange])
        let relativePath: String?
        if let packageRootPath, absolutePath.hasPrefix(packageRootPath + "/") {
            relativePath = String(absolutePath.dropFirst(packageRootPath.count + 1))
        } else if absolutePath.hasPrefix("Sources/") || absolutePath.hasPrefix("Tests/") {
            relativePath = absolutePath
        } else {
            relativePath = nil
        }

        return (
            relativePath: relativePath,
            line: lineNumber,
            column: columnNumber,
            severity: severity,
            message: String(line[messageRange])
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> ProcessRunResult {
        let processReference = ProcessReference()
        return try await withTaskCancellationHandler {
            let processTask = Task.detached(priority: .utility) {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectoryURL
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                guard !processReference.set(process) else {
                    throw CancellationError()
                }
                defer { processReference.clear(process) }

                try process.run()
                let outputTask = Task.detached {
                    outputPipe.fileHandleForReading.readDataToEndOfFile()
                }
                let errorTask = Task.detached {
                    errorPipe.fileHandleForReading.readDataToEndOfFile()
                }

                process.waitUntilExit()

                let outputData = await outputTask.value
                let errorData = await errorTask.value
                return ProcessRunResult(
                    terminationStatus: process.terminationStatus,
                    stdout: String(data: outputData, encoding: .utf8) ?? "",
                    stderr: String(data: errorData, encoding: .utf8) ?? ""
                )
            }

            let result = try await processTask.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            processReference.terminate()
        }
    }

    private static func launchAppBundle(_ appBundleURL: URL) async throws {
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    try await terminateRunningApplications(for: appBundleURL)

                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = false
                    NSWorkspace.shared.openApplication(
                        at: appBundleURL,
                        configuration: configuration
                    ) { app, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }

                        _ = app?.activate(options: [.activateAllWindows])
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private static func terminateRunningApplications(for appBundleURL: URL) async throws {
        guard let bundleIdentifier = Bundle(url: appBundleURL)?.bundleIdentifier else {
            return
        }

        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard !runningApplications.isEmpty else {
            return
        }

        for application in runningApplications where !application.isTerminated {
            application.terminate()
        }
        if await waitForTermination(of: runningApplications, attempts: 40) {
            return
        }

        for application in runningApplications where !application.isTerminated {
            application.forceTerminate()
        }
        _ = await waitForTermination(of: runningApplications, attempts: 20)
    }

    @MainActor
    private static func waitForTermination(
        of applications: [NSRunningApplication],
        attempts: Int
    ) async -> Bool {
        for _ in 0..<attempts {
            if applications.allSatisfy(\.isTerminated) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return applications.allSatisfy(\.isTerminated)
    }
}

private final class ProcessReference: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var shouldTerminate = false

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

private struct ProcessRunResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

enum SwiftPackageProcessError: LocalizedError, Equatable {
    case commandFailed(String)
    case missingBinPath

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            return output.isEmpty ? "The Swift package command failed." : output
        case .missingBinPath:
            return "SwiftPM did not report a binary output path."
        }
    }
}
