import CoreGraphics
import Foundation
import ImageIO
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
        tool.storeVersionNumber = 1
        try Self.writeSource(Self.publisherSource, to: tool)

        await publisher.beginPublishing(
            tool,
            inferenceStore: inferenceStore,
            tools: [tool]
        )

        #expect(publisher.errorMessage?.contains("currently published version") == true)
        #expect(tool.storeVersionNumber == 1)
        #expect(!publisher.isShowingPublishSheet)
    }

    @MainActor
    @Test
    func storePublisherCompletesCreatorProfileBeforePublishing() async throws {
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
            checkHandleAvailability: {
                IronsmithHandleAvailability(handle: $0, available: true)
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
        let buildCapture = PublisherBuildCapture()
        let publisher = ToolLibraryStorePublisher(
            storeClient: storeClient,
            iconClient: .noOp,
            buildClient: ToolBuildClient { tool in
                await buildCapture.record(
                    category: tool.category,
                    versionNumber: tool.appVersionNumber
                )
            }
        )
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

        await publisher.beginPublishing(tool, inferenceStore: inferenceStore, tools: [tool])
        #expect(publisher.isShowingCreatorProfileSheet)
        publisher.creatorDisplayName = "  Jade Westover  "
        publisher.creatorHandle = "jade_w"
        await publisher.saveCreatorProfile(inferenceStore: inferenceStore, tools: [tool])
        publisher.publishShortDescription = "Clean copied text"
        publisher.publishDescription = "Cleans and reformats text."

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
        #expect(tool.storeVersionNumber == 1)
        #expect(await buildCapture.versionNumbers == [1])
        #expect(publisher.errorMessage == nil)
    }

    @MainActor
    @Test
    func storePublisherUpgradesLegacyIconAssetsBeforePublishing() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let publishedDetail = Self.publisherAppDetail()
        let publicationCapture = PublisherPublicationCapture()
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.publishApp = { request in
            _ = try ToolImageAssetEncoder.validateIconMasterJPEG(request.iconMasterJPEG)
            _ = try ToolImageAssetEncoder.validateIconThumbnailJPEG(
                request.iconThumbnailJPEG
            )
            await publicationCapture.record(request)
            return publishedDetail
        }
        let publisher = ToolLibraryStorePublisher(
            storeClient: storeClient,
            iconClient: .cachedOnly(),
            buildClient: ToolBuildClient { _ in }
        )
        publisher.publishShortDescription = "Clean copied text"
        publisher.publishDescription = "Cleans and reformats text."
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
        try Self.publisherLegacyIconPNG().write(
            to: tool.packageLayout.cachedAppIconPNGURL,
            options: .atomic
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = container.mainContext
        context.insert(tool)
        try context.save()
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()

        await publisher.publish(
            tool,
            modelContext: context,
            inferenceStore: inferenceStore,
            defaultSettings: .default,
            routeStore: IronsmithRouteStore(openSettingsWindow: {})
        )

        let publicationCount = await publicationCapture.count
        #expect(publicationCount == 1)
        #expect(publisher.errorMessage == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: tool.packageLayout.cachedAppIconMasterJPEGURL.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: tool.packageLayout.cachedAppIconThumbnailJPEGURL.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: tool.packageLayout.cachedAppIconICNSURL.path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: tool.packageLayout.cachedAppIconPNGURL.path
            )
        )
    }

    @MainActor
    @Test
    func successfulVersionPublicationPersistsReturnedCategoryAndRebuildsAtReturnedVersion()
        async throws
    {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let changedSource = Self.publisherSource.replacingOccurrences(
            of: "Published",
            with: "Version Two"
        )
        let previousDetail = Self.publisherAppDetail()
        let publishedDetail = Self.publisherAppDetail(
            versionNumber: 2,
            category: .finance,
            source: changedSource
        )
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.publishVersion = { _ in publishedDetail }
        let buildCapture = PublisherBuildCapture()
        let publisher = ToolLibraryStorePublisher(
            storeClient: storeClient,
            iconClient: .noOp,
            buildClient: ToolBuildClient { tool in
                await buildCapture.record(
                    category: tool.category,
                    versionNumber: tool.appVersionNumber
                )
            }
        )
        publisher.publishedStoreAppsByID[previousDetail.id] = StoreAppSummary(
            detail: previousDetail
        )
        publisher.publishShortDescription = "Clean copied text"
        publisher.publishDescription = "Cleans and reformats text."
        let tool = Tool(
            name: "Clipboard Cleaner",
            executableName: "ClipboardCleaner",
            category: .utilities,
            packageRootPath: root.appendingPathComponent("ClipboardCleaner").path,
            storeId: previousDetail.storeId,
            storeAppId: previousDetail.id,
            storeVersionId: previousDetail.currentVersion.id,
            storeVersionNumber: 1
        )
        try Self.writeSource(changedSource, to: tool)
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
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()

        await publisher.publish(
            tool,
            modelContext: context,
            inferenceStore: inferenceStore,
            defaultSettings: .default,
            routeStore: IronsmithRouteStore(openSettingsWindow: {})
        )

        #expect(tool.category == .finance)
        #expect(tool.storeVersionId == publishedDetail.currentVersion.id)
        #expect(tool.storeVersionNumber == 2)
        #expect(await buildCapture.categories == [.finance])
        #expect(await buildCapture.versionNumbers == [2])
        #expect(publisher.errorMessage == nil)
        #expect(!publisher.isShowingPublishSheet)
    }

    @MainActor
    @Test
    func localPersistenceFailureStillRetainsSuccessfulStorePublication() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let publishedDetail = Self.publisherAppDetail(category: .productivity)
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.publishApp = { _ in publishedDetail }
        let buildCapture = PublisherBuildCapture()
        let publisher = ToolLibraryStorePublisher(
            storeClient: storeClient,
            iconClient: .noOp,
            buildClient: ToolBuildClient { tool in
                await buildCapture.record(
                    category: tool.category,
                    versionNumber: tool.appVersionNumber
                )
            },
            saveModelContext: { _ in
                throw PublisherPersistenceError.failed
            }
        )
        publisher.publishShortDescription = "Clean copied text"
        publisher.publishDescription = "Cleans and reformats text."
        publisher.isShowingPublishSheet = true
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
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()

        await publisher.publish(
            tool,
            modelContext: context,
            inferenceStore: inferenceStore,
            defaultSettings: .default,
            routeStore: IronsmithRouteStore(openSettingsWindow: {})
        )

        #expect(tool.storeAppId == publishedDetail.id)
        #expect(tool.storeVersionId == publishedDetail.currentVersion.id)
        #expect(tool.category == .productivity)
        #expect(publisher.publishedStoreAppsByID[publishedDetail.id]?.id == publishedDetail.id)
        #expect(publisher.canUpdateStoreVersion(for: tool))
        #expect(await buildCapture.versionNumbers == [1])
        #expect(publisher.errorMessage?.contains("published successfully") == true)
        #expect(publisher.errorMessage?.contains("save the Store linkage") == true)
        #expect(!publisher.isShowingPublishSheet)
    }

    @MainActor
    @Test
    func localRebuildFailurePreservesSuccessfulVersionPublicationAndShowsWarning() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let changedSource = Self.publisherSource.replacingOccurrences(
            of: "Published",
            with: "Version Two"
        )
        let previousDetail = Self.publisherAppDetail()
        let publishedDetail = Self.publisherAppDetail(
            versionNumber: 2,
            category: .music,
            source: changedSource
        )
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.publishVersion = { _ in publishedDetail }
        let publisher = ToolLibraryStorePublisher(
            storeClient: storeClient,
            iconClient: .noOp,
            buildClient: ToolBuildClient { _ in
                throw PublisherBuildError.failed
            }
        )
        publisher.publishedStoreAppsByID[previousDetail.id] = StoreAppSummary(
            detail: previousDetail
        )
        publisher.publishShortDescription = "Clean copied text"
        publisher.publishDescription = "Cleans and reformats text."
        publisher.isShowingPublishSheet = true
        let tool = Tool(
            name: "Clipboard Cleaner",
            executableName: "ClipboardCleaner",
            packageRootPath: root.appendingPathComponent("ClipboardCleaner").path,
            storeId: previousDetail.storeId,
            storeAppId: previousDetail.id,
            storeVersionId: previousDetail.currentVersion.id,
            storeVersionNumber: 1
        )
        try Self.writeSource(changedSource, to: tool)
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
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()

        await publisher.publish(
            tool,
            modelContext: context,
            inferenceStore: inferenceStore,
            defaultSettings: .default,
            routeStore: IronsmithRouteStore(openSettingsWindow: {})
        )

        #expect(tool.category == .music)
        #expect(tool.storeVersionId == publishedDetail.currentVersion.id)
        #expect(tool.storeVersionNumber == 2)
        #expect(publisher.errorMessage?.contains("published successfully") == true)
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

    private static func publisherLegacyIconPNG() throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: 1024,
                height: 1024,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data,
                "public.png" as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func publisherAppDetail(
        versionNumber: Int = 1,
        category: StoreAppCategory = .utilities,
        source: String = publisherSource
    ) -> StoreAppDetail {
        let appID = "00000000-0000-4000-8000-000000000101"
        let version = StoreVersionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            appId: appID,
            versionNumber: versionNumber,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: source),
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
            authorHandle: "jade",
            name: "Clipboard Cleaner",
            shortDescription: "Clean copied text",
            description: "Cleans and reformats text from the clipboard.",
            category: category,
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
    private var handle: String?

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
                    displayName: $0,
                    handle: handle
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
        if let updatedHandle = update.handle {
            handle = updatedHandle
        }
        return IronsmithAccountProfile(
            id: "00000000-0000-4000-8000-000000000001",
            email: "jade@example.com",
            displayName: name,
            handle: handle
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

private actor PublisherBuildCapture {
    private(set) var categories: [StoreAppCategory] = []
    private(set) var versionNumbers: [Int] = []

    func record(category: StoreAppCategory, versionNumber: Int) {
        categories.append(category)
        versionNumbers.append(versionNumber)
    }
}

private enum PublisherBuildError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The test bundle could not be rebuilt."
    }
}

private enum PublisherPersistenceError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The test Store linkage could not be saved."
    }
}
