import Foundation
import SwiftData
import Testing

@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func storePublisherRequestsSignInWithoutShowingGenericError() async {
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies()
        )
        let publisher = ToolLibraryStorePublisher(
            storeClient: .unconfigured,
            iconClient: .noOp
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

        #expect(publisher.pendingSignInToolID == tool.id)
        #expect(publisher.errorMessage == nil)
        #expect(!publisher.isShowingPublishSheet)
    }

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

    @MainActor
    @Test
    func storePublisherSavesMissingDisplayNameOnceBeforePublishing() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileCapture = PublisherProfileCapture()
        let session = Self.ironsmithSession()
        let accountClient = IronsmithAccountClient(
            supabase: nil,
            currentSession: { session },
            validAccessToken: { "access-token" },
            generationAccessToken: { "access-token" },
            signInWithAppleOAuth: { _ in session },
            signOut: {},
            fetchAccountSummary: {
                await profileCapture.summary()
            },
            updateProfile: { update in
                await profileCapture.update(update)
            },
            fetchCreditPacks: { [] },
            createCheckoutSession: { _ in
                throw IronsmithAccountClientError.notConfigured
            },
            deleteAccount: {},
            invokeAPIData: { _, _ in
                throw IronsmithAccountClientError.notConfigured
            }
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(accountClient: accountClient)
        )
        inferenceStore.ironsmithSession = session
        await inferenceStore.refreshIronsmithAccountSummary()
        let publicationCapture = PublisherPublicationCapture()
        let publishedDetail = Self.publisherAppDetail()
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.publishApp = { request in
            await publicationCapture.record(request)
            return publishedDetail
        }
        let publisher = ToolLibraryStorePublisher(
            storeClient: storeClient,
            iconClient: .noOp
        )
        publisher.publishShortDescription = "Clean copied text"
        publisher.publishDescription = "Cleans and reformats text."
        publisher.publishDisplayName = "  Jade Westover  "
        let tool = Tool(
            name: "Clipboard Cleaner",
            executableName: "ClipboardCleaner",
            packageRootPath: root.appendingPathComponent("ClipboardCleaner").path
        )
        try Self.writeSource(Self.publisherSource, to: tool)
        try FileManager.default.createDirectory(
            at: tool.packageLayout.packageMetadataDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: tool.packageLayout.cachedAppIconMasterJPEGURL)
        try Data([2]).write(to: tool.packageLayout.cachedAppIconThumbnailJPEGURL)
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = container.mainContext
        context.insert(tool)
        try context.save()

        await publisher.publish(
            tool,
            modelContext: context,
            inferenceStore: inferenceStore,
            defaultSettings: .default,
            routeStore: IronsmithRouteStore(openSettingsWindow: {})
        )

        let updatedNames = await profileCapture.updatedNames
        let publicationCount = await publicationCapture.count
        let publishedName = await publicationCapture.lastName
        #expect(updatedNames == ["Jade Westover"])
        #expect(publicationCount == 1)
        #expect(publishedName == tool.name)
        #expect(publisher.errorMessage == nil)
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

private actor PublisherProfileCapture {
    private(set) var updatedNames: [String] = []
    private var displayName: String?

    func summary() -> IronsmithAccountSummary {
        IronsmithAccountSummary(
            user: IronsmithAccountUser(
                id: "00000000-0000-4000-8000-000000000001",
                email: "jade@example.com"
            ),
            profile: displayName.map {
                IronsmithAccountProfile(
                    id: "00000000-0000-4000-8000-000000000001",
                    email: "jade@example.com",
                    displayName: $0
                )
            },
            credits: IronsmithCreditSummary(
                userId: "00000000-0000-4000-8000-000000000001",
                balanceCredits: 100
            ),
            recentLedger: []
        )
    }

    func update(_ update: IronsmithAccountProfileUpdate) -> IronsmithAccountProfile {
        let name = update.displayName
        if let name {
            updatedNames.append(name)
        }
        displayName = name
        return IronsmithAccountProfile(
            id: "00000000-0000-4000-8000-000000000001",
            email: "jade@example.com",
            displayName: name
        )
    }
}

private actor PublisherPublicationCapture {
    private(set) var count = 0
    private(set) var lastName: String?

    func record(_ request: StorePublicationRequest) {
        count += 1
        lastName = request.name
    }
}
