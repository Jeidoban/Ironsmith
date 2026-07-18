//
//  ToolRowView.swift
//  Ironsmith
//

import AppKit
import SwiftUI

struct ToolRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let tool: Tool
    let state: ToolItemPresentationState
    let actions: ToolItemActions
    @State private var isHoveringRow = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                icon

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let generationStatusText {
                            Text(generationStatusText)
                                .font(.caption)
                                .foregroundStyle(statusStyle)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture {
                guard tool.isGenerationReady else { return }
                actions.onSelect()
            }
            .contextMenu {
                ToolItemActionsMenu(tool: tool, state: state, actions: actions)
            }

            Menu {
                ToolItemActionsMenu(tool: tool, state: state, actions: actions)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 8)
            .accessibilityLabel("App actions for \(tool.name)")
            .accessibilityHint(
                "Opens actions like run, export, view source, show in Finder, restore, or delete.")
        }
        .onHover { isHoveringRow = $0 }
        .accessibilityIdentifier("tool-row-\(tool.id.uuidString)")
    }

    private var icon: some View {
        ZStack {
            ToolIconImageView(tool: tool)
                .frame(width: 42, height: 42)

            if tool.generationState == .generating && isHoveringRow {
                Button(action: actions.onStop) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(RunToolButtonStyle())
                .help("Pause \(tool.name)")
                .accessibilityLabel("Pause \(tool.name)")
                .accessibilityIdentifier("pause-tool-\(tool.id.uuidString)")
            } else if tool.generationState == .generating {
                iconProgressOverlay("Generating \(tool.name)")
            } else if state.isLaunching {
                iconProgressOverlay("Running \(tool.name)")
            } else if state.isRestoring {
                iconProgressOverlay("Restoring \(tool.name)")
            } else if state.isRebuilding {
                iconProgressOverlay("Rebuilding \(tool.name)")
            } else if state.isExporting {
                iconProgressOverlay("Exporting \(tool.name)")
            } else if isHoveringRow && canContinue {
                Button(action: actions.onContinue) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(RunToolButtonStyle())
                .help("Continue \(tool.name)")
                .accessibilityLabel("Continue \(tool.name)")
                .accessibilityIdentifier("continue-tool-\(tool.id.uuidString)")
            } else if isHoveringRow && tool.isGenerationReady {
                Button(action: actions.onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(RunToolButtonStyle())
                .help("Run \(tool.name)")
                .accessibilityLabel("Run \(tool.name)")
                .accessibilityIdentifier("run-tool-\(tool.id.uuidString)")
            }
        }
    }

    private func iconProgressOverlay(_ accessibilityLabel: String) -> some View {
        IconProgressBadge(accessibilityLabel: accessibilityLabel)
    }

    private var generationStatusText: String? {
        switch tool.generationState {
        case .ready:
            return nil
        case .generating:
            return ToolRowGenerationStatusResolver.statusText(
                phase: tool.generationPhase,
                repairErrorCount: tool.generationRepairErrorCount,
                activeCodingAgent: state.activeCodingAgent
            )
        case .stopped:
            return "Paused"
        case .failed:
            return "Failed"
        }
    }

    private var canContinue: Bool {
        tool.generationState == .stopped || tool.generationState == .failed
    }

    private var statusStyle: some ShapeStyle {
        switch tool.generationState {
        case .ready, .generating, .stopped:
            return AnyShapeStyle(.secondary)
        case .failed:
            return AnyShapeStyle(.red)
        }
    }

    private var backgroundStyle: Color {
        if state.isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.24)
        }

        if !tool.isGenerationReady {
            return Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.10)
        }

        if isHoveringRow {
            return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.13)
        }

        return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.07)
    }
}

#Preview("Tool Row") {
    ToolRowView(
        tool: Tool(
            name: "Clipboard Cleaner",
            packageRootPath: "~/Library/Application Support/Ironsmith/ClipboardCleaner"),
        state: ToolItemPresentationState(
            isSelected: true,
            isRunning: false,
            isLaunching: false,
            isExporting: false,
            isRebuilding: false,
            isRestoring: false,
            canRevert: true,
            showsStoreActions: true,
            canUpdateStoreVersion: false,
            activeCodingAgent: nil,
            canShowAgentOutput: false
        ),
        actions: ToolItemActions(
            onSelect: {},
            onEdit: {},
            onRun: {},
            onQuit: {},
            onRename: {},
            onRebuild: {},
            onPublishToStore: {},
            onRevert: {},
            onExport: {},
            onShowInFinder: {},
            onViewSource: {},
            onShowAgentOutput: {},
            onContinue: {},
            onDiscard: {},
            onStop: {},
            onDelete: {}
        )
    )
    .padding()
    .frame(width: 360)
}

