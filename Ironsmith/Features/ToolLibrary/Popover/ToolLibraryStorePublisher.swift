import Foundation
import Observation
import Auth
import SwiftData

@MainActor
@Observable
final class ToolLibraryStorePublisher {
    var publishingToolID: UUID?
    var publishShortDescription = ""
    var publishDescription = ""
    var publishCategory: StoreAppCategory = .utilities
    var publishLicense: StoreLicenseIdentifier = .mit
    var publishScreenshotData: Data?
    var publishScreenshotName: String?
    var publishIconPreviewData: Data?
    var publishInheritedLegalAttributions: [StoreLegalAttribution] = []
    var originalRemixApp: StoreAppDetail?
    var isShowingPublishSheet = false
    var isPublishing = false
    var isUpdatingPublishedListing = false
    var errorMessage: String?
    var pendingSignInToolID: UUID?
    var pendingCreatorProfileToolID: UUID?
    var creatorDisplayName = ""
    var creatorHandle = ""
    var isShowingCreatorProfileSheet = false
    var isSavingCreatorProfile = false
    private(set) var storeSourceChangesByToolID: [UUID: Bool] = [:]

    @ObservationIgnored private let storeClient: IronsmithStoreClient
    @ObservationIgnored private let iconClient: ToolIconClient
    @ObservationIgnored private let originalIconDataLoader: @Sendable (URL) async throws -> Data
    @ObservationIgnored private let buildClient: ToolBuildClient
    @ObservationIgnored private let saveModelContext: (ModelContext) throws -> Void
    @ObservationIgnored private var currentPublishedSourceSha256: String?
    @ObservationIgnored private var originalRemixIconData: Data?

    init() {
        self.storeClient = .live
        self.iconClient = .live()
        self.originalIconDataLoader = { try await StoreToolImportClient.downloadImage(from: $0) }
        self.buildClient = .live()
        self.saveModelContext = { try $0.save() }
    }

    init(
        storeClient: IronsmithStoreClient,
        iconClient: ToolIconClient,
        originalIconDataLoader: (@Sendable (URL) async throws -> Data)? = nil,
        buildClient: ToolBuildClient? = nil,
        saveModelContext: ((ModelContext) throws -> Void)? = nil
    ) {
        self.storeClient = storeClient
        self.iconClient = iconClient
        self.originalIconDataLoader =
            originalIconDataLoader ?? {
                try await StoreToolImportClient.downloadImage(from: $0)
            }
        self.buildClient = buildClient ?? .live()
        self.saveModelContext = saveModelContext ?? { try $0.save() }
    }

    func canUpdateStoreVersion(for tool: Tool, userID: String?) -> Bool {
        guard let userID else { return false }
        return tool.storePublication?.ownerUserId == userID
    }

    func hasStoreSourceChanges(for tool: Tool, userID: String? = nil) -> Bool {
        if let publication = tool.storePublication,
            publication.ownerUserId != userID
        {
            return true
        }
        return storeSourceChangesByToolID[tool.id] ?? (tool.storeBaselineSourceSha256 == nil)
    }

    func publishNameMatchesOriginal(for tool: Tool) -> Bool {
        guard let originalRemixApp else { return false }
        return StoreAppNameComparison.matches(tool.name, originalRemixApp.name)
    }

    var isUsingOriginalRemixIcon: Bool {
        guard let originalRemixIconData, let publishIconPreviewData else { return false }
        return originalRemixIconData == publishIconPreviewData
    }

    func canPublishRemixIdentity(for tool: Tool) -> Bool {
        originalRemixApp == nil || !publishNameMatchesOriginal(for: tool)
    }

    func refreshPublishIdentity(for tool: Tool) {
        publishIconPreviewData = try? Data(contentsOf: tool.packageLayout.cachedAppIconPreviewURL)
    }

    func refreshStoreSourceChanges(for tools: [Tool]) async {
        let inputs = tools.map { tool in
            StoreSourceChangeInput(
                toolID: tool.id,
                sourceURL: try? tool.packageLayout.packageFileURL(
                    for: tool.contentViewSourcePath
                ),
                storeSourceSha256: tool.storeBaselineSourceSha256?.lowercased()
            )
        }
        let changesByToolID = await Task.detached(priority: .utility) {
            Dictionary(
                uniqueKeysWithValues: inputs.map { input in
                    let hasChanges: Bool
                    if let storeSourceSha256 = input.storeSourceSha256,
                        let sourceURL = input.sourceURL,
                        let source = try? String(contentsOf: sourceURL, encoding: .utf8)
                    {
                        hasChanges =
                            IronsmithStoreClient.sha256Hex(for: source) != storeSourceSha256
                    } else {
                        hasChanges = input.storeSourceSha256 == nil
                    }
                    return (input.toolID, hasChanges)
                })
        }.value
        guard !Task.isCancelled else { return }
        storeSourceChangesByToolID = changesByToolID
    }

