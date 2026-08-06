import SwiftData
import SwiftUI

private let storeAppGridColumns = [
    GridItem(.adaptive(minimum: 340), spacing: 28, alignment: .top)
]

struct StoreWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @Query(sort: \Tool.updatedAt, order: .reverse) private var tools: [Tool]
    @State private var store = StoreWindowStore()
    @State private var path: [StoreNavigationDestination] = []
    @State private var sidebarSelection: StoreSidebarSelection? = .discover
    @State private var categoryRefreshToken = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            StoreSidebarView(
                selection: $sidebarSelection,
                searchText: $store.searchText
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch sidebarSelection ?? .discover {
                    case .discover:
                        StoreDiscoverHomeView(
                            store: store,
                            tools: tools,
                            inferenceStore: inferenceStore,
                            onOpen: openApp,
                            onSeeAll: openSection,
                            onGet: install
                        )
                    case .category(let category):
                        StoreSectionAppsView(
                            section: StoreSectionRoute(category: category),
                            refreshToken: categoryRefreshToken,
                            store: store,
                            tools: tools,
                            inferenceStore: inferenceStore,
                            onOpen: openApp,
                            onGet: install
                        )
                    case .published:
                        StorePublishedListView(
                            store: store,
                            tools: tools,
                            inferenceStore: inferenceStore,
                            onOpen: openApp,
                            onUpdateVersion: { tool in
                                routeStore.open(.toolLibrary(.publishTool(tool.id)))
                            }
                        )
                    }
                }
                .navigationTitle(navigationTitle)
                .navigationDestination(for: StoreNavigationDestination.self) { destination in
                    switch destination {
                    case .app(let appRoute):
                        StoreAppDetailDestinationView(
                            appID: appRoute.appID,
                            storeID: appRoute.storeID,
                            store: store,
                            tools: tools,
                            modelContext: modelContext,
                            routeStore: routeStore,
                            inferenceStore: inferenceStore,
                            onOpenCreator: openCreator
                        )
                    case .section(let section):
                        StoreSectionAppsView(
                            section: section,
                            refreshToken: 0,
                            store: store,
                            tools: tools,
                            inferenceStore: inferenceStore,
                            onOpen: openApp,
                            onGet: install
                        )
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: store.searchText) { _, _ in
            searchTask?.cancel()
            store.searchResultsNextOffset = 0
            store.searchResultsHasMore = false
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await store.refreshHome(showLoadingIndicator: false)
                } else {
                    sidebarSelection = .discover
                    path = []
                    await store.refreshDiscover()
                }
            }
        }
        .onChange(of: sidebarSelection) { _, selection in
            path = []
            if selection != .discover {
                store.searchText = ""
            }
            if selection == .discover {
                Task { await store.refreshHome(showLoadingIndicator: false) }
            } else if selection == .published {
                Task { await store.refreshPublished() }
            }
        }
        .onChange(of: store.contentRevision) { _, _ in
            Task { await refreshStoreContent() }
        }
        .task {
            await store.loadInitial(inferenceStore: inferenceStore)
            if let route = routeStore.consumeStoreRoute() {
                handleStoreRoute(route)
            }
        }
        .onChange(of: routeStore.pendingStoreRoute) { _, _ in
            guard let route = routeStore.consumeStoreRoute() else { return }
            handleStoreRoute(route)
        }
        .alert(
            "Ironsmith Store",
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

    private func openApp(_ app: StoreAppSummary) {
        store.select(app)
        path.append(.app(StoreAppRoute(app: app)))
    }

    private func openSection(_ section: StoreHomeSection) {
        path.append(.section(StoreSectionRoute(section: section)))
    }

    private func openCreator(displayName: String, handle: String) {
        path.append(
            .section(StoreSectionRoute(creatorDisplayName: displayName, handle: handle))
        )
    }

    private func install(_ app: StoreAppSummary, mode: StoreToolImportMode = .get) {
        Task {
            await store.install(
                app,
                mode: mode,
                tools: tools,
                modelContext: modelContext,
                routeStore: routeStore,
                inferenceStore: inferenceStore
            )
        }
    }

    private var navigationTitle: String {
        switch sidebarSelection ?? .discover {
        case .discover: "Ironsmith Store"
        case .category(let category): category.title
        case .published: "Published"
        }
    }

    @MainActor
    private func refreshStoreContent() async {
        if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await store.refreshHome(showLoadingIndicator: false)
        } else {
            await store.refreshDiscover(showLoadingIndicator: false)
        }
        if inferenceStore.ironsmithSession != nil {
            await store.refreshPublished(showLoadingIndicator: false)
        }
        categoryRefreshToken += 1
    }

    @MainActor
    private func handleStoreRoute(_ route: IronsmithStoreRoute) {
        switch route {
        case .root:
            sidebarSelection = .discover
            path = []
            Task { await store.refreshHome(showLoadingIndicator: false) }
        case .published:
            sidebarSelection = .published
            path = []
            Task { await store.refreshPublished() }
        case .publishedApp(let appID):
            sidebarSelection = .published
            path = []
            Task { @MainActor in
                await store.refreshHome(showLoadingIndicator: false)
                await store.refreshPublished(showLoadingIndicator: false)
                categoryRefreshToken += 1
                if let app = store.publishedApps.first(where: { $0.id == appID }) {
                    store.select(app)
                    path = [.app(StoreAppRoute(app: app))]
                }
            }
        }
    }
}

