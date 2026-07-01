import Foundation
import Observation
import SwiftData

enum StoreSidebarTab: String, CaseIterable, Identifiable {
    case discover
    case published

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: "Discover"
        case .published: "Published"
        }
    }

    var systemImage: String {
        switch self {
        case .discover: "sparkles"
        case .published: "square.and.arrow.up"
        }
    }
}

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
    var selectedTab: StoreSidebarTab = .discover
    var stores: [AppStoreDescriptor] = []
    var selectedStoreId = IronsmithStoreConstants.communityStoreId
    var discoverApps: [StoreAppListing] = []
    var publishedApps: [StoreAppListing] = []
    var selectedAppID: String?
    var selectedAppDetail: StoreAppListing?
    var searchText = ""
    var isLoadingStores = false
    var isLoadingDiscover = false
    var isLoadingPublished = false
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

    var selectedApp: StoreAppListing? {
        selectedAppDetail
            ?? discoverApps.first { $0.id == selectedAppID }
            ?? publishedApps.first { $0.id == selectedAppID }
    }

    func loadInitial(inferenceStore: InferenceStore) async {
        guard stores.isEmpty else { return }
        await loadStores()
        await refreshDiscover()
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
               let firstStore = stores.first {
                selectedStoreId = firstStore.id
            }
        } catch {
            present(error)
        }
    }

    func refreshDiscover() async {
        isLoadingDiscover = true
        defer { isLoadingDiscover = false }
        do {
            let page = try await client.listApps(
                selectedStoreId,
                .discover,
                searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                nil
            )
            discoverApps = page.apps
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func refreshPublished() async {
        isLoadingPublished = true
        defer { isLoadingPublished = false }
        do {
            let page = try await client.listApps(selectedStoreId, .mine, nil, nil)
            publishedApps = page.apps
            reconcileSelection()
        } catch {
            present(error)
        }
    }

    func select(_ app: StoreAppListing) {
        selectedAppID = app.id
        selectedAppDetail = app
        Task {
            await loadDetail(for: app)
        }
    }

    func handle(_ route: IronsmithStoreRoute) {
        switch route {
        case .root:
            selectedTab = .discover
        case .published:
            selectedTab = .published
            Task { await refreshPublished() }
        case .publishedApp(let appId):
            selectedTab = .published
            Task {
                await refreshPublished()
                if let app = publishedApps.first(where: { $0.id == appId }) {
                    select(app)
                }
            }
        }
    }

    func isOwnPublishedApp(_ app: StoreAppListing) -> Bool {
        publishedApps.contains { $0.id == app.id }
    }

    func installDisposition(for app: StoreAppListing, tools: [Tool]) -> StoreAppInstallDisposition {
        let linkedTools = tools.filter { $0.storeAppId == app.id }
        if let currentTool = linkedTools.first(where: { localSourceHash(for: $0) == app.currentVersion.sourceSha256 }) {
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
        _ app: StoreAppListing,
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

    func setStatus(_ app: StoreAppListing, status: StoreAppStatus) async {
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
        from app: StoreAppListing,
        isOwnApp: Bool,
        modelContext: ModelContext,
        routeStore: IronsmithRouteStore,
        inferenceStore: InferenceStore
    ) async throws {
        let defaults = ToolLibraryStore.defaultGenerationSettings(from: inferenceStore.generationPreferences)
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
        app: StoreAppListing,
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

    private func loadDetail(for app: StoreAppListing) async {
        do {
            selectedAppDetail = try await client.fetchApp(app.storeId, app.id)
        } catch {
            selectedAppDetail = app
        }
    }

    private func applyStoreLinkage(
        _ app: StoreAppListing,
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

    private func replacePublishedApp(_ app: StoreAppListing) {
        if let index = publishedApps.firstIndex(where: { $0.id == app.id }) {
            publishedApps[index] = app
        } else {
            publishedApps.insert(app, at: 0)
        }
    }

    private func reconcileSelection() {
        guard let selectedAppID else {
            if let first = discoverApps.first ?? publishedApps.first {
                select(first)
            }
            return
        }
        if discoverApps.contains(where: { $0.id == selectedAppID })
            || publishedApps.contains(where: { $0.id == selectedAppID }) {
            return
        }
        selectedAppDetail = nil
        self.selectedAppID = nil
    }

    private func present(_ error: Error) {
        errorMessage = IronsmithErrorPresentation.message(for: error)
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
