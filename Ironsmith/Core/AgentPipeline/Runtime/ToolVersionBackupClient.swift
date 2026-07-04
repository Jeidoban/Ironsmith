import Foundation

struct ToolContentVersionBackup: Equatable {
    let packageRootURL: URL
    let contentViewPath: String
    let pendingURL: URL
    let previousURL: URL
    let pendingBuildSettingsURL: URL
    let previousBuildSettingsURL: URL
}

struct ToolVersionBackupClient {
    var stageCurrentVersion: (
        _ packageRootURL: URL,
        _ contentViewPath: String,
        _ settings: ToolGenerationSettings
    ) throws -> ToolContentVersionBackup
    var promoteStagedVersion: (_ backup: ToolContentVersionBackup) throws -> Void
    var discardStagedVersion: (_ backup: ToolContentVersionBackup) throws -> Void
    var hasPreviousVersion: (_ packageRootURL: URL, _ contentViewPath: String) -> Bool
    var restoreStagedVersion: (
        _ packageRootURL: URL,
        _ contentViewPath: String,
        _ currentSettings: ToolGenerationSettings
    ) throws -> ToolGenerationSettings
    var restorePreviousVersion: (
        _ packageRootURL: URL,
        _ contentViewPath: String,
        _ currentSettings: ToolGenerationSettings
    ) throws -> ToolGenerationSettings