private enum StoreNavigationDestination: Hashable {
    case app(StoreAppRoute)
    case section(StoreSectionRoute)
}

private struct StoreAppRoute: Hashable {
    let appID: String
    let storeID: String

    init(app: StoreAppSummary) {
        appID = app.id
        storeID = app.storeId
    }
}

private enum StoreSidebarSelection: Hashable {
    case discover
    case category(StoreAppCategory)
    case published
}

private struct StoreSidebarView: View {
    @Binding var selection: StoreSidebarSelection?
    @Binding var searchText: String

    var body: some View {
        List(selection: $selection) {
            Label("Discover", systemImage: "sparkles")
                .tag(StoreSidebarSelection.discover)

            ForEach(StoreAppCategory.allCases) { category in
                Label(category.title, systemImage: category.systemImage)
                    .tag(StoreSidebarSelection.category(category))
            }

            Label("Published", systemImage: "square.and.arrow.up")
                .tag(StoreSidebarSelection.published)
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    }
}

private struct StoreSectionRoute: Hashable, Identifiable {
    let id: String
    let title: String
    let sort: StoreAppListSort
    let category: StoreAppCategory?
    let creatorDisplayName: String?
    let creatorHandle: String?

    var showsSortControl: Bool {
        category != nil || creatorHandle != nil
    }

    init(section: StoreHomeSection) {
        id = section.id
        title = section.title
        sort = section.sort
        category = section.category
        creatorDisplayName = nil
        creatorHandle = nil
    }

    init(category: StoreAppCategory) {
        id = "category-\(category.rawValue)"
        title = category.title
        sort = .recent
        self.category = category
        creatorDisplayName = nil
        creatorHandle = nil
    }

    init(creatorDisplayName: String, handle: String) {
        id = "creator-\(handle)"
        title = creatorDisplayName
        sort = .recent
        category = nil
        self.creatorDisplayName = creatorDisplayName
        creatorHandle = handle
    }
}

private struct StoreDiscoverHomeView: View {
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let onOpen: (StoreAppSummary) -> Void
    let onSeeAll: (StoreHomeSection) -> Void
    let onGet: (StoreAppSummary, StoreToolImportMode) -> Void

    private var isSearching: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if isSearching {
                    StoreSearchResultsView(
                        store: store,
                        tools: tools,
                        inferenceStore: inferenceStore,
                        onOpen: onOpen,
                        onGet: onGet
                    )
                } else if store.isLoadingDiscover, store.homeSections.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else if store.homeSections.isEmpty {
                    StoreEmptyStateView(title: "No apps yet", systemImage: "square.grid.2x2")
                        .frame(minHeight: 420)
                } else {
                    if store.isLoadingDiscover {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 28)
                    }
                    ForEach(store.homeSections.filter { $0.category == nil }) { section in
                        StoreHomeSectionView(
                            section: section,
                            tools: tools,
                            inferenceStore: inferenceStore,
                            workingAppID: store.workingAppID,
                            actionTitle: {
                                store.installDisposition(for: $0, tools: tools).buttonTitle
                            },
                            onOpen: onOpen,
                            onSeeAll: { onSeeAll(section) },
                            onGet: onGet
                        )
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
    }
}

private struct StoreSearchResultsView: View {
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let onOpen: (StoreAppSummary) -> Void
    let onGet: (StoreAppSummary, StoreToolImportMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search Results")
                .font(.largeTitle.weight(.semibold))
                .padding(.horizontal, 28)

            if store.isLoadingDiscover, store.searchResults.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if store.searchResults.isEmpty {
                StoreEmptyStateView(title: "No search results", systemImage: "magnifyingglass")
                    .frame(minHeight: 360)
            } else {
                StoreAppRowsView(
                    apps: store.searchResults,
                    workingAppID: store.workingAppID,
                    actionTitle: {
                        store.installDisposition(for: $0, tools: tools).buttonTitle
                    },
                    onOpen: onOpen,
                    onAction: { onGet($0, .get) },
                    onApproachingEnd: {
                        await store.loadMoreSearchResults()
                    }
                )
                .padding(.horizontal, 28)

                StorePaginationProgressView(isLoading: store.isLoadingMoreSearchResults)
            }
        }
    }
}

