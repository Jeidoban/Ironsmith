import SwiftData
import SwiftUI

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
                app: store.selectedAppDetail,
                isLoading: store.isLoadingDetail,
                isWorking: store.workingAppID == store.selectedAppDetail?.id,
                installDisposition: store.selectedAppDetail.map {
                    store.installDisposition(for: $0, tools: tools)
                } ?? .createCopy,
                canRemix: store.selectedAppDetail.map { !store.isOwnPublishedApp($0) } ?? false,
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
                store.handle(route)
            }
        }
        .onChange(of: routeStore.pendingStoreRoute) { _, _ in
            guard let route = routeStore.consumeStoreRoute() else { return }
            store.handle(route)
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
    let app: StoreAppSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StoreIconView(url: app.icon?.url, size: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(app.latestVersionNumber)")
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
            }
        }
        .padding(.vertical, 6)
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
            StoreIconView(url: app.icon?.url, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(app.status.rawValue.capitalized) · v\(app.latestVersionNumber)")
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
                        StoreVersionHistoryView(versions: app.recentVersions)

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
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StoreEmptyStateView(title: "Select an app", systemImage: "square.grid.2x2")
            }
        }
    }
}

private struct StoreDetailMetadataView: View {
    let app: StoreAppDetail

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
