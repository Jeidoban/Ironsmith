import Foundation
import SwiftData

enum StoreToolImportMode: Equatable, Sendable {
    case get
    case remix
}

struct StoreToolImportRequest: Sendable {
    let app: StoreAppDetail
    let version: StoreVersionDownload
    let mode: StoreToolImportMode
    var displayName: String? = nil
    var initialGenerationState: ToolGenerationState = .ready
}

struct StoreToolImportResult {
    let tool: Tool
    let mode: StoreToolImportMode
}

struct StoreToolImportClient {
    var importTool:
        @MainActor (
            _ request: StoreToolImportRequest,
            _ modelContext: ModelContext
        ) async throws -> StoreToolImportResult
}

extension StoreToolImportClient {
    static var live: Self {
        live(toolsDirectoryURL: IronsmithPaths.toolsDirectory)
    }

    static func live(
        toolsDirectoryURL: URL,
        packageMaterializer: ToolPackageMaterializer = .live,
        iconDataLoader: @escaping @Sendable (URL) async throws -> Data = {
            try await downloadImage(from: $0)
        }
    ) -> Self {
        StoreToolImportClient { request, modelContext in
            try IronsmithStoreClient.verifySourceHash(request.version)

            let displayName =
                request.displayName
                ?? (request.mode == .remix
                    ? "\(request.app.name) Remix"
                    : request.app.name)
            let packageRootURL = try packageMaterializer.makeUniquePackageRoot(
                displayName: displayName,
                toolsDirectoryURL: toolsDirectoryURL
            )
            let executableName = ToolNameSanitizer.executableName(from: displayName)
            let layout = ToolPackageLayout(
                packageRootURL: packageRootURL, executableName: executableName)
            let settings = request.version.generationSettings.toolSettings

            try packageMaterializer.materializePackage(
                layout: layout,
                displayName: displayName,
                settings: settings,
                contentViewSource: request.version.sourceCode
            )
            try await cacheIconIfAvailable(
                app: request.app,
                layout: layout,
                dataLoader: iconDataLoader
            )

            let now = Date()
            let generationPhase: ToolGenerationPhase =
                request.initialGenerationState == .generating
                ? .packaging
                : .completed
            let tool = Tool(
                name: displayName,
                executableName: executableName,
                category: request.app.category,
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
                storeRemixedFromVersionId: request.version.remixedFromVersionId,
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

    static func cacheIconIfAvailable(
        app: StoreAppDetail,
        layout: ToolPackageLayout,
        dataLoader: @escaping @Sendable (URL) async throws -> Data = {
            try await downloadImage(from: $0)
        }
    ) async throws {
        guard let thumbnailURL = app.iconAsset?.url else { return }
        do {
            if let masterURL = app.iconMaster?.url {
                async let masterData = dataLoader(masterURL)
                async let thumbnailData = dataLoader(thumbnailURL)
                let (master, thumbnail) = try await (masterData, thumbnailData)
                try ToolIconClient.installDownloadedIconAssets(
                    masterJPEG: master,
                    thumbnailJPEG: thumbnail,
                    request: ToolIconRequest(displayName: app.name, layout: layout)
                )
            } else {
                let data = try await dataLoader(thumbnailURL)
                try FileManager.default.createDirectory(
                    at: layout.packageMetadataDirectoryURL,
                    withIntermediateDirectories: true
                )
                try data.write(to: layout.cachedAppIconPNGURL, options: .atomic)
                _ = try await ToolIconClient.cachedOnly().ensureIconAssets(
                    ToolIconRequest(displayName: app.name, layout: layout)
                )
            }
        } catch {
            AgentDiagnosticsLog.append(
                """
                Store app icon download failed.
                app: \(app.id)
                thumbnailURL: \(thumbnailURL.absoluteString)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
        }
    }

    private static func downloadImage(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode),
            !data.isEmpty
        else {
            throw IronsmithStoreClientError.invalidResponse
        }
        return data
    }
}