    nonisolated static let live = ToolVersionBackupClient(
        stageCurrentVersion: { packageRootURL, contentViewPath, settings in
            let contentViewURL = try resolvedContentViewURL(
                packageRootURL: packageRootURL,
                contentViewPath: contentViewPath
            )
            let backup = try backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath)
            let source = try String(contentsOf: contentViewURL, encoding: .utf8)
            let settingsData = try JSONEncoder().encode(ToolVersionBuildSettingsSnapshot(settings: settings))

            try FileManager.default.createDirectory(
                at: backup.pendingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: backup.pendingURL.path) {
                try source.write(to: backup.pendingURL, atomically: true, encoding: .utf8)
            }
            if !FileManager.default.fileExists(atPath: backup.pendingBuildSettingsURL.path) {
                try settingsData.write(to: backup.pendingBuildSettingsURL, options: .atomic)
            }
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
            if FileManager.default.fileExists(atPath: backup.previousBuildSettingsURL.path) {
                try FileManager.default.removeItem(at: backup.previousBuildSettingsURL)
            }
            if FileManager.default.fileExists(atPath: backup.pendingBuildSettingsURL.path) {
                try FileManager.default.moveItem(
                    at: backup.pendingBuildSettingsURL,
                    to: backup.previousBuildSettingsURL
                )
            }
        },
        discardStagedVersion: { backup in
            if FileManager.default.fileExists(atPath: backup.pendingURL.path) {
                try FileManager.default.removeItem(at: backup.pendingURL)
            }
            if FileManager.default.fileExists(atPath: backup.pendingBuildSettingsURL.path) {
                try FileManager.default.removeItem(at: backup.pendingBuildSettingsURL)
            }
        },
        hasPreviousVersion: { packageRootURL, contentViewPath in
            guard let backup = try? backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath) else {
                return false
            }
            return FileManager.default.fileExists(atPath: backup.previousURL.path)
        },
        restoreStagedVersion: { packageRootURL, contentViewPath, currentSettings in
            let contentViewURL = try resolvedContentViewURL(
                packageRootURL: packageRootURL,
                contentViewPath: contentViewPath
            )
            let backup = try backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath)
            guard FileManager.default.fileExists(atPath: backup.pendingURL.path) else {
                throw ToolVersionBackupError.missingStagedVersion
            }

            let stagedSource = try String(contentsOf: backup.pendingURL, encoding: .utf8)
            let stagedSettings = try readBuildSettings(
                at: backup.pendingBuildSettingsURL,
                fallback: currentSettings
            )
            try FileManager.default.createDirectory(
                at: contentViewURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try stagedSource.write(to: contentViewURL, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: backup.pendingURL.path) {
                try FileManager.default.removeItem(at: backup.pendingURL)
            }
            if FileManager.default.fileExists(atPath: backup.pendingBuildSettingsURL.path) {
                try FileManager.default.removeItem(at: backup.pendingBuildSettingsURL)
            }
            return stagedSettings
        },
        restorePreviousVersion: { packageRootURL, contentViewPath, currentSettings in
            let contentViewURL = try resolvedContentViewURL(
                packageRootURL: packageRootURL,
                contentViewPath: contentViewPath
            )
            let backup = try backupPaths(packageRootURL: packageRootURL, contentViewPath: contentViewPath)
            guard FileManager.default.fileExists(atPath: backup.previousURL.path) else {
                throw ToolVersionBackupError.missingPreviousVersion
            }

            let previousSource = try String(contentsOf: backup.previousURL, encoding: .utf8)
            let previousSettings = try readBuildSettings(
                at: backup.previousBuildSettingsURL,
                fallback: currentSettings
            )
            let currentSource: String
            if FileManager.default.fileExists(atPath: contentViewURL.path) {
                currentSource = try String(contentsOf: contentViewURL, encoding: .utf8)
            } else {
                currentSource = ""
            }
            let currentSettingsData = try JSONEncoder().encode(
                ToolVersionBuildSettingsSnapshot(settings: currentSettings)
            )

            try FileManager.default.createDirectory(
                at: contentViewURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try previousSource.write(to: contentViewURL, atomically: true, encoding: .utf8)
            try currentSource.write(to: backup.previousURL, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: backup.previousBuildSettingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try currentSettingsData.write(to: backup.previousBuildSettingsURL, options: .atomic)
            return previousSettings
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
        previousURL: ToolPackageLayout.previousContentViewVersionURL(for: packageRootURL),
        pendingBuildSettingsURL: ToolPackageLayout.pendingBuildSettingsVersionURL(for: packageRootURL),
        previousBuildSettingsURL: ToolPackageLayout.previousBuildSettingsVersionURL(for: packageRootURL)
    )
}

private func resolvedContentViewURL(
    packageRootURL: URL,
    contentViewPath: String
) throws -> URL {
    try ToolPackageLayout.packageFileURL(for: contentViewPath, packageRootURL: packageRootURL)
}

nonisolated private struct ToolVersionBuildSettingsSnapshot: Codable, Equatable {
    var appKind: String
    var menuBarSystemImage: String
    var sandboxEnabled: Bool
    var sandboxPermissions: String
    var resourcePermissions: String

    private enum CodingKeys: String, CodingKey {
        case appKind
        case menuBarSystemImage
        case sandboxEnabled
        case sandboxPermissions
        case resourcePermissions
        case appKindRawValue
        case sandboxPermissionRawValues
        case resourcePermissionRawValues
    }

    init(settings: ToolGenerationSettings) {
        appKind = settings.appKind.rawValue
        menuBarSystemImage = settings.menuBarSystemImage
        sandboxEnabled = settings.sandboxEnabled
        sandboxPermissions = settings.sandboxPermissions.rawValueList
        resourcePermissions = settings.resourcePermissions.rawValueList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appKind = try container.decodeIfPresent(String.self, forKey: .appKind)
            ?? container.decodeIfPresent(String.self, forKey: .appKindRawValue)
            ?? ToolAppKind.window.rawValue
        menuBarSystemImage = try container.decodeIfPresent(String.self, forKey: .menuBarSystemImage)
            ?? ToolMenuBarSymbol.fallback
        sandboxEnabled = try container.decodeIfPresent(Bool.self, forKey: .sandboxEnabled)
            ?? true
        sandboxPermissions = try container.decodeIfPresent(String.self, forKey: .sandboxPermissions)
            ?? container.decodeIfPresent(String.self, forKey: .sandboxPermissionRawValues)
            ?? GeneratedAppSandboxPermissions.default.rawValueList
        resourcePermissions = try container.decodeIfPresent(String.self, forKey: .resourcePermissions)
            ?? container.decodeIfPresent(String.self, forKey: .resourcePermissionRawValues)
            ?? GeneratedAppResourcePermissions.none.rawValueList
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appKind, forKey: .appKind)
        try container.encode(menuBarSystemImage, forKey: .menuBarSystemImage)
        try container.encode(sandboxEnabled, forKey: .sandboxEnabled)
        try container.encode(sandboxPermissions, forKey: .sandboxPermissions)
        try container.encode(resourcePermissions, forKey: .resourcePermissions)
    }

    var settings: ToolGenerationSettings {
        ToolGenerationSettings(
            appKind: ToolAppKind(rawValue: appKind) ?? .window,
            menuBarSystemImage: menuBarSystemImage,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: GeneratedAppSandboxPermissions(rawValueList: sandboxPermissions),
            resourcePermissions: GeneratedAppResourcePermissions(rawValueList: resourcePermissions)
        )
    }
}

private func readBuildSettings(
    at url: URL,
    fallback: ToolGenerationSettings
) throws -> ToolGenerationSettings {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return fallback
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ToolVersionBuildSettingsSnapshot.self, from: data).settings
}
