import Foundation
import Observation
import SwiftData

enum StoreAppInstallDisposition {
    case openExisting(Tool)
    case updateExisting(Tool)
    case createCopy

    var buttonTitle: String {
        switch self {
        case .openExisting: "Open"
        case .updateExisting: "Update"
        case .createCopy: "Download"
        }
    }

    var systemImage: String {
        switch self {
        case .openExisting: "arrow.forward.circle"
        case .updateExisting: "arrow.triangle.2.circlepath"
        case .createCopy: "arrow.down.circle"
        }
    }
}

enum StorePendingDownloadRequest {
    case appSummary(StoreAppSummary)
    case appDetail(StoreAppDetail)
    case version(StoreVersionMetadata, app: StoreAppDetail)
}

@MainActor
@Observable
final class StoreWindowStore {
    var stores: [AppStoreDescriptor] = []
    var selectedStoreId = IronsmithStoreConstants.communityStoreId
    var homeSections: [StoreHomeSection] = []
    var searchResults: [StoreAppSummary] = []
    var searchResultsNextOffset = 0
    var searchResultsHasMore = false
    var publishedApps: [StoreAppSummary] = []
    var publishedAppsNextOffset = 0
    var publishedAppsHasMore = false
    var selectedAppID: String?
    var selectedAppDetail: StoreAppDetail?
    var searchText = ""
    var isLoadingStores = false
    var isLoadingDiscover = false
    var isLoadingMoreSearchResults = false
    var isLoadingPublished = false
    var isLoadingMorePublishedApps = false
    var isLoadingDetail = false
    var workingAppID: String?
    var workingVersionID: String?
    var contentRevision = 0
    var errorMessage: String?
    var isStoreSignInRequired = false
    var pendingDownloadRequest: StorePendingDownloadRequest?

    @ObservationIgnored private let client: IronsmithStoreClient
    @ObservationIgnored private let importClient: StoreToolImportClient
    @ObservationIgnored private let buildClient: ToolBuildClient
    @ObservationIgnored private let packageMaterializer: ToolPackageMaterializer
    @ObservationIgnored private let saveModelContext: (ModelContext) throws -> Void
    @ObservationIgnored private var searchPaginationRevision = 0
    @ObservationIgnored private var publishedPaginationRevision = 0

    init() {
        self.client = .live
        self.importClient = .live
        self.buildClient = .live()
        self.packageMaterializer = .live
        self.saveModelContext = { try $0.save() }
    }

    init(
        client: IronsmithStoreClient,
        importClient: StoreToolImportClient,
        buildClient: ToolBuildClient,
        packageMaterializer: ToolPackageMaterializer = .live,
        saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.client = client
        self.importClient = importClient
        self.buildClient = buildClient
        self.packageMaterializer = packageMaterializer
        self.saveModelContext = saveModelContext
    }

    var selectedAppSummary: StoreAppSummary? {
        appSummary(id: selectedAppID)
    }

    func appSummary(id: String?) -> StoreAppSummary? {
        guard let id else { return nil }
        return
            homeSections
            .flatMap(\.apps)
            .first { $0.id == id }
            ?? searchResults.first { $0.id == id }
            ?? publishedApps.first { $0.id == id }
    }

    func loadInitial(inferenceStore: InferenceStore) async {
        guard stores.isEmpty else { return }
        await loadStores()
        await refreshHome()
        if inferenceStore.ironsmithSession != nil {
            await refreshPublished()
        }
    }

    func loadStores() async {
        isLoadingStores = true
        defer { isLoadingStores = false }
        do {
            stores = try await client.listStores()
            if !stores.contains(where: { $0.id == selectedStoreId }),
                let firstStore = stores.first
            {
                selectedStoreId = firstStore.id
            }
        } catch {
            present(error)
        }
    }

