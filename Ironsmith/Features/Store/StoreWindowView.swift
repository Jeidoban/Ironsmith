import SwiftData
import SwiftUI

struct StoreWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @Query(sort: \Tool.updatedAt, order: .reverse) private var tools: [Tool]
    @State private var store = StoreWindowStore()
    @State private var path: [StoreNavigationDestination] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        NavigationStack(path: $path) {
            StoreDiscoverHomeView(
                store: store,
                tools: tools,
                inferenceStore: inferenceStore,
                onOpen: openApp,
                onSeeAll: openSection,
                onGet: install
            )
            .navigationTitle("App Store")
            .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search App Store")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task {
                            if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                            {
                                await store.refreshHome()
                            } else {
                                await store.refreshDiscover()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")

                    Button {
                        path = [.published]
                        Task { await store.refreshPublished() }
                    } label: {
                        Label("Published", systemImage: "square.and.arrow.up")
                    }
                    .help("Published")
                }
            }
            .navigationDestination(for: StoreNavigationDestination.self) { destination in
                switch destination {
                case .app(let appID):
                    StoreAppDetailDestinationView(
                        appID: appID,
                        store: store,
                        tools: tools,
                        modelContext: modelContext,
                        routeStore: routeStore,
                        inferenceStore: inferenceStore
                    )
                case .section(let section):
                    StoreSectionAppsView(
                        section: section,
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
        }
        .onChange(of: store.searchText) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await store.refreshDiscover()
            }
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

    private func openApp(_ app: StoreAppSummary) {
        store.select(app)
        path.append(.app(app.id))
    }

    private func openSection(_ section: StoreHomeSection) {
        path.append(.section(StoreSectionRoute(section: section)))
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

    @MainActor
    private func handleStoreRoute(_ route: IronsmithStoreRoute) {
        switch route {
        case .root:
            path = []
            Task { await store.refreshHome() }
        case .published:
            path = [.published]
            Task { await store.refreshPublished() }
        case .publishedApp(let appID):
            path = [.published]
            Task { @MainActor in
                await store.refreshPublished()
                if let app = store.publishedApps.first(where: { $0.id == appID }) {
                    store.select(app)
                    path = [.published, .app(app.id)]
                }
            }
        }
    }
}

private enum StoreNavigationDestination: Hashable {
    case app(String)
    case section(StoreSectionRoute)
    case published
}

private struct StoreSectionRoute: Hashable, Identifiable {
    let id: String
    let title: String
    let sort: StoreAppListSort
    let category: StoreAppCategory?

    init(section: StoreHomeSection) {
        id = section.id
        title = section.title
        sort = section.sort
        category = section.category
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
                    ForEach(store.homeSections) { section in
                        StoreHomeSectionView(
                            section: section,
                            tools: tools,
                            inferenceStore: inferenceStore,
                            workingAppID: store.workingAppID,
                            onOpen: onOpen,
                            onSeeAll: { onSeeAll(section) },
                            onGet: onGet
                        )
                    }
                }
            }
            .padding(.vertical, 24)
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

            if store.isLoadingDiscover, store.discoverApps.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if store.discoverApps.isEmpty {
                StoreEmptyStateView(title: "No search results", systemImage: "magnifyingglass")
                    .frame(minHeight: 360)
            } else {
                StoreAppRowsView(
                    apps: store.discoverApps,
                    workingAppID: store.workingAppID,
                    actionTitle: "Get",
                    onOpen: onOpen,
                    onAction: { onGet($0, .get) }
                )
                .padding(.horizontal, 28)
            }
        }
    }
}

private struct StoreHomeSectionView: View {
    let section: StoreHomeSection
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let workingAppID: String?
    let onOpen: (StoreAppSummary) -> Void
    let onSeeAll: () -> Void
    let onGet: (StoreAppSummary, StoreToolImportMode) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 430), spacing: 44, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .padding(.horizontal, 28)

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

            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(Array(section.apps.prefix(6))) { app in
                    VStack(spacing: 0) {
                        StoreAppStoreRowView(
                            app: app,
                            actionTitle: "Get",
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
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let inferenceStore: InferenceStore
    let onOpen: (StoreAppSummary) -> Void
    let onGet: (StoreAppSummary, StoreToolImportMode) -> Void
    @State private var apps: [StoreAppSummary] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(section.title)
                    .font(.largeTitle.weight(.semibold))
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
                        actionTitle: "Get",
                        onOpen: onOpen,
                        onAction: { onGet($0, .get) }
                    )
                    .padding(.horizontal, 28)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(section.title)
        .task(id: section) {
            isLoading = true
            apps = await store.loadSectionApps(sort: section.sort, category: section.category)
            isLoading = false
        }
    }
}

