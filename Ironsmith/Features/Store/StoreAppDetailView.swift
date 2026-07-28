import SwiftUI

struct StoreAppDetailView: View {
    let app: StoreAppDetail?
    let isLoading: Bool
    let isWorking: Bool
    let workingVersionID: String?
    let installDisposition: StoreAppInstallDisposition
    let canRemix: Bool
    let versionInstallDisposition: (StoreAppDetail, StoreVersionMetadata) -> StoreAppInstallDisposition
    let onGet: (StoreAppDetail) -> Void
    let onRemix: (StoreAppDetail) -> Void
    let onInstallVersion: (StoreAppDetail, StoreVersionMetadata) -> Void

    @State private var expandedVersionID: String?

    var body: some View {
        Group {
            if let app {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        StoreDetailHeroView(
                            app: app,
                            isWorking: isWorking,
                            installDisposition: installDisposition,
                            canRemix: canRemix,
                            onGet: { onGet(app) },
                            onRemix: { onRemix(app) }
                        )

                        StoreDetailMetadataStrip(app: app)

                        if let screenshot = app.screenshots.first {
                            StoreDetailScreenshot(asset: screenshot)
                        }

                        Text(app.description)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        StorePermissionsSection(version: app.currentVersion)

                        StoreVersionsCard(
                            app: app,
                            expandedVersionID: $expandedVersionID,
                            isWorking: isWorking,
                            workingVersionID: workingVersionID,
                            installDisposition: versionInstallDisposition,
                            onInstall: onInstallVersion
                        )
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: app.id) {
                    expandedVersionID = app.currentVersion.id
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

private struct StoreDetailHeroView: View {
    let app: StoreAppDetail
    let isWorking: Bool
    let installDisposition: StoreAppInstallDisposition
    let canRemix: Bool
    let onGet: () -> Void
    let onRemix: () -> Void

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

                    if canRemix {
                        Button("Remix", action: onRemix)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }

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

private struct StoreDetailMetadataStrip: View {
    let app: StoreAppDetail

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            StoreDetailMetadataItem(title: "Creator", value: app.authorDisplayName)
            StoreDetailMetadataItem(
                title: "Version",
                value: String(app.currentVersion.versionNumber)
            )
            StoreDetailMetadataItem(title: "Category", value: app.category.title)
            StoreDetailMetadataItem(title: "License", value: app.currentVersion.license)
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
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
        let settings = version.generationSettings.toolSettings
        let sandbox: [Self] = settings.sandboxEnabled
            ? settings.sandboxPermissions.enabledPermissions.map { permission in
                switch permission {
                case .internet:
                    Self(
                        id: "sandbox.internet",
                        title: permission.displayName,
                        explanation: "Access to network connections",
                        systemImage: "network"
                    )
                case .userSelectedFiles:
                    Self(
                        id: "sandbox.userSelectedFiles",
                        title: permission.displayName,
                        explanation: "Access to files you choose",
                        systemImage: "folder.badge.plus"
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
            row("License", version.license)
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