    func refreshHome(showLoadingIndicator: Bool = true) async {
        searchPaginationRevision += 1
        if showLoadingIndicator {
            isLoadingDiscover = true
        }
        searchResultsNextOffset = 0
        searchResultsHasMore = false
        defer {
            if showLoadingIndicator {
                isLoadingDiscover = false
            }
        }
        do {
            homeSections = try await client.listHomeSections(selectedStoreId)
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults = []
                searchResultsNextOffset = 0
                searchResultsHasMore = false
            }
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func refreshDiscover(showLoadingIndicator: Bool = true) async {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            await refreshHome(showLoadingIndicator: showLoadingIndicator)
            return
        }
        searchPaginationRevision += 1
        let revision = searchPaginationRevision
        let storeId = selectedStoreId
        if showLoadingIndicator {
            isLoadingDiscover = true
        }
        searchResultsNextOffset = 0
        searchResultsHasMore = false
        defer {
            if showLoadingIndicator {
                isLoadingDiscover = false
            }
        }
        do {
            let page = try await client.listApps(
                storeId,
                .discover,
                trimmedSearch,
                0,
                .recent,
                nil,
                nil
            )
            guard searchPaginationRevision == revision,
                selectedStoreId == storeId,
                searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSearch
            else {
                return
            }
            searchResults = page.apps
            searchResultsNextOffset = page.apps.count
            searchResultsHasMore = page.hasMore
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func loadMoreSearchResults() async {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty,
            searchResultsHasMore,
            !isLoadingMoreSearchResults
        else {
            return
        }
        let offset = searchResultsNextOffset
        let revision = searchPaginationRevision
        let storeId = selectedStoreId

        isLoadingMoreSearchResults = true
        defer { isLoadingMoreSearchResults = false }
        do {
            let page = try await client.listApps(
                storeId,
                .discover,
                trimmedSearch,
                offset,
                .recent,
                nil,
                nil
            )
            guard searchPaginationRevision == revision,
                selectedStoreId == storeId,
                searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSearch
            else {
                return
            }
            guard searchResultsNextOffset == offset else {
                return
            }
            appendUnique(page.apps, to: &searchResults)
            searchResultsNextOffset += page.apps.count
            searchResultsHasMore = page.hasMore
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func loadSectionApps(
        sort: StoreAppListSort,
        category: StoreAppCategory?,
        creatorHandle: String? = nil,
        offset: Int = 0
    ) async -> StoreAppPage? {
        do {
            return try await client.listApps(
                selectedStoreId,
                .discover,
                nil,
                offset,
                sort,
                category,
                creatorHandle
            )
        } catch {
            guard !IronsmithErrorPresentation.isCancellation(error), !Task.isCancelled else {
                return nil
            }
            present(error)
            return nil
        }
    }

    func install(
        _ app: StoreAppSummary,
        tools: [Tool],
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async {
        selectedAppID = app.id
        if case .openExisting(let tool) = installDisposition(for: app, tools: tools) {
            routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))
            return
        }
        guard
            requireAccountForDownload(
                .appSummary(app),
                inferenceStore: inferenceStore
            )
        else { return }
        do {
            let detail: StoreAppDetail
            if let selectedAppDetail, selectedAppDetail.id == app.id {
                detail = selectedAppDetail
            } else {
                isLoadingDetail = true
                defer { isLoadingDetail = false }
                detail = try await client.fetchApp(app.storeId, app.id)
                selectedAppDetail = detail
            }
            await install(
                detail,
                tools: tools,
                modelContext: modelContext,
                routeStore: routeStore,
                inferenceStore: inferenceStore
            )
        } catch {
            present(error)
        }
    }

    func refreshPublished(showLoadingIndicator: Bool = true) async {
        publishedPaginationRevision += 1
        let revision = publishedPaginationRevision
        let storeId = selectedStoreId
        if showLoadingIndicator {
            isLoadingPublished = true
        }
        publishedAppsNextOffset = 0
        publishedAppsHasMore = false
        defer {
            if showLoadingIndicator {
                isLoadingPublished = false
            }
        }
        do {
            let page = try await client.listApps(
                storeId,
                .mine,
                nil,
                0,
                .recent,
                nil,
                nil
            )
            guard publishedPaginationRevision == revision, selectedStoreId == storeId else {
                return
            }
            publishedApps = page.apps
            publishedAppsNextOffset = page.apps.count
            publishedAppsHasMore = page.hasMore
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func loadMorePublishedApps() async {
        guard publishedAppsHasMore, !isLoadingMorePublishedApps else {
            return
        }
        let offset = publishedAppsNextOffset
        let revision = publishedPaginationRevision
        let storeId = selectedStoreId

        isLoadingMorePublishedApps = true
        defer { isLoadingMorePublishedApps = false }
        do {
            let page = try await client.listApps(
                storeId,
                .mine,
                nil,
                offset,
                .recent,
                nil,
                nil
            )
            guard publishedPaginationRevision == revision,
                selectedStoreId == storeId,
                publishedAppsNextOffset == offset
            else {
                return
            }
            appendUnique(page.apps, to: &publishedApps)
            publishedAppsNextOffset += page.apps.count
            publishedAppsHasMore = page.hasMore
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func select(_ app: StoreAppSummary, forceReload: Bool = false) {
        select(storeID: app.storeId, appID: app.id, forceReload: forceReload)
    }

    func select(storeID: String, appID: String, forceReload: Bool = false) {
        if !forceReload,
            selectedAppID == appID,
            selectedAppDetail?.id == appID || isLoadingDetail
        {
            return
        }
        selectedAppID = appID
        selectedAppDetail = nil
        isLoadingDetail = true
        Task {
            await loadDetail(storeID: storeID, appID: appID)
        }
    }

    func installDisposition(
        for app: StoreAppSummary,
        tools: [Tool]
    ) -> StoreAppInstallDisposition {
        let unchangedLinkedTools = tools.filter { tool in
            guard tool.storeAppId == app.id,
                let importedHash = tool.storeSourceSha256?.lowercased()
            else {
                return false
            }
            return localSourceHash(for: tool) == importedHash
        }
        if let currentTool = unchangedLinkedTools.first(where: {
            $0.storeVersionNumber == app.latestVersionNumber
        }) {
            return .openExisting(currentTool)
        }
        if let olderTool = unchangedLinkedTools.first(where: {
            guard let versionNumber = $0.storeVersionNumber else { return false }
            return versionNumber < app.latestVersionNumber
        }) {
            return .updateExisting(olderTool)
        }
        return .createCopy
    }

    func installDisposition(for app: StoreAppDetail, tools: [Tool]) -> StoreAppInstallDisposition {
        let linkedTools = tools.filter { $0.storeAppId == app.id }
        if let currentTool = linkedTools.first(where: {
            localSourceHash(for: $0) == app.currentVersion.sourceSha256.lowercased()
        }) {
            return .openExisting(currentTool)
        }
        if let updatableTool = linkedTools.first(where: { tool in
            guard let importedHash = tool.storeSourceSha256,
                importedHash != app.currentVersion.sourceSha256
            else { return false }
            return localSourceHash(for: tool) == importedHash
        }) {
            return .updateExisting(updatableTool)
        }
        return .createCopy
    }

    func installDisposition(
        for version: StoreVersionMetadata,
        of app: StoreAppDetail,
        tools: [Tool]
    ) -> StoreAppInstallDisposition {
        guard
            let matchingTool = tools.first(where: {
                $0.storeAppId == app.id
                    && $0.storeVersionId == version.id
                    && localSourceHash(for: $0) == version.sourceSha256.lowercased()
            })
        else {
            return .createCopy
        }
        return .openExisting(matchingTool)
    }

    func install(
        _ app: StoreAppDetail,
        tools: [Tool],
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async {
        guard workingAppID == nil else { return }
        if case .openExisting(let tool) = installDisposition(for: app, tools: tools) {
            routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))
            return
        }
        guard
            requireAccountForDownload(
                .appDetail(app),
                inferenceStore: inferenceStore
            )
        else { return }
        workingAppID = app.id
        workingVersionID = app.currentVersion.id
        defer {
            workingAppID = nil
            workingVersionID = nil
        }
        do {
            if inferenceStore.ironsmithSession != nil {
                await refreshPublished(showLoadingIndicator: false)
            }
            switch installDisposition(for: app, tools: tools) {
            case .openExisting(let tool):
                routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))
                return
            case .updateExisting(let tool):
                try await updateExistingTool(
                    tool,
                    from: app,
                    modelContext: modelContext,
                    routeStore: routeStore,
                    inferenceStore: inferenceStore
                )
                contentRevision += 1
                return
            case .createCopy:
                break
            }
            let version = try await client.fetchVersion(
                app.storeId,
                app.id,
                app.currentVersion.versionNumber
            )
            try await importAndBuild(
                version,
                app: app,
                displayName: nil,
                modelContext: modelContext,
                routeStore: routeStore
            )
            contentRevision += 1
        } catch {
            present(error)
        }
    }

    func installVersion(
        _ version: StoreVersionMetadata,
        of app: StoreAppDetail,
        tools: [Tool],
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async {
        guard workingAppID == nil else { return }
        if case .openExisting(let tool) = installDisposition(
            for: version,
            of: app,
            tools: tools
        ) {
            routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))
            return
        }
        guard
            requireAccountForDownload(
                .version(version, app: app),
                inferenceStore: inferenceStore
            )
        else { return }
        workingAppID = app.id
        workingVersionID = version.id
        defer {
            workingAppID = nil
            workingVersionID = nil
        }
        do {
            if inferenceStore.ironsmithSession != nil {
                await refreshPublished(showLoadingIndicator: false)
            }
            if case .openExisting(let tool) = installDisposition(
                for: version,
                of: app,
                tools: tools
            ) {
                routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))
                return
            }

            let download = try await client.fetchVersion(
                app.storeId,
                app.id,
                version.versionNumber
            )
            guard download.id == version.id else {
                throw IronsmithStoreClientError.invalidResponse
            }
            guard download.sourceSha256.lowercased() == version.sourceSha256.lowercased() else {
                throw IronsmithStoreClientError.sourceHashMismatch(
                    expected: version.sourceSha256,
                    actual: download.sourceSha256
                )
            }
            let displayName =
                version.id == app.currentVersion.id
                ? app.name
                : "\(app.name) v\(version.versionNumber)"
            try await importAndBuild(
                download,
                app: app,
                displayName: displayName,
                modelContext: modelContext,
                routeStore: routeStore
            )
            contentRevision += 1
        } catch {
            present(error)
        }
    }

    func setStatus(_ app: StoreAppSummary, status: StoreAppStatus) async {
        guard workingAppID == nil else { return }
        workingAppID = app.id
        defer { workingAppID = nil }
        do {
            let updated = try await client.patchListing(
                app.storeId,
                app.id,
                StoreListingUpdateRequest(status: status)
            )
            replacePublishedApp(updated)
            if selectedAppID == updated.id {
                selectedAppDetail = updated
            }
            contentRevision += 1
        } catch {
            present(error)
        }
    }

    func deleteFromStore(
        _ app: StoreAppSummary,
        tools: [Tool],
        modelContext: ModelContext
    ) async {
        guard workingAppID == nil else { return }
        workingAppID = app.id
        defer { workingAppID = nil }
        do {
            try await client.deleteApp(app.storeId, app.id)
        } catch {
            present(error)
            return
        }

        let linkedTools = tools.filter { $0.storeId == app.storeId && $0.storeAppId == app.id }
        let previousLinkages = linkedTools.map {
            ($0, StoreToolLinkageSnapshot(tool: $0), $0.updatedAt)
        }
        for tool in linkedTools {
            tool.storeId = nil
            tool.storeAppId = nil
            tool.storeVersionId = nil
            tool.storeVersionNumber = nil
            tool.storeSourceSha256 = nil
            tool.storeImportedAt = nil
            tool.updatedAt = .now
        }
        do {
            try saveModelContext(modelContext)
        } catch {
            modelContext.rollback()
            for (tool, linkage, updatedAt) in previousLinkages {
                linkage.apply(to: tool)
                tool.updatedAt = updatedAt
            }
            errorMessage =
                "The Store listing was deleted, but Ironsmith could not unlink its local app copies: \(error.localizedDescription)"
            return
        }

        publishedApps.removeAll { $0.id == app.id }
        if selectedAppID == app.id {
            selectedAppID = nil
            selectedAppDetail = nil
        }
        contentRevision += 1
    }

    private func updateExistingTool(
        _ tool: Tool,
        from app: StoreAppDetail,
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async throws {
        let defaults = ToolLibraryStore.defaultGenerationSettings(
            from: inferenceStore.generationPreferences)
        let previousSettings = tool.generationSettings(defaults: defaults)
        let previousState = tool.generationState
        let previousPhase = tool.generationPhase
        let previousError = tool.generationErrorSummary
        let previousLinkage = StoreToolLinkageSnapshot(tool: tool)
        let layout = tool.packageLayout
        let previousIcons = ToolIconAssetSnapshot(layout: layout)
        let backup = try ToolVersionBackupClient.live.stageCurrentVersion(
            layout.packageRootURL,
            tool.contentViewSourcePath,
            previousSettings
        )

        tool.generationState = .generating
        tool.generationPhase = .packaging
        tool.generationErrorSummary = nil
        tool.updatedAt = Date()
        try modelContext.save()
        routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))

        do {
            let version = try await client.fetchVersion(
                app.storeId,
                app.id,
                app.currentVersion.versionNumber
            )
            try IronsmithStoreClient.verifySourceHash(version)
            try writeStoreVersion(version, app: app, to: tool)
            try await StoreToolImportClient.cacheIconIfAvailable(
                app: app,
                layout: tool.packageLayout
            )
            try modelContext.save()
            try await buildClient.buildTool(tool)
            try ToolVersionBackupClient.live.promoteStagedVersion(backup)
            tool.generationState = .ready
            tool.generationPhase = .completed
            tool.generationErrorSummary = nil
            tool.updatedAt = Date()
            try modelContext.save()
        } catch {
            try? restoreToolSource(
                from: backup,
                to: tool,
                settings: previousSettings
            )
            try? ToolVersionBackupClient.live.discardStagedVersion(backup)
            previousIcons.restore()
            previousLinkage.apply(to: tool)
            tool.applyGenerationSettings(previousSettings)
            tool.generationState = previousState
            tool.generationPhase = previousPhase
            tool.generationErrorSummary = previousError
            tool.updatedAt = Date()
            try? modelContext.save()
            throw error
        }
    }

