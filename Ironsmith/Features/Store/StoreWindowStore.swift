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
        case .createCopy: "Get"
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

@MainActor
@Observable
final class StoreWindowStore {
    var stores: [AppStoreDescriptor] = []
    var selectedStoreId = IronsmithStoreConstants.communityStoreId
    var homeSections: [StoreHomeSection] = []
    var discoverApps: [StoreAppSummary] = []
    var publishedApps: [StoreAppSummary] = []
    var selectedAppID: String?
    var selectedAppDetail: StoreAppDetail?
    var searchText = ""
    var isLoadingStores = false
    var isLoadingDiscover = false
    var isLoadingPublished = false
    var isLoadingDetail = false
    var workingAppID: String?
    var errorMessage: String?

    @ObservationIgnored private let client: IronsmithStoreClient
    @ObservationIgnored private let importClient: StoreToolImportClient
    @ObservationIgnored private let buildClient: ToolBuildClient
    @ObservationIgnored private let packageMaterializer: ToolPackageMaterializer

    init() {
        self.client = .live
        self.importClient = .live
        self.buildClient = .live()
        self.packageMaterializer = .live
    }

    init(
        client: IronsmithStoreClient,
        importClient: StoreToolImportClient,
        buildClient: ToolBuildClient,
        packageMaterializer: ToolPackageMaterializer = .live
    ) {
        self.client = client
        self.importClient = importClient
        self.buildClient = buildClient
        self.packageMaterializer = packageMaterializer
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
            ?? discoverApps.first { $0.id == id }
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

    func refreshHome() async {
        isLoadingDiscover = true
        defer { isLoadingDiscover = false }
        do {
            homeSections = try await client.listHomeSections(selectedStoreId)
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                discoverApps = []
            }
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func refreshDiscover() async {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            await refreshHome()
            return
        }
        isLoadingDiscover = true
        defer { isLoadingDiscover = false }
        do {
            let page = try await client.listApps(
                selectedStoreId,
                .discover,
                trimmedSearch,
                nil,
                .recent,
                nil
            )
            discoverApps = page.apps
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func loadSectionApps(
        sort: StoreAppListSort,
        category: StoreAppCategory?
    ) async -> [StoreAppSummary] {
        do {
            return try await client.listApps(
                selectedStoreId,
                .discover,
                nil,
                nil,
                sort,
                category
            ).apps
        } catch {
            present(error)
            return []
        }
    }

    func install(
        _ app: StoreAppSummary,
        mode: StoreToolImportMode,
        tools: [Tool],
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async {
        selectedAppID = app.id
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
                mode: mode,
                tools: tools,
                modelContext: modelContext,
                routeStore: routeStore,
                inferenceStore: inferenceStore
            )
        } catch {
            present(error)
        }
    }

    func refreshPublished() async {
        isLoadingPublished = true
        defer { isLoadingPublished = false }
        do {
            let page = try await client.listApps(
                selectedStoreId,
                .mine,
                nil,
                nil,
                .recent,
                nil
            )
            publishedApps = page.apps
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func select(_ app: StoreAppSummary) {
        selectedAppID = app.id
        selectedAppDetail = nil
        Task {
            await loadDetail(for: app)
        }
    }

    func isOwnPublishedApp(_ app: StoreAppDetail) -> Bool {
        publishedApps.contains { $0.id == app.id }
    }

    func installDisposition(for app: StoreAppDetail, tools: [Tool]) -> StoreAppInstallDisposition {
        let linkedTools = tools.filter { $0.storeAppId == app.id }
        if let currentTool = linkedTools.first(where: {
            localSourceHash(for: $0) == app.currentVersion.sourceSha256
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

    func install(
        _ app: StoreAppDetail,
        mode: StoreToolImportMode,
        tools: [Tool],
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async {
        guard workingAppID == nil else { return }
        workingAppID = app.id
        defer { workingAppID = nil }
        do {
            if inferenceStore.ironsmithSession != nil {
                await refreshPublished()
            }
            let isOwnApp = isOwnPublishedApp(app)
            if mode == .get {
                switch installDisposition(for: app, tools: tools) {
                case .openExisting(let tool):
                    routeStore.open(.toolLibrary(.selectTool(id: tool.id, focusPrompt: false)))
                    return
                case .updateExisting(let tool):
                    try await updateExistingTool(
                        tool,
                        from: app,
                        isOwnApp: isOwnApp,
                        modelContext: modelContext,
                        routeStore: routeStore,
                        inferenceStore: inferenceStore
                    )
                    return
                case .createCopy:
                    break
                }
            }
            let version = try await client.fetchVersion(
                app.storeId,
                app.id,
                app.currentVersion.versionNumber
            )
            let result = try await importClient.importTool(
                StoreToolImportRequest(
                    app: app,
                    version: version,
                    mode: mode,
                    isOwnApp: isOwnApp,
                    initialGenerationState: mode == .get ? .generating : .ready
                ),
                modelContext
            )
            routeStore.open(
                .toolLibrary(
                    .selectTool(id: result.tool.id, focusPrompt: mode == .remix)
                )
            )
            if mode == .get {
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
        } catch {
            present(error)
        }
    }

    private func updateExistingTool(
        _ tool: Tool,
        from app: StoreAppDetail,
        isOwnApp: Bool,
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
            try writeStoreVersion(version, app: app, isOwnApp: isOwnApp, to: tool)
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

    private func writeStoreVersion(
        _ version: StoreVersionDownload,
        app: StoreAppDetail,
        isOwnApp: Bool,
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
        applyStoreLinkage(app, version: version, isOwnApp: isOwnApp, to: tool)
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

    private func loadDetail(for app: StoreAppSummary) async {
        isLoadingDetail = true
        defer {
            if selectedAppID == app.id {
                isLoadingDetail = false
            }
        }
        do {
            let detail = try await client.fetchApp(app.storeId, app.id)
            guard selectedAppID == app.id else { return }
            selectedAppDetail = detail
        } catch {
            guard selectedAppID == app.id else { return }
            present(error)
        }
    }

    private func applyStoreLinkage(
        _ app: StoreAppDetail,
        version: StoreVersionDownload,
        isOwnApp: Bool,
        to tool: Tool
    ) {
        tool.storeId = app.storeId
        tool.storeAppId = app.id
        tool.storeVersionId = version.id
        tool.storeVersionNumber = version.versionNumber
        tool.storeSourceSha256 = version.sourceSha256
        tool.storeImportedAt = Date()
        tool.storeRemixedFromVersionId = isOwnApp ? nil : version.id
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
        if let index = discoverApps.firstIndex(where: { $0.id == app.id }) {
            discoverApps[index] = summary
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

    private func present(_ error: Error) {
        errorMessage =
            IronsmithErrorPresentation.message(for: error)
            ?? error.localizedDescription
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
