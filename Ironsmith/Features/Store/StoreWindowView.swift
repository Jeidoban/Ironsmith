import AppKit
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    var isPublishing = false
    var errorMessage: String?
    var publishingToolID: UUID?
    var publishName = ""
    var publishDescription = ""
    var publishDisplayName = ""
    var publishScreenshotData: Data?
    var publishScreenshotName: String?
    var isShowingPublishSheet = false

    @ObservationIgnored private let client: IronsmithStoreClient
    @ObservationIgnored private let importClient: StoreToolImportClient
    @ObservationIgnored private let buildClient: ToolBuildClient
    @ObservationIgnored private let iconClient: ToolIconClient

    init() {
        self.client = .live
        self.importClient = .live
        self.buildClient = .live()
        self.iconClient = .live()
    }

    init(
        client: IronsmithStoreClient,
        importClient: StoreToolImportClient,
        buildClient: ToolBuildClient,
        iconClient: ToolIconClient
    ) {
        self.client = client
        self.importClient = importClient
        self.buildClient = buildClient
        self.iconClient = iconClient
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

    func handle(_ route: IronsmithStoreRoute, tools: [Tool], inferenceStore: InferenceStore) {
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
        try FileManager.default.createDirectory(
            at: layout.sourceDirectoryURL,
            withIntermediateDirectories: true
        )
        try version.sourceCode.write(
            to: try layout.packageFileURL(for: layout.contentViewSourcePath),
            atomically: true,
            encoding: .utf8
        )
        try layout.fixedAppEntrySource(displayName: tool.name, settings: settings).write(
            to: try layout.packageFileURL(for: layout.appEntrySourcePath),
            atomically: true,
            encoding: .utf8
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
        try previousSource.write(
            to: try layout.packageFileURL(for: layout.contentViewSourcePath),
            atomically: true,
            encoding: .utf8
        )
        try layout.fixedAppEntrySource(displayName: tool.name, settings: settings).write(
            to: try layout.packageFileURL(for: layout.appEntrySourcePath),
            atomically: true,
            encoding: .utf8
        )
    }

    func beginPublishing(_ tool: Tool, inferenceStore: InferenceStore) async {
        await inferenceStore.refreshIronsmithAccountSummary()
        guard inferenceStore.ironsmithSession != nil else {
            errorMessage = "Sign in with Ironsmith before publishing to the App Store."
            return
        }
        publishingToolID = tool.id
        publishName = tool.name
        await refreshPublished()
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
            _ = try await client.updateProfileDisplayName(trimmed)
            await inferenceStore.refreshIronsmithAccountSummary()
            publishDisplayName = inferenceStore.ironsmithAccountSummary?.profile?.displayName ?? trimmed
        } catch {
            present(error)
        }
    }

    func publish(_ tool: Tool, modelContext: ModelContext, inferenceStore: InferenceStore) async {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            if (inferenceStore.ironsmithAccountSummary?.profile?.displayName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            {
                _ = try await client.updateProfileDisplayName(
                    publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                await inferenceStore.refreshIronsmithAccountSummary()
            }

            let source = try String(contentsOf: try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath), encoding: .utf8)
            let settings = tool.generationSettings(
                defaults: ToolLibraryStore.defaultGenerationSettings(from: inferenceStore.generationPreferences)
            )
            let app: StoreAppListing
            if let linkedApp = linkedPublishedApp(for: tool) {
                app = try await client.publishVersion(
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
                app = try await client.publishApp(
                    StorePublicationRequest(
                        storeId: selectedStoreId,
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

            applyStoreLinkage(app, to: tool)
            try modelContext.save()
            isShowingPublishSheet = false
            await refreshPublished()
            selectedTab = .published
            selectedAppID = app.id
            selectedAppDetail = app
        } catch {
            modelContext.rollback()
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

    private func loadDetail(for app: StoreAppListing) async {
        do {
            selectedAppDetail = try await client.fetchApp(app.storeId, app.id)
        } catch {
            selectedAppDetail = app
        }
    }

    func canUpdatePublishedListing(for tool: Tool) -> Bool {
        linkedPublishedApp(for: tool) != nil
    }

    func linkedPublishedApp(for tool: Tool) -> StoreAppListing? {
        guard let storeAppId = tool.storeAppId else { return nil }
        return publishedApps.first { $0.id == storeAppId }
    }

    private func applyStoreLinkage(_ app: StoreAppListing, to tool: Tool) {
        applyPublishedStoreLinkage(app, to: tool)
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

struct StoreWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @Query(sort: \Tool.updatedAt, order: .reverse) private var tools: [Tool]
    @State private var store = StoreWindowStore()
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            storeSidebar
        } content: {
            switch store.selectedTab {
            case .discover:
                StoreDiscoverListView(
                    store: store,
                    searchTask: $searchTask
                )
            case .published:
                StorePublishedListView(
                    store: store,
                    tools: tools,
                    inferenceStore: inferenceStore,
                    onUpdateVersion: { tool in
                        routeStore.open(.toolLibrary(.publishTool(tool.id)))
                    }
                )
            }
        } detail: {
            StoreAppDetailView(
                app: store.selectedApp,
                isWorking: store.workingAppID == store.selectedApp?.id,
                installDisposition: store.selectedApp.map {
                    store.installDisposition(for: $0, tools: tools)
                } ?? .createCopy,
                canRemix: store.selectedApp.map { !store.isOwnPublishedApp($0) } ?? false,
                onGet: { app in
                    Task {
                        await store.install(
                            app,
                            mode: .get,
                            tools: tools,
                            modelContext: modelContext,
                            routeStore: routeStore,
                            inferenceStore: inferenceStore
                        )
                    }
                },
                onRemix: { app in
                    Task {
                        await store.install(
                            app,
                            mode: .remix,
                            tools: tools,
                            modelContext: modelContext,
                            routeStore: routeStore,
                            inferenceStore: inferenceStore
                        )
                    }
                }
            )
        }
        .navigationTitle("App Store")
        .task {
            await store.loadInitial(inferenceStore: inferenceStore)
            if let route = routeStore.consumeStoreRoute() {
                store.handle(route, tools: tools, inferenceStore: inferenceStore)
            }
        }
        .onChange(of: routeStore.pendingStoreRoute) { _, _ in
            guard let route = routeStore.consumeStoreRoute() else { return }
            store.handle(route, tools: tools, inferenceStore: inferenceStore)
        }
        .onChange(of: store.selectedTab) { _, tab in
            if tab == .published {
                Task { await store.refreshPublished() }
            }
        }
        .alert(
            "App Store",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var storeSidebar: some View {
        List {
            ForEach(StoreSidebarTab.allCases) { tab in
                Button {
                    store.selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .foregroundStyle(store.selectedTab == tab ? .primary : .secondary)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }
}

private struct StoreDiscoverListView: View {
    @Bindable var store: StoreWindowStore
    @Binding var searchTask: Task<Void, Never>?

    var body: some View {
        List(selection: $store.selectedAppID) {
            if store.isLoadingDiscover {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if store.discoverApps.isEmpty {
                StoreEmptyStateView(
                    title: store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No apps yet"
                        : "No search results",
                    systemImage: "magnifyingglass"
                )
            } else {
                ForEach(store.discoverApps) { app in
                    StoreAppCardView(app: app)
                        .tag(app.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.select(app)
                        }
                }
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search App Store")
        .onChange(of: store.searchText) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await store.refreshDiscover()
            }
        }
        .toolbar {
            Button {
                Task { await store.refreshDiscover() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
    }
}

private struct StorePublishedListView: View {
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let onUpdateVersion: (Tool) -> Void

    var body: some View {
        List(selection: $store.selectedAppID) {
            if inferenceStore.ironsmithSession == nil {
                StoreEmptyStateView(title: "Sign in to view published apps", systemImage: "person.crop.circle.badge.exclamationmark")
            } else if store.isLoadingPublished {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if store.publishedApps.isEmpty {
                StoreEmptyStateView(
                    title: "Published apps will appear here. Publish from your local app list.",
                    systemImage: "square.and.arrow.up"
                )
            } else {
                ForEach(store.publishedApps) { app in
                    StorePublishedRowView(
                        app: app,
                        linkedTool: tools.first { $0.storeAppId == app.id },
                        isWorking: store.workingAppID == app.id,
                        onSelect: {
                            store.select(app)
                        },
                        onUpdateVersion: { tool in
                            onUpdateVersion(tool)
                        },
                        onToggleStatus: {
                            Task {
                                await store.setStatus(
                                    app,
                                    status: app.status == .published ? .unlisted : .published
                                )
                            }
                        }
                    )
                    .tag(app.id)
                }
            }
        }
        .toolbar {
            Button {
                Task { await store.refreshPublished() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
    }
}

private struct StoreAppCardView: View {
    let app: StoreAppListing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StoreIconView(url: app.iconAsset?.url, size: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(app.currentVersion.versionNumber)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(app.authorDisplayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(app.shortDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                StorePermissionChipsView(permissions: app.currentVersion.generationSettings.permissionChips)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct StorePublishedRowView: View {
    let app: StoreAppListing
    let linkedTool: Tool?
    let isWorking: Bool
    let onSelect: () -> Void
    let onUpdateVersion: (Tool) -> Void
    let onToggleStatus: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StoreIconView(url: app.iconAsset?.url, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(app.status.rawValue.capitalized) · v\(app.currentVersion.versionNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Menu {
                if let linkedTool {
                    Button("Update Version...") {
                        onUpdateVersion(linkedTool)
                    }
                }
                Button(app.status == .published ? "Unlist" : "Relist") {
                    onToggleStatus()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.vertical, 6)
    }
}

private struct StoreAppDetailView: View {
    let app: StoreAppListing?
    let isWorking: Bool
    let installDisposition: StoreAppInstallDisposition
    let canRemix: Bool
    let onGet: (StoreAppListing) -> Void
    let onRemix: (StoreAppListing) -> Void

    var body: some View {
        Group {
            if let app {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 16) {
                            StoreIconView(url: app.iconAsset?.url, size: 72)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(app.name)
                                    .font(.title2.weight(.semibold))
                                Text(app.authorDisplayName)
                                    .foregroundStyle(.secondary)
                                Text("Version \(app.currentVersion.versionNumber)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Text(app.description)
                            .font(.body)
                            .textSelection(.enabled)

                        if let screenshot = app.screenshots.first {
                            Group {
                                if let url = screenshot.url {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .scaledToFit()
                                        case .failure:
                                            StoreImagePlaceholder(systemImage: "photo")
                                        case .empty:
                                            ProgressView()
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    StoreImagePlaceholder(systemImage: "photo")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        StoreDetailMetadataView(app: app)

                        HStack {
                            Button {
                                onGet(app)
                            } label: {
                                Label(installDisposition.buttonTitle, systemImage: installDisposition.systemImage)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking)

                            if canRemix {
                                Button {
                                    onRemix(app)
                                } label: {
                                    Label("Remix", systemImage: "wand.and.sparkles")
                                }
                                .disabled(isWorking)
                            }

                            if isWorking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            } else {
                StoreEmptyStateView(title: "Select an app", systemImage: "square.grid.2x2")
            }
        }
    }
}

private struct StoreDetailMetadataView: View {
    let app: StoreAppListing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StorePermissionChipsView(permissions: app.currentVersion.generationSettings.permissionChips)

            LabeledContent("Source Hash") {
                Text(shortHash(app.currentVersion.sourceSha256))
                    .monospaced()
                    .textSelection(.enabled)
            }
            LabeledContent("Runtime") {
                Text(app.currentVersion.runtimeVersion)
                    .textSelection(.enabled)
            }
            LabeledContent("Scanner") {
                Text(app.currentVersion.scannerVersion)
                    .textSelection(.enabled)
            }
            LabeledContent("License") {
                Text(app.currentVersion.license)
            }
            if let remix = app.remix {
                LabeledContent("Remixed From") {
                    Text("\(remix.appName) v\(remix.versionNumber)")
                }
            }
        }
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(12))...\(hash.suffix(6))"
    }
}

private struct StorePublishSheetView: View {
    @Bindable var store: StoreWindowStore
    let tool: Tool
    let inferenceStore: InferenceStore
    let onPublish: () -> Void
    @State private var isChoosingScreenshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isUpdatingPublishedListing ? "Update Store Version" : "Publish to App Store")
                .font(.title3.weight(.semibold))

            if needsDisplayName {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Display Name", text: $store.publishDisplayName)
                    Button("Save Display Name") {
                        Task {
                            await store.saveDisplayName(inferenceStore: inferenceStore)
                        }
                    }
                    .disabled(store.publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            TextField("Name", text: $store.publishName)
            TextField("Description", text: $store.publishDescription, axis: .vertical)
                .lineLimit(4...8)

            HStack {
                Button {
                    isChoosingScreenshot = true
                } label: {
                    Label("Screenshot", systemImage: "photo")
                }
                Text(store.publishScreenshotName ?? "No screenshot selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    store.isShowingPublishSheet = false
                }
                Button(isUpdatingPublishedListing ? "Update" : "Publish") {
                    onPublish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPublish || store.isPublishing)
                if store.isPublishing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .fileImporter(
            isPresented: $isChoosingScreenshot,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importScreenshot(from: url)
            }
        }
    }

    private var needsDisplayName: Bool {
        (inferenceStore.ironsmithAccountSummary?.profile?.displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var isUpdatingPublishedListing: Bool {
        store.canUpdatePublishedListing(for: tool)
    }

    private var canPublish: Bool {
        !store.publishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.publishDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsDisplayName || !store.publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct StoreIconView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        StoreImagePlaceholder(systemImage: "app.dashed")
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                StoreImagePlaceholder(systemImage: "app.dashed")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct StoreImagePlaceholder: View {
    let systemImage: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.32))
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StorePermissionChipsView: View {
    let permissions: [String]

    var body: some View {
        if permissions.isEmpty {
            Text("No extra permissions")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(permissions, id: \.self) { permission in
                    Text(permission)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.45), in: Capsule())
                }
            }
        }
    }
}

private struct StoreEmptyStateView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = layout(in: bounds.width, subviews: subviews).placements
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.frame.minX, y: bounds.minY + placement.frame.minY),
                proposal: ProposedViewSize(placement.frame.size)
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [(index: Int, frame: CGRect)]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var placements: [(Int, CGRect)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            placements.append((index, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), placements)
    }
}

#Preview("Store Window") {
    let container = try! IronsmithModelContainerFactory.make(isRunningTests: true)
    return StoreWindowView()
        .modelContainer(container)
        .environment(InferenceStore())
        .environment(IronsmithRouteStore(openSettingsWindow: {}))
}
