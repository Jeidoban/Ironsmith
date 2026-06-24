import Foundation

enum IronsmithPaths {
    static let databaseFileName = "ironsmith.sqlite"

    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ironsmith", isDirectory: true)
    }

    static var databaseDirectory: URL {
        rootDirectory.appendingPathComponent("db", isDirectory: true)
    }

    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent(databaseFileName)
    }

    static var databaseBackupsDirectory: URL {
        databaseDirectory.appendingPathComponent("backups", isDirectory: true)
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
        for directory in [
            databaseDirectory,
            databaseBackupsDirectory,
            modelsDirectory,
            toolsDirectory,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