private struct StoreHomeSectionView: View {
    let section: StoreHomeSection
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let workingAppID: String?
    let actionTitle: (StoreAppSummary) -> String
    let onOpen: (StoreAppSummary) -> Void
    let onSeeAll: () -> Void
    let onGet: (StoreAppSummary, StoreToolImportMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button("See All", action: onSeeAll)
                    .buttonStyle(.plain)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 28)

            LazyVGrid(columns: storeAppGridColumns, alignment: .leading, spacing: 0) {
                ForEach(Array(section.apps.prefix(6))) { app in
                    VStack(spacing: 0) {
                        StoreAppStoreRowView(
                            app: app,
                            actionTitle: actionTitle(app),
                            isWorking: workingAppID == app.id,
                            onOpen: { onOpen(app) },
                            onAction: { onGet(app, .get) }
                        )
                        Divider()
                            .padding(.leading, 88)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
    }
}

private struct StoreSectionAppsView: View {
    let section: StoreSectionRoute
    let refreshToken: Int
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let onOpen: (StoreAppSummary) -> Void
    let onGet: (StoreAppSummary, StoreToolImportMode) -> Void
    @State private var apps: [StoreAppSummary] = []
    @State private var nextOffset = 0
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var paginationRevision = 0
    @State private var selectedSort: StoreAppListSort?

    private var activeSort: StoreAppListSort {
        selectedSort ?? section.sort
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.largeTitle.weight(.semibold))
                        if let creatorHandle = section.creatorHandle {
                            Text("@\(creatorHandle)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if section.showsSortControl {
                        HStack(spacing: 6) {
                            Text("Sort by")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Picker("Sort by", selection: sortBinding) {
                                ForEach(StoreAppListSort.allCases) { sort in
                                    Text(sort.title).tag(sort)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 28)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if apps.isEmpty {
                    StoreEmptyStateView(
                        title: "No apps in this section", systemImage: "square.grid.2x2"
                    )
                    .frame(minHeight: 360)
                } else {
                    StoreAppRowsView(
                        apps: apps,
                        workingAppID: store.workingAppID,
                        actionTitle: {
                            store.installDisposition(for: $0, tools: tools).buttonTitle
                        },
                        onOpen: onOpen,
                        onAction: { onGet($0, .get) },
                        onApproachingEnd: loadMore
                    )
                    .padding(.horizontal, 28)

                    StorePaginationProgressView(isLoading: isLoadingMore)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .navigationTitle(section.title)
        .task(id: "\(section.id)-\(refreshToken)-\(activeSort.rawValue)") {
            await reload()
        }
    }

    private var sortBinding: Binding<StoreAppListSort> {
        Binding(
            get: { activeSort },
            set: { sort in
                guard sort != activeSort else { return }
                paginationRevision += 1
                selectedSort = sort
            }
        )
    }

    private func reload() async {
        paginationRevision += 1
        let revision = paginationRevision
        let showsLoadingIndicator = apps.isEmpty
        if showsLoadingIndicator {
            isLoading = true
        }
        defer {
            if showsLoadingIndicator, paginationRevision == revision {
                isLoading = false
            }
        }
        guard
            let page = await store.loadSectionApps(
                sort: activeSort,
                category: section.category,
                creatorHandle: section.creatorHandle
            )
        else {
            return
        }
        guard paginationRevision == revision else {
            return
        }
        apps = page.apps
        nextOffset = page.apps.count
        hasMore = page.hasMore
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else {
            return
        }
        let offset = nextOffset
        let revision = paginationRevision
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard
            let page = await store.loadSectionApps(
                sort: activeSort,
                category: section.category,
                creatorHandle: section.creatorHandle,
                offset: offset
            )
        else {
            return
        }
        guard paginationRevision == revision, nextOffset == offset else {
            return
        }
        let existingIDs = Set(apps.map(\.id))
        apps.append(contentsOf: page.apps.filter { !existingIDs.contains($0.id) })
        nextOffset += page.apps.count
        hasMore = page.hasMore
    }
}

private struct StorePaginationProgressView: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
    }
}

private struct StoreAppRowsView: View {
    let apps: [StoreAppSummary]
    let workingAppID: String?
    let actionTitle: (StoreAppSummary) -> String
    let onOpen: (StoreAppSummary) -> Void
    let onAction: (StoreAppSummary) -> Void
    var onApproachingEnd: (() async -> Void)? = nil

    private let paginationPrefetchItemCount = 4

    var body: some View {
        LazyVGrid(columns: storeAppGridColumns, alignment: .leading, spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                VStack(spacing: 0) {
                    StoreAppStoreRowView(
                        app: app,
                        actionTitle: actionTitle(app),
                        isWorking: workingAppID == app.id,
                        onOpen: { onOpen(app) },
                        onAction: { onAction(app) }
                    )
                    Divider()
                        .padding(.leading, 88)
                }
                .onAppear {
                    guard
                        index >= max(apps.count - paginationPrefetchItemCount, 0),
                        let onApproachingEnd
                    else {
                        return
                    }
                    Task {
                        await onApproachingEnd()
                    }
                }
            }
        }
    }
}

private struct StoreAppStoreRowView: View {
    let app: StoreAppSummary
    let actionTitle: String
    let isWorking: Bool
    let onOpen: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onOpen) {
                HStack(spacing: 16) {
                    StoreIconView(url: app.icon?.url, size: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(app.shortDescription)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 16)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 88)
            } else {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .frame(width: 88)
            }
        }
        .frame(minHeight: 92)
    }
}

