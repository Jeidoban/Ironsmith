import AppKit
import SwiftUI

struct StoreAppDetailView: View {
    let app: StoreAppDetail?
    let isLoading: Bool
    let isWorking: Bool
    let workingVersionID: String?
    let installDisposition: StoreAppInstallDisposition
    let versionInstallDisposition: (StoreAppDetail, StoreVersionMetadata) -> StoreAppInstallDisposition
    let onGet: (StoreAppDetail) -> Void
    let onOpenRemix: (StoreRemixMetadata) -> Void
    let onOpenCreator: (String, String) -> Void
    let loadSource: (StoreAppDetail, StoreVersionMetadata) async throws -> String
    let selectedModelName: String?
    let onAsk: (StoreAppDetail, StoreAppSourceStore, StoreAppQuestionStore) -> Void
    let onInstallVersion: (StoreAppDetail, StoreVersionMetadata) -> Void

    @State private var expandedVersionID: String?
    @State private var sourceVersion: StoreVersionMetadata?
    @State private var sourceStore = StoreAppSourceStore()
    @State private var questionSourceStore = StoreAppSourceStore()
    @State private var questionStore = StoreAppQuestionStore()

    var body: some View {
        Group {
            if let app {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        StoreDetailHeroView(
                            app: app,
                            isWorking: isWorking,
                            installDisposition: installDisposition,
                            onGet: { onGet(app) },
                            onViewSource: { showSource(for: app.currentVersion) }
                        )

                        StoreDetailMetadataStrip(
                            app: app,
                            onOpenCreator: onOpenCreator,
                            onOpenRemix: onOpenRemix
                        )

                        if let screenshot = app.screenshots.first {
                            StoreDetailScreenshot(asset: screenshot)
                        }

                        Text(app.description)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        StoreAppQuestionSection(
                            app: app,
                            sourceStore: questionSourceStore,
                            questionStore: questionStore,
                            selectedModelName: selectedModelName,
                            hasSelectedModel: selectedModelName != nil,
                            onAsk: { onAsk(app, questionSourceStore, questionStore) }
                        )

                        StorePermissionsSection(version: app.currentVersion)

                        StoreVersionsCard(
                            app: app,
                            expandedVersionID: $expandedVersionID,
                            isWorking: isWorking,
                            workingVersionID: workingVersionID,
                            installDisposition: versionInstallDisposition,
                            onViewSource: showSource,
                            onInstall: onInstallVersion
                        )
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: app.currentVersion.id) {
                    expandedVersionID = app.currentVersion.id
                    sourceStore.reset()
                    questionSourceStore.reset()
                    questionStore.reset()
                }
                .sheet(item: $sourceVersion) { version in
                    StoreSourceCodeSheet(
                        app: app,
                        version: version,
                        sourceStore: sourceStore,
                        loadSourceCode: { try await loadSource(app, version) }
                    )
                }
                .onDisappear {
                    questionStore.cancel()
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StoreEmptyStateView(title: "App not found", systemImage: "square.grid.2x2")
            }
        }
    }

    private func showSource(for version: StoreVersionMetadata) {
        sourceVersion = version
    }
}

