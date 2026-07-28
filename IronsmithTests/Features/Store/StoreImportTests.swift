import AppKit
import CoreGraphics
import Foundation
import SwiftData
import Testing

@testable import Ironsmith

struct StoreImportTests {
    @Test
    func storeMultipartUsesJPEGAssetContract() throws {
        let body = StoreMultipartBody(boundary: "JPEG-Test-Boundary")
            .addingFile(
                name: "iconMaster",
                filename: "icon-master.jpg",
                contentType: "image/jpeg",
                data: Data("master-bytes".utf8)
            )
            .addingFile(
                name: "iconThumbnail",
                filename: "icon-thumbnail.jpg",
                contentType: "image/jpeg",
                data: Data("thumbnail-bytes".utf8)
            )
            .addingScreenshotFiles([Data("screenshot-bytes".utf8)])
        let encoded = String(decoding: body.data, as: UTF8.self)

        #expect(
            encoded.contains(
                #"name="iconMaster"; filename="icon-master.jpg""#
            )
        )
        #expect(
            encoded.contains(
                #"name="iconThumbnail"; filename="icon-thumbnail.jpg""#
            )
        )
        #expect(
            encoded.contains(
                #"name="screenshots"; filename="screenshot-1.jpg""#
            )
        )
        #expect(encoded.components(separatedBy: "Content-Type: image/jpeg").count == 4)
        #expect(encoded.hasSuffix("--JPEG-Test-Boundary--\r\n"))
    }

    @MainActor
    @Test
    func storeSourceHashVerificationRejectsTamperedDownloads() throws {
        let version = Self.versionDownload(
            sourceCode:
                "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"bad\") } }",
            sourceSha256: String(repeating: "0", count: 64)
        )

        #expect(
            throws: IronsmithStoreClientError.sourceHashMismatch(
                expected: version.sourceSha256,
                actual: IronsmithStoreClient.sha256Hex(for: version.sourceCode))
        ) {
            try IronsmithStoreClient.verifySourceHash(version)
        }
    }

    @MainActor
    @Test
    func getImportCreatesReadyAttributedLocalTool() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let source = Self.sourceCode("downloaded")
        let app = Self.appListing(sourceCode: source)
        let version = Self.versionDownload(
            appId: app.id,
            sourceCode: source,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
        )

        let result = try await StoreToolImportClient.live(toolsDirectoryURL: root)
            .importTool(StoreToolImportRequest(app: app, version: version, mode: .get), context)

        let tool = result.tool
        let sourceOnDisk = try String(
            contentsOf: try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath),
            encoding: .utf8)
        let tools = try context.fetch(FetchDescriptor<Tool>())

        #expect(result.mode == .get)
        #expect(tools.map(\.id) == [tool.id])
        #expect(sourceOnDisk == source)
        #expect(tool.generationState == .ready)
        #expect(tool.generationPhase == .completed)
        #expect(tool.storeId == app.storeId)
        #expect(tool.storeAppId == app.id)
        #expect(tool.storeVersionId == version.id)
        #expect(tool.storeVersionNumber == version.versionNumber)
        #expect(tool.storeSourceSha256 == version.sourceSha256)
        #expect(tool.storeImportedAt != nil)
        #expect(tool.storeRemixedFromVersionId == version.id)
    }

    @MainActor
    @Test
    func storeImportPersistsJPEGsAndBuildsICNSFromMaster() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let source = Self.sourceCode("downloaded icon")
        let iconImage = try Self.transparentIconImage()
        let iconAssets = try ToolImageAssetEncoder.iconAssets(from: iconImage)
        let masterURL = URL(string: "https://assets.example.test/master.jpg")!
        let thumbnailURL = URL(string: "https://assets.example.test/thumbnail.jpg")!
        let app = Self.appListing(
            sourceCode: source,
            icon: StoreAsset(
                id: UUID().uuidString,
                kind: .icon,
                sortOrder: 0,
                width: 256,
                height: 256,
                byteSize: iconAssets.thumbnailData.count,
                url: thumbnailURL
            ),
            iconMaster: StoreAsset(
                id: UUID().uuidString,
                kind: .iconMaster,
                sortOrder: 0,
                width: 1024,
                height: 1024,
                byteSize: iconAssets.masterData.count,
                url: masterURL
            )
        )
        let version = Self.versionDownload(
            appId: app.id,
            sourceCode: source,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
        )
        let client = StoreToolImportClient.live(
            toolsDirectoryURL: root,
            iconDataLoader: { url in
                switch url {
                case masterURL:
                    return iconAssets.masterData
                case thumbnailURL:
                    return iconAssets.thumbnailData
                default:
                    throw IronsmithStoreClientError.invalidResponse
                }
            }
        )

        let result = try await client.importTool(
            StoreToolImportRequest(app: app, version: version, mode: .get),
            context
        )
        let layout = result.tool.packageLayout

        #expect(
            try Data(contentsOf: layout.cachedAppIconMasterJPEGURL)
                == iconAssets.masterData
        )
        #expect(
            try Data(contentsOf: layout.cachedAppIconThumbnailJPEGURL)
                == iconAssets.thumbnailData
        )
        #expect(FileManager.default.fileExists(atPath: layout.cachedAppIconICNSURL.path))
        let importedICNS = try ToolImageAssetEncoder.largestImage(
            at: layout.cachedAppIconICNSURL
        )
        let corner = try #require(
            NSBitmapImageRep(cgImage: importedICNS).colorAt(x: 0, y: 0)
        )
        #expect(corner.alphaComponent > 0.99)
    }

    @MainActor
    @Test
    func remixImportTracksParentVersionWithoutLinkingOriginalAppForUpdates() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let source = Self.sourceCode("remix")
        let app = Self.appListing(sourceCode: source)
        let version = Self.versionDownload(
            appId: app.id,
            sourceCode: source,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
        )

        let result = try await StoreToolImportClient.live(toolsDirectoryURL: root)
            .importTool(StoreToolImportRequest(app: app, version: version, mode: .remix), context)

        #expect(result.tool.name == "\(app.name) Remix")
        #expect(result.tool.storeId == app.storeId)
        #expect(result.tool.storeAppId == app.id)
        #expect(result.tool.storeVersionId == version.id)
        #expect(result.tool.storeVersionNumber == version.versionNumber)
        #expect(result.tool.storeSourceSha256 == version.sourceSha256)
        #expect(result.tool.storeImportedAt != nil)
        #expect(result.tool.storeRemixedFromVersionId == version.id)
    }

    @MainActor
    @Test
    func ownAppImportLinksPublishedAppWithoutRemixAttribution() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let source = Self.sourceCode("own")
        let app = Self.appListing(sourceCode: source)
        let version = Self.versionDownload(
            appId: app.id,
            sourceCode: source,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
        )

        let result = try await StoreToolImportClient.live(toolsDirectoryURL: root)
            .importTool(
                StoreToolImportRequest(
                    app: app,
                    version: version,
                    mode: .get,
                    isOwnApp: true
                ),
                context
            )

        #expect(result.tool.storeId == app.storeId)
        #expect(result.tool.storeAppId == app.id)
        #expect(result.tool.storeVersionId == version.id)
        #expect(result.tool.storeVersionNumber == version.versionNumber)
        #expect(result.tool.storeSourceSha256 == version.sourceSha256)
        #expect(result.tool.storeRemixedFromVersionId == nil)
    }

    @MainActor
    @Test
    func repeatedStoreImportsCreateDistinctLocalTools() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let source = Self.sourceCode("copy")
        let app = Self.appListing(sourceCode: source)
        let version = Self.versionDownload(
            appId: app.id,
            sourceCode: source,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
        )
        let client = StoreToolImportClient.live(toolsDirectoryURL: root)

        let first = try await client.importTool(
            StoreToolImportRequest(app: app, version: version, mode: .get), context)
        let second = try await client.importTool(
            StoreToolImportRequest(app: app, version: version, mode: .get), context)
        let tools = try context.fetch(FetchDescriptor<Tool>())

        #expect(tools.count == 2)
        #expect(first.tool.id != second.tool.id)
        #expect(first.tool.packageRootPath != second.tool.packageRootPath)
        #expect(first.tool.storeRemixedFromVersionId == version.id)
        #expect(second.tool.storeRemixedFromVersionId == version.id)
        #expect(first.tool.storeAppId == app.id)
        #expect(second.tool.storeAppId == app.id)
    }

    @MainActor
    @Test
    func storeWindowInstallDispositionUsesLocalSourceHashes() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let store = StoreWindowStore(
            client: .unconfigured,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )
        let oldSource = Self.sourceCode("old")
        let currentSource = Self.sourceCode("current")
        let app = Self.appListing(sourceCode: currentSource)
        let oldVersion = Self.versionDownload(
            appId: app.id,
            sourceCode: oldSource,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: oldSource)
        )

        let imported = try await StoreToolImportClient.live(toolsDirectoryURL: root)
            .importTool(StoreToolImportRequest(app: app, version: oldVersion, mode: .get), context)

        guard
            case .updateExisting(let updatableTool) = store.installDisposition(
                for: app, tools: [imported.tool])
        else {
            Issue.record("Expected an unchanged older import to be updatable.")
            return
        }
        #expect(updatableTool.id == imported.tool.id)

        try currentSource.write(
            to: try imported.tool.packageLayout.packageFileURL(
                for: imported.tool.contentViewSourcePath),
            atomically: true,
            encoding: .utf8
        )
        guard
            case .openExisting(let currentTool) = store.installDisposition(
                for: app, tools: [imported.tool])
        else {
            Issue.record("Expected a local copy matching the current hash to open.")
            return
        }
        #expect(currentTool.id == imported.tool.id)

        try Self.sourceCode("edited").write(
            to: try imported.tool.packageLayout.packageFileURL(
                for: imported.tool.contentViewSourcePath),
            atomically: true,
            encoding: .utf8
        )
        guard case .createCopy = store.installDisposition(for: app, tools: [imported.tool]) else {
            Issue.record("Expected an edited local copy to avoid destructive replacement.")
            return
        }
    }

    @MainActor
    @Test
    func storeSummaryInstallDispositionUsesVersionLinkageAndProtectsEditedTools() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let store = StoreWindowStore(
            client: .unconfigured,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )
        let oldSource = Self.sourceCode("old")
        let currentSource = Self.sourceCode("current")
        let oldMetadata = Self.versionMetadata(versionNumber: 1, sourceCode: oldSource)
        let currentMetadata = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000202",
            versionNumber: 2,
            sourceCode: currentSource
        )
        let app = Self.appListing(
            sourceCode: currentSource,
            versions: [currentMetadata, oldMetadata]
        )
        let summary = StoreAppSummary(detail: app)
        let client = StoreToolImportClient.live(toolsDirectoryURL: root)
        let oldImport = try await client.importTool(
            StoreToolImportRequest(
                app: app,
                version: Self.versionDownload(
                    versionNumber: 1,
                    appId: app.id,
                    sourceCode: oldSource,
                    sourceSha256: oldMetadata.sourceSha256
                ),
                mode: .get
            ),
            context
        )

        guard
            case .updateExisting(let tool) = store.installDisposition(
                for: summary,
                tools: [oldImport.tool]
            )
        else {
            Issue.record("Expected the listing row to show Update for an unchanged older version.")
            return
        }
        #expect(tool.id == oldImport.tool.id)

        let currentImport = try await client.importTool(
            StoreToolImportRequest(
                app: app,
                version: Self.versionDownload(
                    id: currentMetadata.id,
                    versionNumber: 2,
                    appId: app.id,
                    sourceCode: currentSource,
                    sourceSha256: currentMetadata.sourceSha256
                ),
                mode: .get
            ),
            context
        )
        guard
            case .openExisting(let tool) = store.installDisposition(
                for: summary,
                tools: [currentImport.tool]
            )
        else {
            Issue.record("Expected the listing row to show Open for an unchanged current version.")
            return
        }
        #expect(tool.id == currentImport.tool.id)

        try Self.sourceCode("edited").write(
            to: try currentImport.tool.packageLayout.packageFileURL(
                for: currentImport.tool.contentViewSourcePath
            ),
            atomically: true,
            encoding: .utf8
        )
        guard
            case .createCopy = store.installDisposition(
                for: summary,
                tools: [currentImport.tool]
            )
        else {
            Issue.record("Expected an edited current copy to show Get.")
            return
        }
    }

    @MainActor
    @Test
    func successfulStoreMutationRequestsImplicitContentRefresh() async {
        let app = Self.appListing(sourceCode: Self.sourceCode("published"))
        var client = IronsmithStoreClient.unconfigured
        client.patchListing = { _, _, _ in app }
        let store = StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )

        await store.setStatus(StoreAppSummary(detail: app), status: .unlisted)

        #expect(store.contentRevision == 1)
    }

    @MainActor
    @Test
    func searchPaginationAppendsUniqueResultsAndAdvancesCursor() async {
        let first = Self.appSummary(id: "app-one")
        let second = Self.appSummary(id: "app-two")
        let recorder = StoreListRequestRecorder()
        var client = IronsmithStoreClient.unconfigured
        client.listApps = { _, scope, search, cursor, sort, category in
            await recorder.record(
                scope: scope,
                search: search,
                cursor: cursor,
                sort: sort,
                category: category
            )
            if cursor == nil {
                return StoreAppPage(apps: [first], nextCursor: "page-two")
            }
            return StoreAppPage(apps: [first, second], nextCursor: nil)
        }
        let store = StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )
        store.searchText = "calculator"

        await store.refreshDiscover()
        await store.loadMoreSearchResults()

        #expect(store.searchResults.map(\.id) == [first.id, second.id])
        #expect(store.searchResultsNextCursor == nil)
        let requests = await recorder.requests
        #expect(requests.map(\.cursor) == [nil, "page-two"])
        #expect(requests.allSatisfy { $0.scope == .discover })
        #expect(requests.allSatisfy { $0.search == "calculator" })
    }

    @MainActor
    @Test
    func sectionPaginationForwardsCategorySortAndCursor() async {
        let app = Self.appSummary(id: "section-app")
        let recorder = StoreListRequestRecorder()
        var client = IronsmithStoreClient.unconfigured
        client.listApps = { _, scope, search, cursor, sort, category in
            await recorder.record(
                scope: scope,
                search: search,
                cursor: cursor,
                sort: sort,
                category: category
            )
            return StoreAppPage(
                apps: [app],
                nextCursor: cursor == nil ? "next-section-page" : nil
            )
        }
        let store = StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )

        let firstPage = await store.loadSectionApps(
            sort: .trending,
            category: .games
        )
        let secondPage = await store.loadSectionApps(
            sort: .trending,
            category: .games,
            cursor: firstPage?.nextCursor
        )

        #expect(firstPage?.nextCursor == "next-section-page")
        #expect(secondPage?.nextCursor == nil)
        let requests = await recorder.requests
        #expect(requests.map(\.cursor) == [nil, "next-section-page"])
        #expect(requests.allSatisfy { $0.scope == .discover })
        #expect(requests.allSatisfy { $0.search == nil })
        #expect(requests.allSatisfy { $0.sort == .trending })
        #expect(requests.allSatisfy { $0.category == .games })
    }

    @MainActor
    @Test
    func publishedPaginationAppendsUniqueResultsAndAdvancesCursor() async {
        let first = Self.appSummary(id: "published-one")
        let second = Self.appSummary(id: "published-two")
        let recorder = StoreListRequestRecorder()
        var client = IronsmithStoreClient.unconfigured
        client.listApps = { _, scope, search, cursor, sort, category in
            await recorder.record(
                scope: scope,
                search: search,
                cursor: cursor,
                sort: sort,
                category: category
            )
            if cursor == nil {
                return StoreAppPage(apps: [first], nextCursor: "published-page-two")
            }
            return StoreAppPage(apps: [first, second], nextCursor: nil)
        }
        let store = StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )

        await store.refreshPublished()
        await store.loadMorePublishedApps()

        #expect(store.publishedApps.map(\.id) == [first.id, second.id])
        #expect(store.publishedAppsNextCursor == nil)
        let requests = await recorder.requests
        #expect(requests.map(\.cursor) == [nil, "published-page-two"])
        #expect(requests.allSatisfy { $0.scope == .mine })
        #expect(requests.allSatisfy { $0.search == nil })
    }

    @MainActor
    @Test
    func historicalVersionWithSharedSourceCreatesAttributedSeparateCopyWithoutMutatingExistingTool()
        async throws
    {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let historicalSource = Self.sourceCode("shared")
        let currentSource = historicalSource
        let historicalMetadata = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            versionNumber: 1,
            sourceCode: historicalSource,
            publishedAt: "2026-06-27T00:00:00.000Z"
        )
        let currentMetadata = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000202",
            versionNumber: 2,
            sourceCode: currentSource,
            publishedAt: "2026-06-28T00:00:00.000Z"
        )
        let app = Self.appListing(
            sourceCode: currentSource,
            versions: [currentMetadata, historicalMetadata]
        )
        let currentDownload = Self.versionDownload(
            id: currentMetadata.id,
            versionNumber: 2,
            appId: app.id,
            sourceCode: currentSource,
            sourceSha256: currentMetadata.sourceSha256
        )
        let historicalDownload = Self.versionDownload(
            id: historicalMetadata.id,
            versionNumber: 1,
            appId: app.id,
            sourceCode: historicalSource,
            sourceSha256: historicalMetadata.sourceSha256
        )
        let importer = StoreToolImportClient.live(toolsDirectoryURL: root)
        let existing = try await importer.importTool(
            StoreToolImportRequest(app: app, version: currentDownload, mode: .get),
            context
        ).tool
        var client = IronsmithStoreClient.unconfigured
        client.fetchVersion = { _, _, versionNumber in
            #expect(versionNumber == 1)
            return historicalDownload
        }
        let store = StoreWindowStore(
            client: client,
            importClient: importer,
            buildClient: ToolBuildClient(buildTool: { _ in })
        )

        await store.installVersion(
            historicalMetadata,
            of: app,
            tools: [existing],
            modelContext: context,
            routeStore: IronsmithRouteStore(openSettingsWindow: {}),
            inferenceStore: InferenceStore()
        )

        let tools = try context.fetch(FetchDescriptor<Tool>())
        let installed = try #require(tools.first { $0.id != existing.id })
        let existingSource = try String(
            contentsOf: try existing.packageLayout.packageFileURL(
                for: existing.contentViewSourcePath),
            encoding: .utf8
        )
        #expect(tools.count == 2)
        #expect(existingSource == currentSource)
        #expect(existing.storeVersionId == currentMetadata.id)
        #expect(installed.name == "\(app.name) v1")
        #expect(installed.generationState == .ready)
        #expect(installed.storeVersionId == historicalMetadata.id)
        #expect(installed.storeVersionNumber == 1)
        #expect(installed.storeSourceSha256 == historicalMetadata.sourceSha256)
        #expect(installed.storeRemixedFromVersionId == historicalMetadata.id)
        #expect(store.workingVersionID == nil)

        guard
            case .openExisting(let matchingTool) = store.installDisposition(
                for: historicalMetadata,
                of: app,
                tools: tools
            )
        else {
            Issue.record("Expected the exact installed historical version to open.")
            return
        }
        #expect(matchingTool.id == installed.id)
    }

    @MainActor
    @Test
    func historicalVersionHashMismatchDoesNotCreateOrChangeTools() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let historicalSource = Self.sourceCode("historical")
        let currentSource = Self.sourceCode("current")
        let historicalMetadata = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            versionNumber: 1,
            sourceCode: historicalSource
        )
        let currentMetadata = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000202",
            versionNumber: 2,
            sourceCode: currentSource
        )
        let app = Self.appListing(
            sourceCode: currentSource,
            versions: [currentMetadata, historicalMetadata]
        )
        let mismatchedSource = Self.sourceCode("wrong version")
        let mismatchedDownload = Self.versionDownload(
            id: historicalMetadata.id,
            versionNumber: 1,
            appId: app.id,
            sourceCode: mismatchedSource,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: mismatchedSource)
        )
        var client = IronsmithStoreClient.unconfigured
        client.fetchVersion = { _, _, _ in mismatchedDownload }
        let store = StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient.live(toolsDirectoryURL: root),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )

        await store.installVersion(
            historicalMetadata,
            of: app,
            tools: [],
            modelContext: context,
            routeStore: IronsmithRouteStore(openSettingsWindow: {}),
            inferenceStore: InferenceStore()
        )

        #expect(try context.fetch(FetchDescriptor<Tool>()).isEmpty)
        #expect(store.errorMessage != nil)
        #expect(store.workingVersionID == nil)
    }

    @MainActor
    @Test
    func historicalVersionBuildFailureLeavesFailedCopyAndNoOtherToolChanges() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let source = Self.sourceCode("historical")
        let metadata = Self.versionMetadata(versionNumber: 1, sourceCode: source)
        let app = Self.appListing(sourceCode: source, versions: [metadata])
        let download = Self.versionDownload(
            id: metadata.id,
            versionNumber: 1,
            appId: app.id,
            sourceCode: source,
            sourceSha256: metadata.sourceSha256
        )
        var client = IronsmithStoreClient.unconfigured
        client.fetchVersion = { _, _, _ in download }
        let store = StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient.live(toolsDirectoryURL: root),
            buildClient: ToolBuildClient(buildTool: { _ in throw TestFailure.build })
        )

        await store.installVersion(
            metadata,
            of: app,
            tools: [],
            modelContext: context,
            routeStore: IronsmithRouteStore(openSettingsWindow: {}),
            inferenceStore: InferenceStore()
        )

        let failedTool = try #require(context.fetch(FetchDescriptor<Tool>()).first)
        #expect(failedTool.generationState == .failed)
        #expect(failedTool.storeVersionId == metadata.id)
        #expect(failedTool.storeRemixedFromVersionId == metadata.id)
        #expect(store.errorMessage != nil)
    }

    @Test
    func storePermissionPresentationUsesFriendlyLabelsAndSupportsEmptyState() {
        let source = Self.sourceCode("permissions")
        let permissionVersion = Self.versionMetadata(
            versionNumber: 1,
            sourceCode: source,
            settings: ToolGenerationSettings(
                sandboxEnabled: true,
                sandboxPermissions: GeneratedAppSandboxPermissions([.internet]),
                resourcePermissions: GeneratedAppResourcePermissions([.microphone])
            )
        )
        let items = StorePermissionPresentation.items(for: permissionVersion)

        #expect(items.map(\.title) == ["Internet", "Microphone"])
        #expect(
            items.map(\.explanation) == [
                "Access to network connections",
                "Access to audio input",
            ]
        )

        let emptyVersion = Self.versionMetadata(
            versionNumber: 1,
            sourceCode: source,
            settings: ToolGenerationSettings(
                sandboxEnabled: false,
                sandboxPermissions: .none,
                resourcePermissions: .none
            )
        )
        #expect(StorePermissionPresentation.items(for: emptyVersion).isEmpty)
        #expect(StoreVersionPresentation.permissionsSummary(emptyVersion) == "None")
    }

    @Test
    func storeVersionPresentationOrdersNewestFirstAndDesignatesCurrentVersion() {
        let first = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            versionNumber: 1,
            sourceCode: Self.sourceCode("one"),
            publishedAt: "2026-06-27T00:00:00.000Z"
        )
        let second = Self.versionMetadata(
            id: "00000000-0000-4000-8000-000000000202",
            versionNumber: 2,
            sourceCode: Self.sourceCode("two"),
            publishedAt: "2026-06-28T00:00:00.000Z"
        )
        let app = Self.appListing(sourceCode: Self.sourceCode("two"), versions: [first, second])

        #expect(StoreVersionPresentation.newestFirst(app.versions).map(\.versionNumber) == [2, 1])
        #expect(StoreVersionPresentation.isCurrent(second, in: app))
        #expect(!StoreVersionPresentation.isCurrent(first, in: app))
        #expect(StoreVersionPresentation.formattedDate(second.publishedAt).contains("2026"))
    }

    private static func sourceCode(_ text: String) -> String {
        """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("\(text)")
            }
        }
        """
    }

    private static func appSummary(id: String) -> StoreAppSummary {
        StoreAppSummary(
            id: id,
            storeId: "00000000-0000-4000-8000-000000000011",
            authorDisplayName: "Jade",
            name: id,
            shortDescription: "A Store app",
            category: .utilities,
            status: .published,
            latestVersionNumber: 1,
            publishedAt: "2026-06-27T00:00:00.000Z",
            updatedAt: "2026-06-27T00:00:00.000Z",
            icon: nil
        )
    }

    private static func appListing(
        sourceCode: String,
        versions suppliedVersions: [StoreVersionMetadata]? = nil,
        icon: StoreAsset? = nil,
        iconMaster: StoreAsset? = nil
    ) -> StoreAppDetail {
        let storeId = "00000000-0000-4000-8000-000000000011"
        let appId = "00000000-0000-4000-8000-000000000101"
        let version = StoreVersionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            appId: appId,
            versionNumber: 1,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: sourceCode),
            generationSettings: StoreGenerationSettingsDTO(settings: .default),
            runtimeVersion: "ironsmith-macos-v1",
            license: "MIT",
            scannerVersion: "swift-execution-blocklist-v1",
            remixedFromVersionId: nil,
            publishedAt: "2026-06-27T00:00:00.000Z"
        )
        let versions = suppliedVersions ?? [version]
        let currentVersion = versions.max { $0.versionNumber < $1.versionNumber } ?? version
        return StoreAppDetail(
            id: appId,
            storeId: storeId,
            storeVisibility: "public",
            authorDisplayName: "Jade",
            name: "Clipboard Cleaner",
            shortDescription: "Clipboard cleanup",
            description: "Cleans clipboard text.",
            category: .utilities,
            status: .published,
            publishedAt: "2026-06-27T00:00:00.000Z",
            createdAt: "2026-06-27T00:00:00.000Z",
            updatedAt: "2026-06-27T00:00:00.000Z",
            icon: icon,
            iconMaster: iconMaster,
            screenshots: [],
            currentVersion: currentVersion,
            versions: versions,
            remix: nil
        )
    }

    private static func versionMetadata(
        id: String = "00000000-0000-4000-8000-000000000201",
        versionNumber: Int,
        sourceCode: String,
        settings: ToolGenerationSettings = .default,
        publishedAt: String = "2026-06-27T00:00:00.000Z"
    ) -> StoreVersionMetadata {
        StoreVersionMetadata(
            id: id,
            appId: "00000000-0000-4000-8000-000000000101",
            versionNumber: versionNumber,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: sourceCode),
            generationSettings: StoreGenerationSettingsDTO(settings: settings),
            runtimeVersion: "ironsmith-macos-v1",
            license: "MIT",
            scannerVersion: "swift-execution-blocklist-v1",
            remixedFromVersionId: nil,
            publishedAt: publishedAt
        )
    }

    private static func transparentIconImage() throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil,
                width: 1024,
                height: 1024,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ToolImageAssetEncodingError.couldNotCreateImage
        }
        context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 128, y: 128, width: 768, height: 768))
        return try #require(context.makeImage())
    }

    private static func versionDownload(
        id: String = "00000000-0000-4000-8000-000000000201",
        versionNumber: Int = 1,
        appId: String = "00000000-0000-4000-8000-000000000101",
        sourceCode: String,
        sourceSha256: String
    ) -> StoreVersionDownload {
        StoreVersionDownload(
            id: id,
            storeId: "00000000-0000-4000-8000-000000000011",
            storeVisibility: "public",
            appId: appId,
            versionNumber: versionNumber,
            sourceSha256: sourceSha256,
            generationSettings: StoreGenerationSettingsDTO(settings: .default),
            runtimeVersion: "ironsmith-macos-v1",
            license: "MIT",
            scannerVersion: "swift-execution-blocklist-v1",
            remixedFromVersionId: nil,
            publishedAt: "2026-06-27T00:00:00.000Z",
            sourceCode: sourceCode
        )
    }

    private enum TestFailure: Error {
        case build
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ironsmith-store-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor StoreListRequestRecorder {
    struct Request: Sendable {
        let scope: StoreAppListScope
        let search: String?
        let cursor: String?
        let sort: StoreAppListSort
        let category: StoreAppCategory?
    }

    private(set) var requests: [Request] = []

    func record(
        scope: StoreAppListScope,
        search: String?,
        cursor: String?,
        sort: StoreAppListSort,
        category: StoreAppCategory?
    ) {
        requests.append(
            Request(
                scope: scope,
                search: search,
                cursor: cursor,
                sort: sort,
                category: category
            )
        )
    }
}