    func takePendingDownloadRequest() -> StorePendingDownloadRequest? {
        defer { pendingDownloadRequest = nil }
        return pendingDownloadRequest
    }

    func requestStoreAccountAccess(using inferenceStore: InferenceStore) -> Bool {
        guard inferenceStore.ironsmithSession != nil else {
            isStoreSignInRequired = true
            return false
        }
        return true
    }

    func fetchSource(for version: StoreVersionMetadata, of app: StoreAppDetail) async throws -> String {
        let downloadedVersion = try await client.fetchVersion(
            app.storeId,
            app.id,
            version.versionNumber
        )
        guard downloadedVersion.id == version.id,
              downloadedVersion.appId == app.id,
              downloadedVersion.sourceSha256.lowercased() == version.sourceSha256.lowercased()
        else {
            throw IronsmithStoreClientError.invalidResponse
        }
        try IronsmithStoreClient.verifySourceHash(downloadedVersion)
        return downloadedVersion.sourceCode
    }

    func resumeDownload(
        _ request: StorePendingDownloadRequest,
        tools: [Tool],
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async {
        switch request {
        case .appSummary(let app):
            await install(
                app,
                tools: tools,
                modelContext: modelContext,
                routeStore: routeStore,
                inferenceStore: inferenceStore
            )
        case .appDetail(let app):
            await install(
                app,
                tools: tools,
                modelContext: modelContext,
                routeStore: routeStore,
                inferenceStore: inferenceStore
            )
        case .version(let version, let app):
            await installVersion(
                version,
                of: app,
                tools: tools,
                modelContext: modelContext,
                routeStore: routeStore,
                inferenceStore: inferenceStore
            )
        }
    }

    private func requireAccountForDownload(
        _ request: StorePendingDownloadRequest,
        inferenceStore: InferenceStore
    ) -> Bool {
        guard requestStoreAccountAccess(using: inferenceStore) else {
            pendingDownloadRequest = request
            return false
        }
        return true
    }

    private func importAndBuild(
        _ version: StoreVersionDownload,
        app: StoreAppDetail,
        displayName: String?,
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore
    ) async throws {
        let result = try await importClient.importTool(
            StoreToolImportRequest(
                app: app,
                version: version,
                displayName: displayName,
                initialGenerationState: .generating
            ),
            modelContext
        )
        routeStore.open(.toolLibrary(.selectTool(id: result.tool.id, focusPrompt: false)))

        do {
            try await buildClient.buildTool(result.tool)
            result.tool.generationState = .ready
            result.tool.generationPhase = .completed
            result.tool.generationErrorSummary = nil
            result.tool.updatedAt = Date()
            try modelContext.save()
        } catch {
            result.tool.generationState = .failed
            result.tool.generationErrorSummary = error.localizedDescription
            result.tool.updatedAt = Date()
            try? modelContext.save()
            throw error
        }
    }

    private func writeStoreVersion(
        _ version: StoreVersionDownload,
        app: StoreAppDetail,
        to tool: Tool
    ) throws {
        let layout = tool.packageLayout
        let settings = version.generationSettings.toolSettings
        try packageMaterializer.preparePackageDirectories(layout)
        try packageMaterializer.writeContentView(version.sourceCode, layout: layout)
        try packageMaterializer.writeAppEntry(
            layout: layout,
            displayName: tool.name,
            settings: settings
        )
        tool.applyGenerationSettings(settings)
        applyStoreLinkage(app, version: version, to: tool)
    }

    private func restoreToolSource(
        from backup: ToolContentVersionBackup,
        to tool: Tool,
        settings: ToolGenerationSettings
    ) throws {
        let layout = tool.packageLayout
        let previousSource = try String(contentsOf: backup.pendingURL, encoding: .utf8)
        try packageMaterializer.preparePackageDirectories(layout)
        try packageMaterializer.writeContentView(previousSource, layout: layout)
        try packageMaterializer.writeAppEntry(
            layout: layout,
            displayName: tool.name,
            settings: settings
        )
    }

    private func loadDetail(storeID: String, appID: String) async {
        defer {
            if selectedAppID == appID {
                isLoadingDetail = false
            }
        }
        do {
            let detail = try await client.fetchApp(storeID, appID)
            guard selectedAppID == appID else { return }
            selectedAppDetail = detail
        } catch {
            guard selectedAppID == appID else { return }
            present(error)
        }
    }

    private func applyStoreLinkage(
        _ app: StoreAppDetail,
        version: StoreVersionDownload,
        to tool: Tool
    ) {
        tool.storeId = app.storeId
        tool.storeAppId = app.id
        tool.storeVersionId = version.id
        tool.storeVersionNumber = version.versionNumber
        tool.storeSourceSha256 = version.sourceSha256
        tool.storeImportedAt = Date()
        tool.storeRemixedFromVersionId = version.remixedFromVersionId
        tool.updatedAt = Date()
    }

    private func localSourceHash(for tool: Tool) -> String? {
        guard
            let source = try? String(
                contentsOf: try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath),
                encoding: .utf8
            )
        else {
            return nil
        }
        return IronsmithStoreClient.sha256Hex(for: source)
    }

