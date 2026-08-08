import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ToolLibraryStorePublisher {
    var publishedStoreAppsByID: [String: StoreAppSummary] = [:]
    var publishingToolID: UUID?
    var publishShortDescription = ""
    var publishDescription = ""
    var publishCategory: StoreAppCategory = .utilities
    var publishScreenshotData: Data?
    var publishScreenshotName: String?
    var isShowingPublishSheet = false
    var isPublishing = false
    var errorMessage: String?
    var pendingSignInToolID: UUID?
    var pendingCreatorProfileToolID: UUID?
    var creatorDisplayName = ""
    var creatorHandle = ""
    var isShowingCreatorProfileSheet = false
    var isSavingCreatorProfile = false

    @ObservationIgnored private let storeClient: IronsmithStoreClient
    @ObservationIgnored private let iconClient: ToolIconClient
    @ObservationIgnored private let buildClient: ToolBuildClient
    @ObservationIgnored private let saveModelContext: (ModelContext) throws -> Void
    @ObservationIgnored private var currentPublishedSourceSha256: String?

    init() {
        self.storeClient = .live
        self.iconClient = .live()
        self.buildClient = .live()
        self.saveModelContext = { try $0.save() }
    }

    init(
        storeClient: IronsmithStoreClient,
        iconClient: ToolIconClient,
        buildClient: ToolBuildClient? = nil,
        saveModelContext: ((ModelContext) throws -> Void)? = nil
    ) {
        self.storeClient = storeClient
        self.iconClient = iconClient
        self.buildClient = buildClient ?? .live()
        self.saveModelContext = saveModelContext ?? { try $0.save() }
    }

    func canUpdateStoreVersion(for tool: Tool) -> Bool {
        guard let storeAppId = tool.storeAppId else { return false }
        return publishedStoreAppsByID[storeAppId] != nil
    }

    func refreshPublishedStoreApps(
        isSignedIn: Bool,
        tools: [Tool]
    ) async {
        guard isSignedIn else {
            publishedStoreAppsByID = [:]
            return
        }
        let storeIDs = Set(
            tools.compactMap { tool -> String? in
                guard tool.storeAppId != nil else { return nil }
                return tool.storeId
            }
        )
        guard !storeIDs.isEmpty else {
            publishedStoreAppsByID = [:]
            return
        }

        do {
            let linkedAppIDs = Set(tools.compactMap(\.storeAppId))
            var ownedAppsByID: [String: StoreAppSummary] = [:]
            for storeID in storeIDs {
                var offset = 0
                var hasMore: Bool
                repeat {
                    let page = try await storeClient.listApps(
                        storeID,
                        .mine,
                        nil,
                        offset,
                        .recent,
                        nil,
                        nil
                    )
                    for app in page.apps {
                        guard linkedAppIDs.contains(app.id) else { continue }
                        ownedAppsByID[app.id] = app
                    }
                    offset += page.apps.count
                    hasMore = page.hasMore
                } while hasMore
            }
            publishedStoreAppsByID = ownedAppsByID
        } catch {
            publishedStoreAppsByID = [:]
        }
    }

    func hasCompleteCreatorProfile(inferenceStore: InferenceStore) -> Bool {
        let profile = inferenceStore.ironsmithAccountSummary?.profile
        return !(profile?.displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(profile?.handle ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginPublishing(
        _ tool: Tool,
        inferenceStore: InferenceStore,
        tools: [Tool]
    ) async {
        errorMessage = nil
        await inferenceStore.refreshIronsmithAccountSummary()
        guard inferenceStore.ironsmithSession != nil else {
            pendingSignInToolID = tool.id
            return
        }
        pendingSignInToolID = nil
        guard hasCompleteCreatorProfile(inferenceStore: inferenceStore) else {
            pendingCreatorProfileToolID = tool.id
            creatorDisplayName = inferenceStore.ironsmithAccountSummary?.profile?.displayName ?? ""
            creatorHandle = inferenceStore.ironsmithAccountSummary?.profile?.handle ?? ""
            isShowingCreatorProfileSheet = true
            return
        }
        pendingCreatorProfileToolID = nil
        await refreshPublishedStoreApps(
            isSignedIn: true,
            tools: tools
        )
        let linkedApp = linkedPublishedApp(for: tool)
        if let linkedApp {
            do {
                // May consider adding the latest source hash to the StoreAppSummary so we don't have to fetch the detail here, but this is fine for now.
                let detail = try await storeClient.fetchApp(linkedApp.storeId, linkedApp.id)
                let source = try sourceCode(for: tool)
                if IronsmithStoreClient.sha256Hex(for: source)
                    == detail.currentVersion.sourceSha256.lowercased()
                {
                    throw IronsmithStoreClientError.unchangedStoreVersion
                }
                publishShortDescription = detail.shortDescription
                publishDescription = detail.description
                publishCategory = detail.category
                currentPublishedSourceSha256 = detail.currentVersion.sourceSha256.lowercased()
            } catch {
                present(error)
                return
            }
        } else {
            publishShortDescription = ""
            publishDescription = ""
            publishCategory = tool.category
            currentPublishedSourceSha256 = nil
        }
        publishingToolID = tool.id
        publishScreenshotData = nil
        publishScreenshotName = nil
        isShowingPublishSheet = true
    }

    func publish(
        _ tool: Tool,
        modelContext: ModelContext,
        inferenceStore: InferenceStore,
        defaultSettings: ToolGenerationSettings,
        routeStore: IronsmithRouteStore
    ) async {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            let source = try sourceCode(for: tool)
            if linkedPublishedApp(for: tool) != nil,
                let currentPublishedSourceSha256,
                IronsmithStoreClient.sha256Hex(for: source) == currentPublishedSourceSha256
            {
                throw IronsmithStoreClientError.unchangedStoreVersion
            }
            let settings = tool.generationSettings(defaults: defaultSettings)
            _ = try await iconClient.ensureIconAssets(
                ToolIconRequest(displayName: tool.name, layout: tool.packageLayout)
            )
            let iconMasterJPEG = try Data(
                contentsOf: tool.packageLayout.cachedAppIconMasterJPEGURL
            )
            let iconThumbnailJPEG = try Data(
                contentsOf: tool.packageLayout.cachedAppIconThumbnailJPEGURL
            )
            let app: StoreAppDetail
            let linkedApp = linkedPublishedApp(for: tool)
            if let linkedApp {
                let remixedFromVersionId =
                    tool.storeRemixedFromVersionId == tool.storeVersionId
                    ? nil
                    : tool.storeRemixedFromVersionId
                app = try await storeClient.publishVersion(
                    StoreVersionPublicationRequest(
                        storeId: linkedApp.storeId,
                        appId: linkedApp.id,
                        shortDescription: publishShortDescription.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        description: publishDescription.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        sourceCode: source,
                        generationSettings: settings,
                        iconMasterJPEG: iconMasterJPEG,
                        iconThumbnailJPEG: iconThumbnailJPEG,
                        screenshotJPEGs: publishScreenshotData.map { [$0] } ?? [],
                        replaceScreenshots: publishScreenshotData != nil,
                        remixedFromVersionId: remixedFromVersionId
                    )
                )
            } else {
                app = try await storeClient.publishApp(
                    StorePublicationRequest(
                        storeId: tool.storeId ?? IronsmithStoreConstants.communityStoreId,
                        name: tool.name,
                        shortDescription: publishShortDescription.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        description: publishDescription.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        category: publishCategory,
                        sourceCode: source,
                        generationSettings: settings,
                        iconMasterJPEG: iconMasterJPEG,
                        iconThumbnailJPEG: iconThumbnailJPEG,
                        screenshotJPEGs: publishScreenshotData.map { [$0] } ?? [],
                        remixedFromVersionId: tool.storeRemixedFromVersionId
                    )
                )
            }

            await finishSuccessfulPublication(
                app,
                for: tool,
                localRemixedFromVersionId: linkedApp == nil
                    ? app.currentVersion.id
                    : app.currentVersion.remixedFromVersionId,
                modelContext: modelContext,
                routeStore: routeStore
            )
        } catch {
            modelContext.rollback()
            present(error)
        }
    }

    func saveCreatorProfile(
        inferenceStore: InferenceStore,
        tools: [Tool]
    ) async {
        guard !isSavingCreatorProfile else { return }
        let displayName = creatorDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = IronsmithCreatorHandle.normalized(creatorHandle)
        guard (1...80).contains(displayName.count) else {
            present(ToolLibraryStorePublishingError.invalidDisplayName)
            return
        }
        guard ToolLibraryCreatorProfileSheetView.isValidHandle(handle) else {
            present(ToolLibraryStorePublishingError.invalidHandle)
            return
        }
        isSavingCreatorProfile = true
        defer { isSavingCreatorProfile = false }
        do {
            _ = try await inferenceStore.updateIronsmithAccountProfile(
                IronsmithAccountProfileUpdate(displayName: displayName, handle: handle)
            )
            isShowingCreatorProfileSheet = false
            guard let toolID = pendingCreatorProfileToolID,
                let tool = tools.first(where: { $0.id == toolID })
            else { return }
            pendingCreatorProfileToolID = nil
            await beginPublishing(tool, inferenceStore: inferenceStore, tools: tools)
        } catch {
            present(error)
        }
    }

    func importScreenshot(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let source = try Data(contentsOf: url)
            let screenshot = try ToolImageAssetEncoder.screenshot(from: source)
            publishScreenshotData = screenshot.data
            publishScreenshotName =
                url.deletingPathExtension().lastPathComponent + ".jpg"
        } catch {
            present(error)
        }
    }

    private func linkedPublishedApp(for tool: Tool) -> StoreAppSummary? {
        guard let storeAppId = tool.storeAppId else { return nil }
        return publishedStoreAppsByID[storeAppId]
    }

    private func sourceCode(for tool: Tool) throws -> String {
        try String(
            contentsOf: try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath),
            encoding: .utf8
        )
    }

    private func applyPublishedStoreLinkage(
        _ app: StoreAppDetail,
        to tool: Tool,
        localRemixedFromVersionId: String?
    ) {
        tool.storeId = app.storeId
        tool.storeAppId = app.id
        tool.category = app.category
        tool.storeVersionId = app.currentVersion.id
        tool.storeVersionNumber = app.currentVersion.versionNumber
        tool.storeSourceSha256 = app.currentVersion.sourceSha256
        tool.storeImportedAt = Date()
        tool.storeRemixedFromVersionId = localRemixedFromVersionId
        tool.updatedAt = Date()
    }

    private func finishSuccessfulPublication(
        _ app: StoreAppDetail,
        for tool: Tool,
        localRemixedFromVersionId: String?,
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore
    ) async {
        applyPublishedStoreLinkage(
            app,
            to: tool,
            localRemixedFromVersionId: localRemixedFromVersionId
        )

        let persistenceError: Error?
        do {
            try saveModelContext(modelContext)
            persistenceError = nil
        } catch {
            persistenceError = error
        }

        let rebuildError: Error?
        do {
            try await buildClient.buildTool(tool)
            rebuildError = nil
        } catch {
            rebuildError = error
        }

        publishedStoreAppsByID[app.id] = StoreAppSummary(detail: app)
        isShowingPublishSheet = false
        routeStore.open(.store(.publishedApp(app.id)))

        if let warning = ToolLibraryStorePublishingError.localFinalizationWarning(
            persistenceError: persistenceError,
            rebuildError: rebuildError
        ) {
            present(warning)
        }
    }

    private func present(_ error: Error) {
        errorMessage =
            IronsmithErrorPresentation.message(for: error)
            ?? error.localizedDescription
    }
}

private enum ToolLibraryStorePublishingError: LocalizedError {
    case invalidDisplayName
    case invalidHandle
    case localFinalizationFailed(String)

    static func localFinalizationWarning(
        persistenceError: Error?,
        rebuildError: Error?
    ) -> Self? {
        var details: [String] = []
        if let persistenceError {
            details.append(
                "Ironsmith could not save the Store linkage locally: \(persistenceError.localizedDescription)"
            )
        }
        if let rebuildError {
            details.append(
                "Ironsmith could not rebuild the local app with its updated Store metadata: \(rebuildError.localizedDescription)"
            )
        }
        guard !details.isEmpty else { return nil }
        return .localFinalizationFailed(details.joined(separator: " "))
    }

    var errorDescription: String? {
        switch self {
        case .invalidDisplayName:
            "Enter a display name between 1 and 80 characters."
        case .invalidHandle:
            "Enter a handle using 3–30 letters, numbers, or underscores that begins and ends with a letter or number."
        case .localFinalizationFailed(let detail):
            """
            This app was published successfully, but Ironsmith could not finish updating its \
            local state. \(detail)
            """
        }
    }
}
