import Foundation
import SwiftData

struct StoreToolImportRequest: Sendable {
    let app: StoreAppDetail
    let version: StoreVersionDownload
    var displayName: String? = nil
    var initialGenerationState: ToolGenerationState = .ready
    var ownerUserID: String? = nil
}

struct StoreToolImportResult {
    let tool: Tool
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
            let licenses =
                [request.version.license]
                + request.version.legalAttributions.map(\.license)
            if let unsupportedLicense = licenses.first(where: {
                !$0.isSupportedForPublication
            }) {
                throw IronsmithStoreClientError.unsupportedLicense(
                    unsupportedLicense.rawValue)
            }

            let displayName = request.displayName ?? request.app.name
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
            try StoreLegalPackageWriter.write(
                StoreLegalDocumentRenderer.render(
                    appName: request.app.name,
                    currentVersionId: request.version.id,
                    primaryLicense: request.version.license,
                    attributions: request.version.legalAttributions
                ),
                to: layout
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
            let storeMetadata = storeMetadata(
                app: request.app,
                version: request.version,
                ownerUserID: request.ownerUserID
            )
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
                storeMetadata: storeMetadata,
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

            return StoreToolImportResult(tool: tool)
        }
    }

    static func storeMetadata(
        app: StoreAppDetail,
        version: StoreVersionDownload,
        ownerUserID: String?
    ) -> ToolStoreMetadata {
        guard version.isOwnedByCurrentUser == true, let ownerUserID else {
            return ToolStoreMetadata(
                provenance: StoreProvenance(
                    remixSource: StoreVersionReference(
                        versionId: version.id,
                        storeId: app.storeId,
                        appId: app.id,
                        appName: app.name,
                        versionNumber: version.versionNumber,
                        sourceSha256: version.sourceSha256
                    ),
                    inspirations: []
                )
            )
        }

        return ToolStoreMetadata(
            publication: StorePublication(
                storeId: app.storeId,
                appId: app.id,
                versionId: version.id,
                versionNumber: version.versionNumber,
                sourceSha256: version.sourceSha256,
                ownerUserId: ownerUserID,
                publishedAt: publicationDate(version.publishedAt)
            ),
            provenance: publishedAppProvenance(app: app, version: version)
        )
    }

    private static func publishedAppProvenance(
        app: StoreAppDetail,
        version: StoreVersionDownload
    ) -> StoreProvenance? {
        let remixSource = version.remixedFromVersionId.map { versionID in
            versionReference(
                versionID: versionID,
                link: app.remix?.versionId == versionID ? app.remix : nil
            )
        }
        let inspirations = (version.inspiredByVersionIds ?? []).map { versionID in
            versionReference(
                versionID: versionID,
                link: app.inspirations.first { $0.versionId == versionID }
            )
        }
        return StoreProvenance(
            remixSource: remixSource,
            inspirations: inspirations
        ).normalized
    }

    private static func versionReference(
        versionID: String,
        link: StoreVersionLinkMetadata?
    ) -> StoreVersionReference {
        StoreVersionReference(
            versionId: versionID,
            storeId: link?.storeId,
            appId: link?.appId,
            appName: link?.appName,
            versionNumber: link?.versionNumber
        )
    }

    private static func publicationDate(_ value: String) -> Date {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
            ?? .now
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

    static func downloadImage(from url: URL) async throws -> Data {
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
