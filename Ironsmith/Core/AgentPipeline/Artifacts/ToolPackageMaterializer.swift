import Foundation

struct ToolPackageMaterializer: Sendable {
    let fileClient: AgentFileClient

    nonisolated init(fileClient: AgentFileClient = .live) {
        self.fileClient = fileClient
    }

    nonisolated static let live = ToolPackageMaterializer()

    nonisolated func makeUniquePackageRoot(
        displayName: String,
        toolsDirectoryURL: URL
    ) throws -> URL {
        try fileClient.createDirectory(toolsDirectoryURL)

        let slug = ToolNameSanitizer.slug(from: displayName)
        var candidate = toolsDirectoryURL.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while fileClient.fileExists(candidate) {
            candidate = toolsDirectoryURL.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    nonisolated func materializePackage(
        layout: ToolPackageLayout,
        displayName: String,
        settings: ToolGenerationSettings,
        contentViewSource: String? = nil
    ) throws {
        try preparePackageDirectories(layout)
        try writePackageManifest(layout)
        try writeAppEntry(layout: layout, displayName: displayName, settings: settings)
        if let contentViewSource {
            try writeContentView(contentViewSource, layout: layout)
        }
    }

    nonisolated func preparePackageDirectories(_ layout: ToolPackageLayout) throws {
        try fileClient.createDirectory(layout.sourceDirectoryURL)
        try fileClient.createDirectory(layout.packageMetadataDirectoryURL)
    }

    nonisolated func writePackageManifest(_ layout: ToolPackageLayout) throws {
        try fileClient.writeString(layout.packageManifestContent(), layout.packageManifestURL)
    }

    nonisolated func writeAppEntry(
        layout: ToolPackageLayout,
        displayName: String,
        settings: ToolGenerationSettings
    ) throws {
        try fileClient.writeString(
            layout.fixedAppEntrySource(displayName: displayName, settings: settings),
            try layout.packageFileURL(for: layout.appEntrySourcePath)
        )
    }

    nonisolated func writeContentView(
        _ source: String,
        layout: ToolPackageLayout
    ) throws {
        try fileClient.writeString(
            source,
            try layout.packageFileURL(for: layout.contentViewSourcePath)
        )
    }
}