    private func replacePublishedApp(_ app: StoreAppDetail) {
        let summary = StoreAppSummary(detail: app)
        if let index = publishedApps.firstIndex(where: { $0.id == app.id }) {
            publishedApps[index] = summary
        } else {
            publishedApps.insert(summary, at: 0)
        }
        if let index = searchResults.firstIndex(where: { $0.id == app.id }) {
            searchResults[index] = summary
        }
        for sectionIndex in homeSections.indices {
            if let appIndex = homeSections[sectionIndex].apps.firstIndex(where: { $0.id == app.id })
            {
                var apps = homeSections[sectionIndex].apps
                apps[appIndex] = summary
                homeSections[sectionIndex] = StoreHomeSection(
                    id: homeSections[sectionIndex].id,
                    title: homeSections[sectionIndex].title,
                    category: homeSections[sectionIndex].category,
                    sort: homeSections[sectionIndex].sort,
                    apps: apps
                )
            }
        }
        if selectedAppID == app.id {
            selectedAppDetail = app
        }
    }

    private func reconcileSelection() {
        guard let selectedAppID else {
            return
        }
        if appSummary(id: selectedAppID) != nil {
            return
        }
        selectedAppDetail = nil
        self.selectedAppID = nil
    }

    private func appendUnique(_ apps: [StoreAppSummary], to existingApps: inout [StoreAppSummary]) {
        let existingIDs = Set(existingApps.map(\.id))
        existingApps.append(contentsOf: apps.filter { !existingIDs.contains($0.id) })
    }