private struct StorePublishedListView: View {
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let onOpen: (StoreAppSummary) -> Void
    let onUpdateVersion: (Tool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Published")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 28)

                if inferenceStore.ironsmithSession == nil {
                    StoreEmptyStateView(
                        title: "Sign in to view published apps",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                    .frame(minHeight: 420)
                } else if store.isLoadingPublished, store.publishedApps.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if store.publishedApps.isEmpty {
                    StoreEmptyStateView(
                        title: "Published apps will appear here. Publish from your local app list.",
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(minHeight: 420)
                } else {
                    LazyVGrid(columns: storeAppGridColumns, alignment: .leading, spacing: 0) {
                        ForEach(Array(store.publishedApps.enumerated()), id: \.element.id) {
                            index, app in
                            VStack(spacing: 0) {
                                StorePublishedRowView(
                                    app: app,
                                    linkedTool: tools.first { $0.storeAppId == app.id },
                                    isWorking: store.workingAppID == app.id,
                                    onSelect: { onOpen(app) },
                                    onUpdateVersion: onUpdateVersion,
                                    onToggleStatus: {
                                        Task {
                                            await store.setStatus(
                                                app,
                                                status: app.status == .published
                                                    ? .unlisted : .published
                                            )
                                        }
                                    }
                                )
                                Divider()
                                    .padding(.leading, 72)
                            }
                            .onAppear {
                                guard
                                    index >= max(store.publishedApps.count - 4, 0)
                                else {
                                    return
                                }
                                Task {
                                    await store.loadMorePublishedApps()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)

                    StorePaginationProgressView(isLoading: store.isLoadingMorePublishedApps)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .navigationTitle("Published")
    }
}

private struct StorePublishedRowView: View {
    let app: StoreAppSummary
    let linkedTool: Tool?
    let isWorking: Bool
    let onSelect: () -> Void
    let onUpdateVersion: (Tool) -> Void
    let onToggleStatus: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    StoreIconView(url: app.icon?.url, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(
                            "\(app.status.rawValue.capitalized) · \(app.category.title) · v\(app.latestVersionNumber)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
        .frame(minHeight: 76)
    }
}

private struct StoreAppDetailDestinationView: View {
    let appID: String
    let storeID: String
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let modelContext: ModelContext
    let routeStore: IronsmithRouteStore
    let inferenceStore: InferenceStore
    let onOpenCreator: (String, String) -> Void

    var body: some View {
        StoreAppDetailView(
            app: store.selectedAppDetail?.id == appID ? store.selectedAppDetail : nil,
            isLoading: store.isLoadingDetail,
            isWorking: store.workingAppID == appID,
            workingVersionID: store.workingVersionID,
            installDisposition: detail.map {
                store.installDisposition(for: $0, tools: tools)
            } ?? .createCopy,
            canRemix: detail.map { !store.isOwnPublishedApp($0) } ?? false,
            versionInstallDisposition: { app, version in
                store.installDisposition(for: version, of: app, tools: tools)
            },
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
            },
            onOpenCreator: onOpenCreator,
            onInstallVersion: { app, version in
                Task {
                    await store.installVersion(
                        version,
                        of: app,
                        tools: tools,
                        modelContext: modelContext,
                        routeStore: routeStore,
                        inferenceStore: inferenceStore
                    )
                }
            }
        )
        .navigationTitle(detail?.name ?? "App")
        .onAppear {
            store.select(storeID: storeID, appID: appID)
        }
    }

    private var detail: StoreAppDetail? {
        guard store.selectedAppDetail?.id == appID else { return nil }
        return store.selectedAppDetail
    }
}

struct StoreIconView: View {
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

struct StoreImagePlaceholder: View {
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

struct StoreEmptyStateView: View {
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

#Preview("Store Window") {
    let container = try! IronsmithModelContainerFactory.make(isRunningTests: true)
    return StoreWindowView()
        .modelContainer(container)
        .environment(InferenceStore())
        .environment(IronsmithRouteStore(openSettingsWindow: {}))
}