enum ToolRowGenerationStatusResolver {
    nonisolated static func statusText(
        phase: ToolGenerationPhase?,
        repairErrorCount: Int?,
        activeCodingAgent: ToolCodingAgent?
    ) -> String {
        if activeCodingAgent == .codex && isCodexOwnedPhase(phase) {
            return "Agent is working"
        }

        switch phase {
        case .initializing:
            return "Initializing"
        case .planning:
            return "Naming app"
        case .generatingIcon:
            return "Generating icon"
        case .waitingForIcon:
            return "Waiting for icon"
        case .refiningPrompt:
            return "Enhancing prompt"
        case .generatingSource:
            return "Generating source"
        case .generatingEditDiff:
            return "Editing source"
        case .generatingRepairDiff:
            return repairStatusText(repairErrorCount) ?? "Repairing"
        case .repairing:
            return repairStatusText(repairErrorCount) ?? "Building"
        case .packaging:
            return "Packaging"
        case .completed, nil:
            return "Finishing"
        }
    }

    nonisolated private static func isCodexOwnedPhase(_ phase: ToolGenerationPhase?) -> Bool {
        switch phase {
        case .generatingSource, .generatingEditDiff, .generatingRepairDiff, .repairing:
            return true
        case .initializing, .planning, .generatingIcon, .waitingForIcon, .refiningPrompt, .packaging, .completed, nil:
            return false
        }
    }

    nonisolated private static func repairStatusText(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        let errorLabel = count == 1 ? "error" : "errors"
        return "Repairing \(count) \(errorLabel)"
    }
}

@MainActor
struct ToolIconImageView: View {
    let tool: Tool
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var iconImage: NSImage?

    init(tool: Tool, size: CGFloat = 42, cornerRadius: CGFloat = 9) {
        self.tool = tool
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary.opacity(0.22))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.quaternary.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: loadKey) {
            await loadIcon()
        }
    }

    private var loadKey: ToolIconLoadKey {
        let layout = ToolPackageLayout(
            packageRootURL: tool.packageRootURL, executableName: tool.executableName)
        return ToolIconLoadKey(
            path: layout.cachedAppIconPNGURL.path,
            updatedAt: tool.updatedAt
        )
    }

    private func loadIcon() async {
        let key = loadKey.cacheKey
        if let cachedImage = ToolIconImageCache.image(for: key) {
            iconImage = cachedImage
            return
        }

        let path = loadKey.path
        let data = await Task.detached(priority: .utility) {
            Self.loadIconData(atPath: path)
        }.value
        guard !Task.isCancelled else { return }
        guard let data, let image = NSImage(data: data) else {
            iconImage = nil
            return
        }

        ToolIconImageCache.insert(image, for: key)
        iconImage = image
    }

    nonisolated private static func loadIconData(atPath path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}

private struct ToolIconLoadKey: Hashable {
    let path: String
    let updatedAt: Date

    var cacheKey: String {
        "\(path)#\(updatedAt.timeIntervalSinceReferenceDate)"
    }
}

@MainActor
private enum ToolIconImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    static func insert(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

struct RunToolButtonStyle: ButtonStyle {
    var size: CGFloat = 42
    var cornerRadius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct IconProgressBadge: View {
    let accessibilityLabel: String
    let containerSize: CGFloat
    @State private var isSpinning = false

    init(accessibilityLabel: String, containerSize: CGFloat = 42) {
        self.accessibilityLabel = accessibilityLabel
        self.containerSize = containerSize
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.38), radius: 3, y: 1)

            Circle()
                .trim(from: 0.18, to: 0.84)
                .stroke(
                    .black.opacity(0.78),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
        }
        .frame(width: containerSize, height: containerSize)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            isSpinning = false
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        }
        .onDisappear {
            isSpinning = false
        }
    }
}