    private func present(_ error: Error) {
        errorMessage =
            IronsmithErrorPresentation.message(for: error)
            ?? error.localizedDescription
    }
}

private struct ToolIconAssetSnapshot {
    private let files: [(url: URL, data: Data?)]

    init(layout: ToolPackageLayout) {
        files = [
            layout.cachedAppIconICNSURL,
            layout.cachedAppIconMasterJPEGURL,
            layout.cachedAppIconThumbnailJPEGURL,
            layout.cachedAppIconPNGURL,
        ].map { url in
            (url, try? Data(contentsOf: url))
        }
    }

    func restore(fileManager: FileManager = .default) {
        for file in files {
            if let data = file.data {
                try? fileManager.createDirectory(
                    at: file.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: file.url, options: .atomic)
            } else {
                try? fileManager.removeItem(at: file.url)
            }
        }
    }
}

private struct StoreToolLinkageSnapshot {
    let storeId: String?
    let storeAppId: String?
    let storeVersionId: String?
    let storeVersionNumber: Int?
    let storeSourceSha256: String?
    let storeImportedAt: Date?
    let storeRemixedFromVersionId: String?

    init(tool: Tool) {
        storeId = tool.storeId
        storeAppId = tool.storeAppId
        storeVersionId = tool.storeVersionId
        storeVersionNumber = tool.storeVersionNumber
        storeSourceSha256 = tool.storeSourceSha256
        storeImportedAt = tool.storeImportedAt
        storeRemixedFromVersionId = tool.storeRemixedFromVersionId
    }

    func apply(to tool: Tool) {
        tool.storeId = storeId
        tool.storeAppId = storeAppId
        tool.storeVersionId = storeVersionId
        tool.storeVersionNumber = storeVersionNumber
        tool.storeSourceSha256 = storeSourceSha256
        tool.storeImportedAt = storeImportedAt
        tool.storeRemixedFromVersionId = storeRemixedFromVersionId
    }
}
