import Foundation

nonisolated struct CommandLineToolsSelection: Equatable, Sendable {
    let developerDirectory: String
    let swiftVersion: CommandLineToolsVersion
    let sdkVersion: CommandLineToolsVersion

    var usesXcode: Bool {
        developerDirectory.contains(".app/Contents/Developer")
    }
}

nonisolated enum CommandLineToolsAvailability: Equatable, Sendable {
    case available(CommandLineToolsSelection)
    case unavailable
    case unsupported(CommandLineToolsSelection)
}

nonisolated struct CommandLineToolsVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int

    var displayName: String { "\(major).\(minor)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    static func parseSwiftVersion(from output: String) -> Self? {
        parse(from: output, pattern: #"Swift version (\d+)\.(\d+)"#)
    }

    static func parseSDKVersion(from output: String) -> Self? {
        parse(from: output, pattern: #"^\s*(\d+)\.(\d+)"#)
    }

    private static func parse(from output: String, pattern: String) -> Self? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
            let majorRange = Range(match.range(at: 1), in: output),
            let minorRange = Range(match.range(at: 2), in: output),
            let major = Int(output[majorRange]),
            let minor = Int(output[minorRange])
        else {
            return nil
        }
        return Self(major: major, minor: minor)
    }
}

nonisolated struct CommandLineToolsClient: Sendable {
    var detectAvailability: @Sendable () async -> CommandLineToolsAvailability
    var requestInstallation: @Sendable () async -> Void = {}
}

extension CommandLineToolsClient {
    nonisolated static let manualInstallCommand = "xcode-select --install"

    nonisolated static func live(processInfo: ProcessInfo = .processInfo) -> Self {
        live(environment: processInfo.environment)
    }

    nonisolated static func live(environment: [String: String]) -> Self {
        if let availabilityOverride = environment["IRONSMITH_TEST_SWIFTC_AVAILABLE"] {
            let availability: CommandLineToolsAvailability
            if availabilityOverride == "1" {
                availability = .available(
                    CommandLineToolsSelection(
                        developerDirectory: "/Library/Developer/CommandLineTools",
                        swiftVersion: .init(major: 6, minor: 2),
                        sdkVersion: .init(major: 26, minor: 0)
                    )
                )
            } else {
                availability = .unavailable
            }
            return fixed(availability: availability)
        }

        return Self(
            detectAvailability: {
                await Task.detached(priority: .utility) {
                    detectSynchronously()
                }.value
            },
            requestInstallation: {
                await Task.detached(priority: .utility) {
                    _ = run("/usr/bin/xcode-select", ["--install"])
                }.value
            }
        )
    }

    nonisolated static func fixed(
        availability: CommandLineToolsAvailability,
        requestInstallation: @escaping @Sendable () async -> Void = {}
    ) -> Self {
        Self(
            detectAvailability: { availability },
            requestInstallation: requestInstallation
        )
    }

    nonisolated static func isSupported(
        swiftVersion: CommandLineToolsVersion,
        sdkVersion: CommandLineToolsVersion
    ) -> Bool {
        swiftVersion
            >= CommandLineToolsVersion(
                major: GeneratedToolRequirements.swiftMajorVersion,
                minor: GeneratedToolRequirements.swiftMinorVersion
            )
            && sdkVersion
                >= CommandLineToolsVersion(
                    major: GeneratedToolRequirements.sdkMajorVersion,
                    minor: 0
                )
    }

    nonisolated private static func detectSynchronously() -> CommandLineToolsAvailability {
        let developerDirectoryResult = run("/usr/bin/xcode-select", ["-p"])
        let developerDirectory = developerDirectoryResult.output
        guard developerDirectoryResult.status == 0,
            !developerDirectory.isEmpty,
            FileManager.default.fileExists(atPath: developerDirectory),
            FileManager.default.fileExists(atPath: developerDirectory + "/usr/bin")
        else {
            return .unavailable
        }

        let swiftResult = run("/usr/bin/xcrun", ["--no-cache", "swift", "--version"])
        let sdkResult = run(
            "/usr/bin/xcrun",
            ["--no-cache", "--sdk", "macosx", "--show-sdk-version"]
        )
        guard swiftResult.status == 0,
            sdkResult.status == 0,
            let swiftVersion = CommandLineToolsVersion.parseSwiftVersion(from: swiftResult.output),
            let sdkVersion = CommandLineToolsVersion.parseSDKVersion(from: sdkResult.output)
        else {
            return .unavailable
        }

        let selection = CommandLineToolsSelection(
            developerDirectory: developerDirectory,
            swiftVersion: swiftVersion,
            sdkVersion: sdkVersion
        )
        return isSupported(swiftVersion: swiftVersion, sdkVersion: sdkVersion)
            ? .available(selection)
            : .unsupported(selection)
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String])
        -> (status: Int32, output: String)
    {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "")
        }

        let text =
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}