    private func sourceHasStoreChanges(for tool: Tool) -> Bool {
        guard let storeSourceSha256 = tool.storeBaselineSourceSha256?.lowercased() else {
            return true
        }
        guard let source = try? sourceCode(for: tool) else {
            return true
        }
        return IronsmithStoreClient.sha256Hex(for: source) != storeSourceSha256
    }

    private func hasPublishableSource(for tool: Tool, userID: String) -> Bool {
        if let publication = tool.storePublication,
            publication.ownerUserId != userID
        {
            return true
        }
        return sourceHasStoreChanges(for: tool)
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
        inferenceStore: InferenceStore
    ) async {
        errorMessage = nil
        await inferenceStore.refreshIronsmithAccountSummary()
        guard let userID = inferenceStore.ironsmithSession?.user.id.uuidString else {
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
        guard hasPublishableSource(for: tool, userID: userID) else {
            present(IronsmithStoreClientError.unchangedStoreVersion)
            return
        }
        let publication = canUpdateStoreVersion(for: tool, userID: userID)
            ? tool.storePublication
            : nil
        if let publication {
            do {
                let detail = try await storeClient.fetchApp(
                    publication.storeId,
                    publication.appId
                )
                let source = try sourceCode(for: tool)
                if IronsmithStoreClient.sha256Hex(for: source)
                    == detail.currentVersion.sourceSha256.lowercased()
                {
                    throw IronsmithStoreClientError.unchangedStoreVersion
                }
                publishShortDescription = detail.shortDescription
                publishDescription = detail.description
                publishCategory = detail.category
                publishLicense = detail.currentVersion.license
                publishInheritedLegalAttributions = detail.currentVersion.legalAttributions.filter {
                    $0.versionId != detail.currentVersion.id
                }
                currentPublishedSourceSha256 = detail.currentVersion.sourceSha256.lowercased()
            } catch {
                present(error)
                return
            }
        } else {
            publishShortDescription = ""
            publishDescription = ""
            publishCategory = tool.category
            publishLicense = .mit
            publishInheritedLegalAttributions = []
            currentPublishedSourceSha256 = nil
        }
        do {
            try await preparePublishIdentity(
                for: tool,
                isUpdating: publication != nil,
                remixSource: effectiveRemixSource(for: tool, userID: userID)
            )
        } catch {
            present(error)
            return
        }
        isUpdatingPublishedListing = publication != nil
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
            guard let userID = inferenceStore.ironsmithSession?.user.id.uuidString else {
                throw IronsmithStoreClientError.missingSession
            }
            let publicationName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicationName.isEmpty else {
                throw ToolLibraryStorePublishingError.invalidAppName
            }
            guard canPublishRemixIdentity(for: tool) else {
                throw ToolLibraryStorePublishingError.remixNameMatchesOriginal
            }
            let source = try sourceCode(for: tool)
            let publication = canUpdateStoreVersion(for: tool, userID: userID)
                ? tool.storePublication
                : nil
            let newPublicationRemixSource = publication == nil
                ? effectiveRemixSource(for: tool, userID: userID)
                : nil
            if publication != nil,
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
            if let publication {
                app = try await storeClient.publishVersion(
                    StoreVersionPublicationRequest(
                        storeId: publication.storeId,
                        appId: publication.appId,
                        license: publishLicense,
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
                        remixedFromVersionId: tool.storeRemixSource?.versionId,
                        inspiredByVersionIds: tool.storeAttributionVersionIds
                    )
                )
            } else {
                app = try await storeClient.publishApp(
                    StorePublicationRequest(
                        storeId: newPublicationRemixSource?.storeId
                            ?? IronsmithStoreConstants.communityStoreId,
                        name: publicationName,
                        shortDescription: publishShortDescription.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        description: publishDescription.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        category: publishCategory,
                        license: publishLicense,
                        sourceCode: source,
                        generationSettings: settings,
                        iconMasterJPEG: iconMasterJPEG,
                        iconThumbnailJPEG: iconThumbnailJPEG,
                        screenshotJPEGs: publishScreenshotData.map { [$0] } ?? [],
                        remixedFromVersionId: newPublicationRemixSource?.versionId,
                        inspiredByVersionIds: tool.storeAttributionVersionIds
                    )
                )
            }

            await finishSuccessfulPublication(
                app,
                for: tool,
                ownerUserID: userID,
                adoptedRemixSource: newPublicationRemixSource,
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
            await beginPublishing(tool, inferenceStore: inferenceStore)
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

    private func preparePublishIdentity(
        for tool: Tool,
        isUpdating: Bool,
        remixSource: StoreVersionReference?
    ) async throws {
        refreshPublishIdentity(for: tool)
        originalRemixApp = nil
        originalRemixIconData = nil

        guard !isUpdating,
            let storeId = remixSource?.storeId,
            let appId = remixSource?.appId
        else { return }

        let originalApp = try await storeClient.fetchApp(storeId, appId)
        originalRemixApp = originalApp
        publishInheritedLegalAttributions = originalApp.currentVersion.legalAttributions
        if let url = originalApp.iconAsset?.url {
            if let downloadedIconData = try? await originalIconDataLoader(url) {
                originalRemixIconData = comparableOriginalIconData(
                    downloadedIconData,
                    app: originalApp
                )
            }
        }
    }

    private func effectiveRemixSource(
        for tool: Tool,
        userID: String?
    ) -> StoreVersionReference? {
        if let publication = tool.storePublication,
            publication.ownerUserId != userID
        {
            return StoreVersionReference(
                versionId: publication.versionId,
                storeId: publication.storeId,
                appId: publication.appId,
                versionNumber: publication.versionNumber,
                sourceSha256: publication.sourceSha256
            )
        }
        return tool.storeRemixSource
    }

    private func comparableOriginalIconData(
        _ downloadedIconData: Data,
        app: StoreAppDetail
    ) -> Data {
        guard app.iconMaster == nil,
            let decodedIcon = try? ToolImageAssetEncoder.decodeImage(
                downloadedIconData,
                applyingOrientation: true
            ),
            let normalizedIcon = try? ToolImageAssetEncoder.iconAssets(from: decodedIcon)
        else {
            return downloadedIconData
        }
        return normalizedIcon.thumbnailData
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
        ownerUserID: String?
    ) {
        guard let ownerUserID else { return }
        tool.category = app.category
        tool.storePublication = StorePublication(
            storeId: app.storeId,
            appId: app.id,
            versionId: app.currentVersion.id,
            versionNumber: app.currentVersion.versionNumber,
            sourceSha256: app.currentVersion.sourceSha256,
            ownerUserId: ownerUserID,
            publishedAt: Date()
        )
        tool.updatedAt = Date()
    }

    private func finishSuccessfulPublication(
        _ app: StoreAppDetail,
        for tool: Tool,
        ownerUserID: String?,
        adoptedRemixSource: StoreVersionReference?,
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore
    ) async {
        if let adoptedRemixSource,
            tool.storeRemixSource?.versionId != adoptedRemixSource.versionId
        {
            tool.replaceStoreProvenance(
                remixSource: adoptedRemixSource,
                inspirations: tool.storeInspirations
            )
        }
        applyPublishedStoreLinkage(
            app,
            to: tool,
            ownerUserID: ownerUserID
        )

        let persistenceError: Error?
        do {
            try saveModelContext(modelContext)
            persistenceError = nil
        } catch {
            persistenceError = error
        }

        let legalDocumentsError: Error?
        do {
            let version = app.currentVersion
            try StoreLegalPackageWriter.write(
                StoreLegalDocumentRenderer.render(
                    appName: app.name,
                    currentVersionId: version.id,
                    primaryLicense: version.license,
                    attributions: version.legalAttributions
                ),
                to: tool.packageLayout
            )
            legalDocumentsError = nil
        } catch {
            legalDocumentsError = error
        }

        let rebuildError: Error?
        do {
            try await buildClient.buildTool(tool)
            rebuildError = nil
        } catch {
            rebuildError = error
        }

        isShowingPublishSheet = false
        routeStore.open(.store(.publishedApp(app.id)))

        if let warning = ToolLibraryStorePublishingError.localFinalizationWarning(
            persistenceError: persistenceError,
            legalDocumentsError: legalDocumentsError,
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

private struct StoreSourceChangeInput: Sendable {
    let toolID: UUID
    let sourceURL: URL?
    let storeSourceSha256: String?
}

private enum ToolLibraryStorePublishingError: LocalizedError {
    case invalidAppName
    case invalidDisplayName
    case invalidHandle
    case remixNameMatchesOriginal
    case localFinalizationFailed(String)

    static func localFinalizationWarning(
        persistenceError: Error?,
        legalDocumentsError: Error?,
        rebuildError: Error?
    ) -> Self? {
        var details: [String] = []
        if let persistenceError {
            details.append(
                "Ironsmith could not save the Store linkage locally: \(persistenceError.localizedDescription)"
            )
        }
        if let legalDocumentsError {
            details.append(
                "Ironsmith could not write the local Legal documents: \(legalDocumentsError.localizedDescription)"
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
        case .invalidAppName:
            "Enter an app name before publishing."
        case .invalidDisplayName:
            "Enter a display name between 1 and 80 characters."
        case .invalidHandle:
            "Enter a handle using 3–30 letters, numbers, or underscores that begins and ends with a letter or number."
        case .remixNameMatchesOriginal:
            "Current app name is the same as the original. Change the app name in Edit Details before publishing."
        case .localFinalizationFailed(let detail):
            """
            This app was published successfully, but Ironsmith could not finish updating its \
            local state. \(detail)
            """
        }
    }
}
