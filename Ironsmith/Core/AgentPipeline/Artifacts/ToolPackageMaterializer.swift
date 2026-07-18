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

    nonisolated func createPlaceholderPackageDirectory(at packageRootURL: URL) throws {
        try fileClient.createDirectory(packageRootURL)
        try fileClient.createDirectory(
            ToolPackageLayout.packageMetadataDirectoryURL(for: packageRootURL)
        )
    }

    nonisolated func finalizePlaceholderPackage(
        from placeholderRootURL: URL,
        layout: ToolPackageLayout,
        displayName: String,
        settings: ToolGenerationSettings
    ) throws {
        let didMove = placeholderRootURL.standardizedFileURL != layout.packageRootURL.standardizedFileURL
        if didMove {
            try fileClient.moveItem(placeholderRootURL, layout.packageRootURL)
        }

        do {
            try materializePackage(
                layout: layout,
                displayName: displayName,
                settings: settings
            )
        } catch {
            if didMove {
                try? restorePlaceholderPackage(
                    from: layout,
                    to: placeholderRootURL
                )
            }
            throw error
        }
    }

    nonisolated func restorePlaceholderPackage(
        from layout: ToolPackageLayout,
        to placeholderRootURL: URL
    ) throws {
        try? fileClient.removeItemIfExists(layout.packageManifestURL)
        try? fileClient.removeItemIfExists(
            layout.packageRootURL.appendingPathComponent("Sources", isDirectory: true)
        )
        guard layout.packageRootURL.standardizedFileURL != placeholderRootURL.standardizedFileURL else {
            return
        }
        try fileClient.moveItem(layout.packageRootURL, placeholderRootURL)
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
