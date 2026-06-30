import Foundation
import SwiftData

enum StoreToolImportMode: Equatable, Sendable {
    case get
    case remix
}

struct StoreToolImportRequest: Sendable {
    let app: StoreAppListing
    let version: StoreVersionDownload
    let mode: StoreToolImportMode
    var isOwnApp = false
    var initialGenerationState: ToolGenerationState = .ready
}

struct StoreToolImportResult {
    let tool: Tool
    let mode: StoreToolImportMode
}

struct StoreToolImportClient {
    var importTool: @MainActor (
        _ request: StoreToolImportRequest,
        _ modelContext: ModelContext
    ) async throws -> StoreToolImportResult
}

extension StoreToolImportClient {
    static var live: Self {
        live(toolsDirectoryURL: IronsmithPaths.toolsDirectory)
    }

    static func live(toolsDirectoryURL: URL) -> Self {
        StoreToolImportClient { request, modelContext in
            try IronsmithStoreClient.verifySourceHash(request.version)

            let displayName = request.mode == .remix
                ? "\(request.app.name) Remix"
                : request.app.name
            let packageRootURL = try makeUniquePackageRoot(
                displayName: displayName,
                toolsDirectoryURL: toolsDirectoryURL
            )
            let executableName = ToolNameSanitizer.executableName(from: displayName)
            let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
            let settings = request.version.generationSettings.toolSettings

            try FileManager.default.createDirectory(
                at: layout.sourceDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: layout.packageMetadataDirectoryURL,
                withIntermediateDirectories: true
            )
            try layout.packageManifestContent().write(
                to: layout.packageManifestURL,
                atomically: true,
                encoding: .utf8
            )
            try layout.fixedAppEntrySource(displayName: displayName, settings: settings).write(
                to: try layout.packageFileURL(for: layout.appEntrySourcePath),
                atomically: true,
                encoding: .utf8
            )
            try request.version.sourceCode.write(
                to: try layout.packageFileURL(for: layout.contentViewSourcePath),
                atomically: true,
                encoding: .utf8
            )
            try await cacheIconIfAvailable(app: request.app, layout: layout)

            let now = Date()
            let generationPhase: ToolGenerationPhase = request.initialGenerationState == .generating
                ? .packaging
                : .completed
            let tool = Tool(
                name: displayName,
                executableName: executableName,
                sandboxEnabled: settings.sandboxEnabled,
                appKind: settings.appKind,
                menuBarSystemImage: settings.menuBarSystemImage,
                sandboxPermissions: settings.sandboxPermissions,
                resourcePermissions: settings.resourcePermissions,
                packageRootPath: packageRootURL.path,
                generationState: request.initialGenerationState,
                generationPhase: generationPhase,
                storeId: request.app.storeId,
                storeAppId: request.app.id,
                storeVersionId: request.version.id,
                storeVersionNumber: request.version.versionNumber,
                storeSourceSha256: request.version.sourceSha256,
                storeImportedAt: now,
                storeRemixedFromVersionId: request.isOwnApp ? nil : request.version.id,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(tool)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                try? FileManager.default.removeItem(at: packageRootURL)
                throw error
            }

            return StoreToolImportResult(tool: tool, mode: request.mode)
        }
    }

    private static func makeUniquePackageRoot(
        displayName: String,
        toolsDirectoryURL: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: toolsDirectoryURL,
            withIntermediateDirectories: true
        )
        let slug = ToolNameSanitizer.slug(from: displayName)
        var candidate = toolsDirectoryURL.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = toolsDirectoryURL.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func cacheIconIfAvailable(app: StoreAppListing, layout: ToolPackageLayout) async throws {
        guard let url = app.iconAsset?.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  !data.isEmpty
            else {
                return
            }
            try data.write(to: layout.cachedAppIconPNGURL, options: .atomic)
        } catch {
            AgentDiagnosticsLog.append(
                """
                Store app icon download failed.
                app: \(app.id)
                url: \(url.absoluteString)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
        }
    }
}
