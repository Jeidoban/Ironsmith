import Foundation
import Testing

@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func storePublisherLeavesNewListingCopyEmpty() async {
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()
        let publisher = ToolLibraryStorePublisher(
            storeClient: .unconfigured,
            iconClient: .live()
        )
        let tool = Tool(
            name: "Clipboard Cleaner",
            packageRootPath: "/tmp/ClipboardCleaner"
        )

        await publisher.beginPublishing(
            tool,
            inferenceStore: inferenceStore,
            tools: [tool]
        )

        #expect(publisher.publishName == tool.name)
        #expect(publisher.publishShortDescription.isEmpty)
        #expect(publisher.publishDescription.isEmpty)
        #expect(publisher.isShowingPublishSheet)
    }

    @MainActor
    @Test
    func storePublisherPrefillsDescriptionsForVersionUpdates() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let detail = Self.publisherAppDetail()
        var client = IronsmithStoreClient.unconfigured
        client.listApps = { _, _, _, _, _, _ in
            StoreAppPage(apps: [StoreAppSummary(detail: detail)], hasMore: false)
        }
        client.fetchApp = { _, _ in detail }
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()
        let publisher = ToolLibraryStorePublisher(
            storeClient: client,
            iconClient: .live()
        )
        let tool = Tool(
            name: "Clipboard Cleaner",
            executableName: "ClipboardCleaner",
            packageRootPath: root.path
        )
        tool.storeId = detail.storeId
        tool.storeAppId = detail.id
        try Self.writeSource(
            Self.publisherSource.replacingOccurrences(of: "Published", with: "Changed"),
            to: tool
        )

        await publisher.beginPublishing(
            tool,
            inferenceStore: inferenceStore,
            tools: [tool]
        )

        #expect(publisher.publishShortDescription == detail.shortDescription)
        #expect(publisher.publishDescription == detail.description)
        #expect(publisher.isShowingPublishSheet)
    }

    @MainActor
    @Test
    func storePublisherRejectsUnchangedVersionWhenUpdateBegins() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let detail = Self.publisherAppDetail()
        var client = IronsmithStoreClient.unconfigured
        client.listApps = { _, _, _, _, _, _ in
            StoreAppPage(apps: [StoreAppSummary(detail: detail)], hasMore: false)
        }
        client.fetchApp = { _, _ in detail }
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()
        let publisher = ToolLibraryStorePublisher(
            storeClient: client,
            iconClient: .live()
        )
        let tool = Tool(
            name: "Clipboard Cleaner",
            executableName: "ClipboardCleaner",
            packageRootPath: root.path
        )
        tool.storeId = detail.storeId
        tool.storeAppId = detail.id
        try Self.writeSource(Self.publisherSource, to: tool)

        await publisher.beginPublishing(
            tool,
            inferenceStore: inferenceStore,
            tools: [tool]
        )

        #expect(publisher.errorMessage?.contains("currently published version") == true)
        #expect(!publisher.isShowingPublishSheet)
    }

    private static let publisherSource = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { Text("Published") }
        }
        """

    private static func writeSource(_ source: String, to tool: Tool) throws {
        let sourceURL = try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    private static func publisherAppDetail() -> StoreAppDetail {
        let appID = "00000000-0000-4000-8000-000000000101"
        let version = StoreVersionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            appId: appID,
            versionNumber: 1,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: publisherSource),
            generationSettings: StoreGenerationSettingsDTO(settings: .default),
            runtimeVersion: "ironsmith-macos-v1",
            license: "MIT",
            scannerVersion: "swift-execution-blocklist-v1",
            remixedFromVersionId: nil,
            publishedAt: "2026-07-28T00:00:00.000Z"
        )
        return StoreAppDetail(
            id: appID,
            storeId: IronsmithStoreConstants.communityStoreId,
            storeVisibility: "public",
            authorDisplayName: "Jade",
            name: "Clipboard Cleaner",
            shortDescription: "Clean copied text",
            description: "Cleans and reformats text from the clipboard.",
            category: .utilities,
            status: .published,
            publishedAt: "2026-07-28T00:00:00.000Z",
            createdAt: "2026-07-28T00:00:00.000Z",
            updatedAt: "2026-07-28T00:00:00.000Z",
            icon: nil,
            iconMaster: nil,
            screenshots: [],
            currentVersion: version,
            versions: [version],
            remix: nil
        )
    }
}
