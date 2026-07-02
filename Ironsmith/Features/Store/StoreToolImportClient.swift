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

    static func live(
        toolsDirectoryURL: URL,
        packageMaterializer: ToolPackageMaterializer = .live
    ) -> Self {
        StoreToolImportClient { request, modelContext in
            try IronsmithStoreClient.verifySourceHash(request.version)

            let displayName = request.mode == .remix
                ? "\(request.app.name) Remix"
                : request.app.name
            let packageRootURL = try packageMaterializer.makeUniquePackageRoot(
                displayName: displayName,
                toolsDirectoryURL: toolsDirectoryURL
            )
            let executableName = ToolNameSanitizer.executableName(from: displayName)
            let layout = ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
            let settings = request.version.generationSettings.toolSettings

            try packageMaterializer.materializePackage(
                layout: layout,
                displayName: displayName,
                settings: settings,
                contentViewSource: request.version.sourceCode
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

    private static func cacheIconIfAvailable(app: StoreAppDetail, layout: ToolPackageLayout) async throws {
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
