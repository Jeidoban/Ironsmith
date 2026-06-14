import Foundation

struct AgentFileClient: Sendable {
    var fileExists: @Sendable (URL) -> Bool
    var createDirectory: @Sendable (URL) throws -> Void
    var readString: @Sendable (URL) throws -> String
    var writeString: @Sendable (String, URL) throws -> Void
    var removeItemIfExists: @Sendable (URL) throws -> Void

    nonisolated static let live = AgentFileClient(
        fileExists: { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        createDirectory: { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        readString: { url in
            try String(contentsOf: url, encoding: .utf8)
        },
        writeString: { string, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try string.write(to: url, atomically: true, encoding: .utf8)
        },
        removeItemIfExists: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    )
}

enum AgentFileError: LocalizedError, Equatable {
    case emptyPath
    case pathIsPackageRoot
    case pathEscapesPackage(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "The agent tried to access an empty file path."
        case .pathIsPackageRoot:
            return "The agent tried to access the package root as a file."
        case .pathEscapesPackage(let path):
            return "The agent tried to access a file outside the generated package: \(path)"
        }
    }
}
