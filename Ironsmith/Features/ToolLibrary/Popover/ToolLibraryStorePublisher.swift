import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ToolLibraryStorePublisher {
    var publishedStoreAppsByID: [String: StoreAppListing] = [:]
    var publishingToolID: UUID?
    var publishName = ""
    var publishDescription = ""
    var publishDisplayName = ""
    var publishScreenshotData: Data?
    var publishScreenshotName: String?
    var isShowingPublishSheet = false
    var isPublishing = false
    var errorMessage: String?

    @ObservationIgnored private let storeClient: IronsmithStoreClient
    @ObservationIgnored private let iconClient: ToolIconClient

    init() {
        self.storeClient = .live
        self.iconClient = .live()
    }

    init(
        storeClient: IronsmithStoreClient,
        iconClient: ToolIconClient
    ) {
        self.storeClient = storeClient
        self.iconClient = iconClient
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
            var ownedAppsByID: [String: StoreAppListing] = [:]
            for storeID in storeIDs {
                var cursor: String?
                repeat {
                    let page = try await storeClient.listApps(storeID, .mine, nil, cursor)
                    for app in page.apps {
                        ownedAppsByID[app.id] = app
                    }
                    cursor = page.nextCursor
                } while cursor != nil
            }
            publishedStoreAppsByID = ownedAppsByID
        } catch {
            publishedStoreAppsByID = [:]
        }
    }

    func needsDisplayName(inferenceStore: InferenceStore) -> Bool {
        (inferenceStore.ironsmithAccountSummary?.profile?.displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    func beginPublishing(
        _ tool: Tool,
        inferenceStore: InferenceStore,
        tools: [Tool]
    ) async {
        await inferenceStore.refreshIronsmithAccountSummary()
        guard inferenceStore.ironsmithSession != nil else {
            errorMessage = "Sign in with Ironsmith before publishing to the App Store."
            return
        }
        await refreshPublishedStoreApps(
            isSignedIn: true,
            tools: tools
        )
        publishingToolID = tool.id
        publishName = tool.name
        publishDescription = linkedPublishedApp(for: tool)?.description ?? "Created with Ironsmith."
        publishDisplayName = inferenceStore.ironsmithAccountSummary?.profile?.displayName ?? ""
        publishScreenshotData = nil
        publishScreenshotName = nil
        isShowingPublishSheet = true
    }

    func saveDisplayName(inferenceStore: InferenceStore) async {
        let trimmed = publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let profile = try await inferenceStore.updateIronsmithAccountProfile(
                IronsmithAccountProfileUpdate(displayName: trimmed)
            )
            publishDisplayName = profile.displayName ?? trimmed
        } catch {
            present(error)
        }
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
            if needsDisplayName(inferenceStore: inferenceStore) {
                _ = try await inferenceStore.updateIronsmithAccountProfile(
                    IronsmithAccountProfileUpdate(
                        displayName: publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }

            let source = try String(
                contentsOf: try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath),
                encoding: .utf8
            )
            let settings = tool.generationSettings(defaults: defaultSettings)
            let app: StoreAppListing
            if let linkedApp = linkedPublishedApp(for: tool) {
                app = try await storeClient.publishVersion(
                    StoreVersionPublicationRequest(
                        storeId: linkedApp.storeId,
                        appId: linkedApp.id,
                        sourceCode: source,
                        generationSettings: settings,
                        iconPNG: nil,
                        screenshotPNGs: publishScreenshotData.map { [$0] } ?? [],
                        replaceScreenshots: publishScreenshotData != nil,
                        remixedFromVersionId: tool.storeRemixedFromVersionId
                    )
                )
            } else {
                _ = try await iconClient.ensureIconAssets(
                    ToolIconRequest(displayName: tool.name, layout: tool.packageLayout)
                )
                let iconPNG = try Data(contentsOf: tool.packageLayout.cachedAppIconPNGURL)
                app = try await storeClient.publishApp(
                    StorePublicationRequest(
                        storeId: tool.storeId ?? IronsmithStoreConstants.communityStoreId,
                        name: publishName.trimmingCharacters(in: .whitespacesAndNewlines),
                        description: publishDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                        sourceCode: source,
                        generationSettings: settings,
                        iconPNG: iconPNG,
                        screenshotPNGs: publishScreenshotData.map { [$0] } ?? [],
                        remixedFromVersionId: tool.storeRemixedFromVersionId
                    )
                )
            }

            applyPublishedStoreLinkage(app, to: tool)
            try modelContext.save()
            publishedStoreAppsByID[app.id] = app
            isShowingPublishSheet = false
            routeStore.open(.store(.publishedApp(app.id)))
        } catch {
            modelContext.rollback()
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
            publishScreenshotData = try Data(contentsOf: url)
            publishScreenshotName = url.lastPathComponent
        } catch {
            present(error)
        }
    }

    private func linkedPublishedApp(for tool: Tool) -> StoreAppListing? {
        guard let storeAppId = tool.storeAppId else { return nil }
        return publishedStoreAppsByID[storeAppId]
    }

    private func applyPublishedStoreLinkage(_ app: StoreAppListing, to tool: Tool) {
        tool.storeId = app.storeId
        tool.storeAppId = app.id
        tool.storeVersionId = app.currentVersion.id
        tool.storeVersionNumber = app.currentVersion.versionNumber
        tool.storeSourceSha256 = app.currentVersion.sourceSha256
        tool.storeImportedAt = Date()
        tool.storeRemixedFromVersionId = app.currentVersion.remixedFromVersionId
        tool.updatedAt = Date()
    }

    private func present(_ error: Error) {
        errorMessage = IronsmithErrorPresentation.message(for: error)
            ?? error.localizedDescription
    }
}