private struct StoreAppRowsView: View {
    let apps: [StoreAppSummary]
    let workingAppID: String?
    let actionTitle: String
    let onOpen: (StoreAppSummary) -> Void
    let onAction: (StoreAppSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(apps) { app in
                StoreAppStoreRowView(
                    app: app,
                    actionTitle: actionTitle,
                    isWorking: workingAppID == app.id,
                    onOpen: { onOpen(app) },
                    onAction: { onAction(app) }
                )
                Divider()
                    .padding(.leading, 88)
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
                    .font(.headline)
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
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
                    VStack(spacing: 0) {
                        ForEach(store.publishedApps) { app in
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
                    }
                    .padding(.horizontal, 28)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Published")
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
    @Bindable var store: StoreWindowStore
    let tools: [Tool]
    let modelContext: ModelContext
    let routeStore: IronsmithRouteStore
    let inferenceStore: InferenceStore

    var body: some View {
        StoreAppDetailView(
            app: store.selectedAppDetail?.id == appID ? store.selectedAppDetail : nil,
            isLoading: store.isLoadingDetail,
            isWorking: store.workingAppID == appID,
            installDisposition: detail.map {
                store.installDisposition(for: $0, tools: tools)
            } ?? .createCopy,
            canRemix: detail.map { !store.isOwnPublishedApp($0) } ?? false,
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
        .navigationTitle(detail?.name ?? "App")
        .task(id: appID) {
            guard store.selectedAppDetail?.id != appID,
                let summary = store.appSummary(id: appID)
            else {
                return
            }
            store.select(summary)
        }
    }

    private var detail: StoreAppDetail? {
        guard store.selectedAppDetail?.id == appID else { return nil }
        return store.selectedAppDetail
    }
}

private struct StoreAppDetailView: View {
    let app: StoreAppDetail?
    let isLoading: Bool
    let isWorking: Bool
    let installDisposition: StoreAppInstallDisposition
    let canRemix: Bool
    let onGet: (StoreAppDetail) -> Void
    let onRemix: (StoreAppDetail) -> Void

    var body: some View {
        Group {
            if let app {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 16) {
                            StoreIconView(url: app.iconAsset?.url, size: 88)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(app.name)
                                    .font(.largeTitle.weight(.semibold))
                                Text(app.shortDescription)
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(
                                    "\(app.authorDisplayName) · \(app.category.title) · Version \(app.currentVersion.versionNumber)"
                                )
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        HStack {
                            Button {
                                onGet(app)
                            } label: {
                                Label(
                                    installDisposition.buttonTitle,
                                    systemImage: installDisposition.systemImage)
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
                            .frame(maxWidth: .infinity, maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        StoreDetailMetadataView(app: app)
                        StoreVersionHistoryView(versions: app.recentVersions)
                    }
                    .padding(28)
                    .frame(maxWidth: 860, alignment: .leading)
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StoreEmptyStateView(title: "App not found", systemImage: "square.grid.2x2")
            }
        }
    }
}

private struct StoreDetailMetadataView: View {
    let app: StoreAppDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StorePermissionChipsView(
                permissions: app.currentVersion.generationSettings.permissionChips)

            LabeledContent("Category") {
                Text(app.category.title)
            }
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

private struct StoreVersionHistoryView: View {
    let versions: [StoreVersionMetadata]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Versions")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(versions) { version in
                    HStack {
                        Text("v\(version.versionNumber)")
                            .font(.subheadline.weight(.semibold))
                        Text(shortHash(version.sourceSha256))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formattedDate(version.publishedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        return String(hash.prefix(12))
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            return value
        }
        return date.formatted(date: .abbreviated, time: .omitted)
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

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let placements = layout(in: bounds.width, subviews: subviews).placements
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.frame.minX, y: bounds.minY + placement.frame.minY),
                proposal: ProposedViewSize(placement.frame.size)
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (
        size: CGSize, placements: [(index: Int, frame: CGRect)]
    ) {
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