private struct StoreDetailHeroView: View {
    let app: StoreAppDetail
    let isWorking: Bool
    let installDisposition: StoreAppInstallDisposition
    let onGet: () -> Void
    let onViewSource: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            StoreIconView(url: app.iconAsset?.url, size: 104)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.largeTitle.weight(.semibold))
                Text(app.shortDescription)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(installDisposition.buttonTitle, action: onGet)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)

                    Button("View Source", action: onViewSource)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)

                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.top, 6)
                .disabled(isWorking)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StoreAppQuestionSection: View {
    let app: StoreAppDetail
    let sourceStore: StoreAppSourceStore
    let questionStore: StoreAppQuestionStore
    let selectedModelName: String?
    let hasSelectedModel: Bool
    let onAsk: () -> Void

    var body: some View {
        @Bindable var questionStore = questionStore

        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about this app")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 14) {
                if let selectedModelName {
                    Text("Using \(selectedModelName)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !hasSelectedModel {
                    Text("Choose an AI model in Settings to ask questions about this app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField(
                        "Ask anything about this app",
                        text: $questionStore.question,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(!hasSelectedModel || questionStore.isAnswering)
                    .onSubmit(submitQuestion)

                    if questionStore.isAnswering {
                        Button("Stop", action: questionStore.cancel)
                            .controlSize(.small)
                    } else {
                        Button("Ask", action: submitQuestion)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canSubmit)
                    }
                }

                if let submittedQuestion = questionStore.submittedQuestion {
                    Divider()
                    Text(submittedQuestion)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if questionStore.isAnswering, questionStore.answer.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(sourceStore.isLoading ? "Loading source code…" : "Thinking…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if !questionStore.answer.isEmpty {
                    Text(IronsmithMarkdown.attributedString(questionStore.answer))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = questionStore.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canSubmit: Bool {
        hasSelectedModel
            && !questionStore.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !questionStore.isAnswering
    }

    private func submitQuestion() {
        guard canSubmit else { return }
        onAsk()
    }
}

private struct StoreSourceCodeSheet: View {
    let app: StoreAppDetail
    let version: StoreVersionMetadata
    let sourceStore: StoreAppSourceStore
    let loadSourceCode: () async throws -> String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(app.name) Source")
                        .font(.title2.weight(.semibold))
                    Text("Version \(version.versionNumber) · ContentView.swift")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Group {
                if sourceStore.sourceVersionID == version.id,
                   let sourceCode = sourceStore.sourceCode
                {
                    StoreSourceCodeTextView(sourceCode: sourceCode)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                } else if sourceStore.isLoading {
                    ProgressView("Loading source code…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = sourceStore.loadErrorMessage {
                    ContentUnavailableView(
                        "Source Code Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Loading source code…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let editorErrorMessage = sourceStore.editorErrorMessage {
                Text(editorErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if sourceStore.loadErrorMessage != nil {
                    Button("Retry", action: loadSource)
                }
                Spacer()
                Button("Open in Default Editor") {
                    sourceStore.openInDefaultEditor(for: app, version: version)
                }
                .disabled(sourceStore.sourceVersionID != version.id || sourceStore.sourceCode == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 560)
        .task(id: version.id) {
            _ = try? await sourceStore.loadSource(for: version, using: loadSourceCode)
        }
    }

    private func loadSource() {
        Task {
            _ = try? await sourceStore.loadSource(for: version, using: loadSourceCode)
        }
    }
}

private struct StoreSourceCodeTextView: NSViewRepresentable {
    let sourceCode: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = NSSize(width: 1, height: 1)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = sourceCode
        textView.sizeToFit()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
            textView.string != sourceCode
        else { return }

        textView.string = sourceCode
        textView.sizeToFit()
    }
}

private struct StoreDetailMetadataStrip: View {
    let app: StoreAppDetail
    let onOpenCreator: (String, String) -> Void
    let onOpenRemix: (StoreRemixMetadata) -> Void
    @State private var isShowingLicense = false

    private var columns: [GridItem] {
        if app.remix != nil {
            return [GridItem(.adaptive(minimum: 128), spacing: 12, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            if let handle = app.authorHandle, !handle.isEmpty {
                StoreDetailCreatorMetadataItem(
                    displayName: app.authorDisplayName,
                    handle: handle,
                    action: { onOpenCreator(app.authorDisplayName, handle) }
                )
            } else {
                StoreDetailMetadataItem(title: "Creator", value: app.creatorDisplayText)
            }
            if let remix = app.remix {
                if remix.isDeleted {
                    StoreDetailMetadataItem(title: "Remixed From", value: "[Deleted]")
                } else {
                    StoreDetailLinkedMetadataItem(
                        title: "Remixed From",
                        value: remix.appName,
                        action: { onOpenRemix(remix) }
                    )
                }
            }
            StoreDetailMetadataItem(
                title: "Version",
                value: String(app.currentVersion.versionNumber)
            )
            StoreDetailMetadataItem(title: "Category", value: app.category.title)
            StoreDetailLinkedMetadataItem(
                title: "License",
                value: app.currentVersion.license.title,
                action: { isShowingLicense = true }
            )
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $isShowingLicense) {
            StoreLicenseDetailSheet(
                license: app.currentVersion.license,
                documents: StoreLegalDocumentRenderer.render(
                    appName: app.name,
                    currentVersionId: app.currentVersion.id,
                    primaryLicense: app.currentVersion.license,
                    attributions: app.currentVersion.legalAttributions
                ),
                inheritedAttributions: app.currentVersion.legalAttributions.filter {
                    $0.versionId != app.currentVersion.id
                }
            )
        }
    }

}

struct StoreLicenseDetailSheet: View {
    let license: StoreLicenseIdentifier
    let documents: StoreLegalDocuments
    let inheritedAttributions: [StoreLegalAttribution]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(license.title)
                        .font(.title2.weight(.semibold))
                    Text(license.summary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if !inheritedAttributions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Includes material under")
                        .font(.headline)
                    ForEach(inheritedAttributions, id: \.versionId) { attribution in
                        Text(
                            "\(attribution.license.title) — \(attribution.appName), \(attribution.holderDisplayName)"
                        )
                        .font(.callout)
                    }
                }
            }

            TabView {
                legalText(documents.license)
                    .tabItem { Text("License") }
                legalText(documents.notice)
                    .tabItem { Text("Notice") }
                legalText(documents.attributions)
                    .tabItem { Text("Attributions") }
            }
        }
        .padding(20)
        .frame(width: 680, height: 620)
    }

    private func legalText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

private struct StoreDetailCreatorMetadataItem: View {
    let displayName: String
    let handle: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CREATOR")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Button(action: action) {
                Text("\(Text(displayName).bold()) · @\(handle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

private struct StoreDetailLinkedMetadataItem: View {
    let title: String
    let value: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Button(action: action) {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

private struct StoreDetailMetadataItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct StoreDetailScreenshot: View {
    let asset: StoreAsset

    var body: some View {
        Group {
            if let url = asset.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        StoreImagePlaceholder(systemImage: "photo")
                            .aspectRatio(aspectRatio, contentMode: .fit)
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(aspectRatio, contentMode: .fit)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                StoreImagePlaceholder(systemImage: "photo")
                    .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .frame(maxWidth: maximumDisplayWidth)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var aspectRatio: CGFloat {
        guard asset.width > 0, asset.height > 0 else { return 16 / 10 }
        return CGFloat(asset.width) / CGFloat(asset.height)
    }

    private var maximumDisplayWidth: CGFloat {
        guard aspectRatio <= 1 else { return .infinity }
        return 560 * aspectRatio
    }
}

private struct StorePermissionsSection: View {
    let version: StoreVersionMetadata

    private var permissions: [StorePermissionPresentation] {
        StorePermissionPresentation.items(for: version)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 250), spacing: 28, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions")
                .font(.title2.weight(.semibold))

            Group {
                if permissions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                        Text("No Additional Permissions")
                            .font(.headline)
                        Text("This version does not request additional sandbox or system resources.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(permissions) { permission in
                            StorePermissionItemView(permission: permission)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct StorePermissionItemView: View {
    let permission: StorePermissionPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: permission.systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(.headline)
                Text(permission.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

nonisolated struct StorePermissionPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let explanation: String
    let systemImage: String

    static func items(for version: StoreVersionMetadata) -> [Self] {
        items(for: version.generationSettings.toolSettings)
    }

    static func items(for settings: ToolGenerationSettings) -> [Self] {
        let sandbox: [Self] = settings.sandboxEnabled
            ? settings.sandboxPermissions.enabledPermissions.map { permission in
                switch permission {
                case .incomingConnections:
                    Self(
                        id: "sandbox.\(permission.rawValue)",
                        title: permission.displayName,
                        explanation: "Accept connections from other devices",
                        systemImage: "server.rack"
                    )
                case .outgoingConnections:
                    Self(
                        id: "sandbox.\(permission.rawValue)",
                        title: permission.displayName,
                        explanation: "Connect to websites and online services",
                        systemImage: "network"
                    )
                case .userSelectedFiles:
                    Self(
                        id: "sandbox.userSelectedFiles",
                        title: permission.displayName,
                        explanation: "Access to files you choose",
                        systemImage: "folder.badge.plus"
                    )
                case .downloadsFolder:
                    Self(
                        id: "sandbox.\(permission.rawValue)",
                        title: permission.displayName,
                        explanation: "Read and write items in your Downloads folder",
                        systemImage: "tray.and.arrow.down"
                    )
                case .picturesFolder:
                    Self(
                        id: "sandbox.\(permission.rawValue)",
                        title: permission.displayName,
                        explanation: "Read and write images in your Pictures folder",
                        systemImage: "photo.on.rectangle"
                    )
                case .musicFolder:
                    Self(
                        id: "sandbox.\(permission.rawValue)",
                        title: permission.displayName,
                        explanation: "Read and write music in your Music folder",
                        systemImage: "music.note"
                    )
                case .moviesFolder:
                    Self(
                        id: "sandbox.\(permission.rawValue)",
                        title: permission.displayName,
                        explanation: "Read and write videos in your Movies folder",
                        systemImage: "film"
                    )
                }
            }
            : []
        let resources = settings.resourcePermissions.enabledPermissions.map { permission in
            Self(
                id: "resource.\(permission.rawValue)",
                title: permission.displayName,
                explanation: explanation(for: permission),
                systemImage: systemImage(for: permission)
            )
        }
        return sandbox + resources
    }

    private static func systemImage(for permission: GeneratedAppResourcePermission) -> String {
        switch permission {
        case .microphone: "mic"
        case .camera: "camera"
        case .location: "location"
        case .contacts: "person.crop.circle"
        case .calendar: "calendar"
        case .photoLibrary: "photo.on.rectangle"
        case .appleEvents: "gearshape.2"
        }
    }

    private static func explanation(for permission: GeneratedAppResourcePermission) -> String {
        switch permission {
        case .microphone: "Access to audio input"
        case .camera: "Access to photo and video capture"
        case .location: "Access to your current location"
        case .contacts: "Access to contact information"
        case .calendar: "Access to calendar events"
        case .photoLibrary: "Access to photos and videos"
        case .appleEvents: "Permission to automate other apps"
        }
    }
}

private struct StoreVersionsCard: View {
    let app: StoreAppDetail
    @Binding var expandedVersionID: String?
    let isWorking: Bool
    let workingVersionID: String?
    let installDisposition: (StoreAppDetail, StoreVersionMetadata) -> StoreAppInstallDisposition
    let onViewSource: (StoreVersionMetadata) -> Void
    let onInstall: (StoreAppDetail, StoreVersionMetadata) -> Void

    private var versions: [StoreVersionMetadata] {
        StoreVersionPresentation.newestFirst(app.versions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Versions")
                .font(.title2.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    StoreVersionAccordionRow(
                        version: version,
                        isCurrent: StoreVersionPresentation.isCurrent(version, in: app),
                        isExpanded: Binding(
                            get: { expandedVersionID == version.id },
                            set: { expandedVersionID = $0 ? version.id : nil }
                        ),
                        isWorking: isWorking,
                        isThisVersionWorking: workingVersionID == version.id,
                        installDisposition: installDisposition(app, version),
                        onViewSource: { onViewSource(version) },
                        onInstall: { onInstall(app, version) }
                    )
                    if index < versions.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 18)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct StoreVersionAccordionRow: View {
    let version: StoreVersionMetadata
    let isCurrent: Bool
    @Binding var isExpanded: Bool
    let isWorking: Bool
    let isThisVersionWorking: Bool
    let installDisposition: StoreAppInstallDisposition
    let onViewSource: () -> Void
    let onInstall: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                StoreVersionMetadataList(version: version)
                HStack {
                    Button(installDisposition.buttonTitle, action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(isWorking)
                    Button("View Source", action: onViewSource)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(isWorking)
                    if isThisVersionWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
            }
            .padding(.bottom, 16)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Version \(version.versionNumber)")
                        .font(.headline)
                    Text(StoreVersionPresentation.formattedDate(version.publishedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isCurrent {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(.automatic)
    }
}

private struct StoreVersionMetadataList: View {
    let version: StoreVersionMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Published", StoreVersionPresentation.formattedDate(version.publishedAt))
            row("App Type", version.generationSettings.appKind.displayName)
            row("Permissions", StoreVersionPresentation.permissionsSummary(version))
            row("License", version.license.title)
            row("Runtime", version.runtimeVersion)
            row("Source Hash", version.sourceSha256, monospaced: true)
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption.weight(.medium))
    }
}

nonisolated enum StoreVersionPresentation {
    static func isCurrent(_ version: StoreVersionMetadata, in app: StoreAppDetail) -> Bool {
        version.id == app.currentVersion.id
    }

    static func newestFirst(_ versions: [StoreVersionMetadata]) -> [StoreVersionMetadata] {
        versions.sorted { lhs, rhs in
            if lhs.versionNumber != rhs.versionNumber {
                return lhs.versionNumber > rhs.versionNumber
            }
            return lhs.publishedAt > rhs.publishedAt
        }
    }

    static func permissionsSummary(_ version: StoreVersionMetadata) -> String {
        let names = StorePermissionPresentation.items(for: version).map(\.title)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    static func formattedDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .omitted) ?? value
    }
}
