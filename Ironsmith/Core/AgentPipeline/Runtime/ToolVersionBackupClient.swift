import Foundation

struct ToolContentVersionBackup: Equatable {
    let packageRootURL: URL
    let contentViewPath: String
    let pendingURL: URL
    let previousURL: URL
}

struct ToolVersionBackupClient {
    var stageCurrentVersion: (_ packageRootURL: URL, _ contentViewPath: String) throws -> ToolContentVersionBackup
    var promoteStagedVersion: (_ backup: ToolContentVersionBackup) throws -> Void
    var discardStagedVersion: (_ backup: ToolContentVersionBackup) throws -> Void
    var hasPreviousVersion: (_ packageRootURL: URL, _ contentViewPath: String) -> Bool
    var restorePreviousVersion: (_ packageRootURL: URL, _ contentViewPath: String) throws -> Void

    nonisolated static let live = ToolVersionBackupClient(
        stageCurrentVersion: { packageRootURL, contentViewPath in
            let contentViewURL = try resolvedContentViewURL(
                packageRootURL: packageRootURL,
                contentViewPath: contentViewPath
            )
            let backup = try backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath)
            let source = try String(contentsOf: contentViewURL, encoding: .utf8)

            try FileManager.default.createDirectory(
                at: backup.pendingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: backup.pendingURL, atomically: true, encoding: .utf8)
            return backup
        },
        promoteStagedVersion: { backup in
            guard FileManager.default.fileExists(atPath: backup.pendingURL.path) else {
                throw ToolVersionBackupError.missingStagedVersion
            }
            if FileManager.default.fileExists(atPath: backup.previousURL.path) {
                try FileManager.default.removeItem(at: backup.previousURL)
            }
            try FileManager.default.moveItem(at: backup.pendingURL, to: backup.previousURL)
        },
        discardStagedVersion: { backup in
            guard FileManager.default.fileExists(atPath: backup.pendingURL.path) else { return }
            try FileManager.default.removeItem(at: backup.pendingURL)
        },
        hasPreviousVersion: { packageRootURL, contentViewPath in
            guard let backup = try? backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath) else {
                return false
            }
            return FileManager.default.fileExists(atPath: backup.previousURL.path)
        },
        restorePreviousVersion: { packageRootURL, contentViewPath in
            let contentViewURL = try resolvedContentViewURL(
                packageRootURL: packageRootURL,
                contentViewPath: contentViewPath
            )
            let backup = try backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath)
            guard FileManager.default.fileExists(atPath: backup.previousURL.path) else {
                throw ToolVersionBackupError.missingPreviousVersion
            }

            let previousSource = try String(contentsOf: backup.previousURL, encoding: .utf8)
            let currentSource: String
            if FileManager.default.fileExists(atPath: contentViewURL.path) {
                currentSource = try String(contentsOf: contentViewURL, encoding: .utf8)
            } else {
                currentSource = ""
            }

            try FileManager.default.createDirectory(
                at: contentViewURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try previousSource.write(to: contentViewURL, atomically: true, encoding: .utf8)
            try currentSource.write(to: backup.previousURL, atomically: true, encoding: .utf8)
        }
    )
}

enum ToolVersionBackupError: LocalizedError, Equatable {
    case missingPreviousVersion
    case missingStagedVersion

    var errorDescription: String? {
        switch self {
        case .missingPreviousVersion:
            return "This app does not have a previous version to restore."
        case .missingStagedVersion:
            return "Ironsmith could not find the staged previous version for this edit."
        }
    }
}

private func backupPaths(
    packageRootURL: URL,
    contentViewPath: String
) throws -> ToolContentVersionBackup {
    _ = try resolvedContentViewURL(packageRootURL: packageRootURL, contentViewPath: contentViewPath)
    return ToolContentVersionBackup(
        packageRootURL: packageRootURL,
        contentViewPath: contentViewPath,
        pendingURL: ToolPackageLayout.pendingContentViewVersionURL(for: packageRootURL),
        previousURL: ToolPackageLayout.previousContentViewVersionURL(for: packageRootURL)
    )
}

private func resolvedContentViewURL(
    packageRootURL: URL,
    contentViewPath: String
) throws -> URL {
    try ToolPackageLayout.packageFileURL(for: contentViewPath, packageRootURL: packageRootURL)
}
