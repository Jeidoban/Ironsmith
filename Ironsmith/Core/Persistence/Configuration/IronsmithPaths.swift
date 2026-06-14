import Foundation

enum IronsmithPaths {
    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ironsmith", isDirectory: true)
    }

    static var modelsDirectory: URL {
        rootDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var toolsDirectory: URL {
        rootDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    static var agentDiagnosticsLogURL: URL {
        rootDirectory.appendingPathComponent("agent-diagnostics.log")
    }

    static func ensureDirectoriesExist() throws {
        for directory in [modelsDirectory, toolsDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
