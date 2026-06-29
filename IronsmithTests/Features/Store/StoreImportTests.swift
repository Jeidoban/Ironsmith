import Foundation
import SwiftData
import Testing
@testable import Ironsmith

struct StoreImportTests {
    @MainActor
    @Test
    func storeSourceHashVerificationRejectsTamperedDownloads() throws {
        let version = Self.versionDownload(
            sourceCode: "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"bad\") } }",
            sourceSha256: String(repeating: "0", count: 64)
        )

        #expect(throws: IronsmithStoreClientError.sourceHashMismatch(expected: version.sourceSha256, actual: IronsmithStoreClient.sha256Hex(for: version.sourceCode))) {
            try IronsmithStoreClient.verifySourceHash(version)
        }
    }

    @MainActor
    @Test
    func getImportCreatesReadyLinkedLocalTool() async throws {
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
        let sourceOnDisk = try String(contentsOf: try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath), encoding: .utf8)
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
        #expect(tool.storeRemixedFromVersionId == nil)
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
        #expect(result.tool.storeAppId == nil)
        #expect(result.tool.storeVersionId == nil)
        #expect(result.tool.storeVersionNumber == nil)
        #expect(result.tool.storeSourceSha256 == version.sourceSha256)
        #expect(result.tool.storeRemixedFromVersionId == version.id)
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

    private static func appListing(sourceCode: String) -> StoreAppListing {
        let storeId = "00000000-0000-4000-8000-000000000011"
        let appId = "00000000-0000-4000-8000-000000000101"
        return StoreAppListing(
            id: appId,
            storeId: storeId,
            storeVisibility: "public",
            authorDisplayName: "Jade",
            name: "Clipboard Cleaner",
            description: "Cleans clipboard text.",
            status: .published,
            publishedAt: "2026-06-27T00:00:00.000Z",
            createdAt: "2026-06-27T00:00:00.000Z",
            updatedAt: "2026-06-27T00:00:00.000Z",
            assets: [],
            currentVersion: StoreVersionMetadata(
                id: "00000000-0000-4000-8000-000000000201",
                storeId: storeId,
                storeVisibility: "public",
                appId: appId,
                versionNumber: 1,
                sourceSha256: IronsmithStoreClient.sha256Hex(for: sourceCode),
                generationSettings: StoreGenerationSettingsDTO(settings: .default),
                runtimeVersion: "ironsmith-macos-v1",
                license: "MIT",
                scannerVersion: "swift-execution-blocklist-v1",
                remixedFromVersionId: nil,
                publishedAt: "2026-06-27T00:00:00.000Z"
            ),
            remix: nil
        )
    }

    private static func versionDownload(
        appId: String = "00000000-0000-4000-8000-000000000101",
        sourceCode: String,
        sourceSha256: String
    ) -> StoreVersionDownload {
        StoreVersionDownload(
            id: "00000000-0000-4000-8000-000000000201",
            storeId: "00000000-0000-4000-8000-000000000011",
            storeVisibility: "public",
            appId: appId,
            versionNumber: 1,
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

    private static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ironsmith-store-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
