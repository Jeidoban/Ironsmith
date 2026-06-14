import Foundation

enum CommandLineToolsAvailability: Equatable {
    case available(path: String)
    case unavailable
}

struct CommandLineToolsClient {
    var detectAvailability: @Sendable () async -> CommandLineToolsAvailability
}

extension CommandLineToolsClient {
    nonisolated static let manualInstallCommand = "xcode-select --install"

    nonisolated static func live(processInfo: ProcessInfo = .processInfo) -> CommandLineToolsClient {
        live(environment: processInfo.environment)
    }

    nonisolated static func live(environment: [String: String]) -> CommandLineToolsClient {
        if let availabilityOverride = environment["IRONSMITH_TEST_SWIFTC_AVAILABLE"] {
            let availability: CommandLineToolsAvailability
            if availabilityOverride == "1" {
                availability = .available(path: "/usr/bin/swiftc")
            } else {
                availability = .unavailable
            }
            return fixed(availability: availability)
        }

        return CommandLineToolsClient(
            detectAvailability: {
                await Task.detached(priority: .utility) {
                    detectSynchronously()
                }.value
            }
        )
    }

    nonisolated static func fixed(availability: CommandLineToolsAvailability) -> CommandLineToolsClient {
        CommandLineToolsClient(
            detectAvailability: { availability }
        )
    }

    nonisolated private static func detectSynchronously() -> CommandLineToolsAvailability {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swiftc"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .unavailable
        }

        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0, let output, !output.isEmpty {
            return .available(path: output)
        }

        return .unavailable
    }
}
