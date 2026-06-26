//
//  ToolRowView.swift
//  Ironsmith
//

import AppKit
import SwiftUI

struct ToolRowView: View {
    let tool: Tool
    let isSelected: Bool
    let isRunning: Bool
    let isExporting: Bool
    let canRevert: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onRun: () -> Void
    let onRename: () -> Void
    let onRevert: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onViewSource: () -> Void
    let onContinue: () -> Void
    let onDiscard: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
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

                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Exporting \(tool.name)")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard tool.isGenerationReady else { return }
                    onSelect()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .contextMenu {
                appActionsMenu
            }

            Menu {
                appActionsMenu
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
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(RunToolButtonStyle())
                .help("Stop \(tool.name)")
                .accessibilityLabel("Stop \(tool.name)")
                .accessibilityIdentifier("stop-tool-\(tool.id.uuidString)")
            } else if tool.generationState == .generating {
                iconProgressOverlay("Generating \(tool.name)")
            } else if isRunning {
                iconProgressOverlay("Running \(tool.name)")
            } else if isHoveringRow && canContinue {
                Button(action: onContinue) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(RunToolButtonStyle())
                .help("Continue \(tool.name)")
                .accessibilityLabel("Continue \(tool.name)")
                .accessibilityIdentifier("continue-tool-\(tool.id.uuidString)")
            } else if isHoveringRow && tool.isGenerationReady {
                Button(action: onRun) {
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

    @ViewBuilder
    private var appActionsMenu: some View {
        Button(editActionTitle) {
            if isSelected {
                onSelect()
            } else {
                onEdit()
            }
        }
        .disabled(!(isSelected || tool.isGenerationReady))

        Button(launchActionTitle) {
            if isGenerating {
                onStop()
            } else if canContinue {
                onContinue()
            } else {
                onRun()
            }
        }
        .disabled(!(tool.isGenerationReady || canContinue || isGenerating))

        Divider()
        Button("Rename App...", action: onRename)
            .disabled(isGenerating)
        Button("Go Back to Previous Version", action: onRevert)
            .disabled(!tool.isGenerationReady || !canRevert)
        Button("Export App", action: onExport)
            .disabled(!tool.isGenerationReady)
        Button("View Source", action: onViewSource)
            .disabled(!tool.isGenerationReady)
        Button("Show in Finder", action: onShowInFinder)
        Divider()
        if shouldDiscardFromMenu {
            Button("Discard Edit", role: .destructive, action: onDiscard)
        } else {
            Button("Delete App", role: .destructive, action: onDelete)
        }
    }

    private var editActionTitle: String {
        isSelected ? "Exit Edit Mode" : "Edit App"
    }

    private var launchActionTitle: String {
        if isGenerating {
            return "Stop Generating"
        }

        if canContinue {
            return "Continue Generating"
        }

        return "Launch App"
    }

    private func iconProgressOverlay(_ accessibilityLabel: String) -> some View {
        IconProgressBadge(accessibilityLabel: accessibilityLabel)
    }

    private var generationStatusText: String? {
        switch tool.generationState {
        case .ready:
            return nil
        case .generating:
            return phaseStatusText
        case .stopped:
            return "Stopped"
        case .failed:
            return "Failed"
        }
    }

    private var phaseStatusText: String {
        switch tool.generationPhase {
        case .initializing:
            return "Initializing"
        case .planning:
            return "Naming app"
        case .generatingIcon:
            return "Generating icon"
        case .refiningPrompt:
            return "Enhancing prompt"
        case .generatingSource:
            return "Generating source"
        case .generatingEditDiff:
            return "Editing source"
        case .generatingRepairDiff:
            return repairStatusText ?? "Repairing"
        case .repairing:
            return repairStatusText ?? "Building"
        case .packaging:
            return "Packaging"
        case .completed, nil:
            return "Finishing"
        }
    }

    private var repairStatusText: String? {
        guard let count = tool.generationRepairErrorCount, count > 0 else { return nil }
        let errorLabel = count == 1 ? "error" : "errors"
        return "Repairing \(count) \(errorLabel)"
    }

    private var canContinue: Bool {
        tool.generationState == .stopped || tool.generationState == .failed
    }

    private var isGenerating: Bool {
        tool.generationState == .generating
    }

    private var shouldDiscardFromMenu: Bool {
        canContinue && tool.generationMode == .edit
    }

    private var statusStyle: some ShapeStyle {
        switch tool.generationState {
        case .ready, .generating, .stopped:
            return AnyShapeStyle(.secondary)
        case .failed:
            return AnyShapeStyle(.red)
        }
    }

    private var backgroundStyle: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(.tint.opacity(0.28))
        }

        if !tool.isGenerationReady {
            return AnyShapeStyle(.quaternary.opacity(0.52))
        }

        if isRunning {
            return AnyShapeStyle(.tint.opacity(0.14))
        }

        if isExporting {
            return AnyShapeStyle(.tint.opacity(0.14))
        }

        if isHoveringRow {
            return AnyShapeStyle(.quaternary.opacity(0.66))
        }

        return AnyShapeStyle(.quaternary.opacity(0.40))
    }
}

#Preview("Tool Row") {
    ToolRowView(
        tool: Tool(
            name: "Clipboard Cleaner",
            packageRootPath: "~/Library/Application Support/Ironsmith/ClipboardCleaner"),
        isSelected: true,
        isRunning: false,
        isExporting: false,
        canRevert: true,
        onSelect: {},
        onEdit: {},
        onRun: {},
        onRename: {},
        onRevert: {},
        onExport: {},
        onShowInFinder: {},
        onViewSource: {},
        onContinue: {},
        onDiscard: {},
        onStop: {},
        onDelete: {}
    )
    .padding()
    .frame(width: 360)
}

@MainActor
private struct ToolIconImageView: View {
    let tool: Tool
    @State private var iconImage: NSImage?

    var body: some View {
        ZStack {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.quaternary.opacity(0.22))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
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

private struct RunToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 42, height: 42)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct IconProgressBadge: View {
    let accessibilityLabel: String
    @State private var isSpinning = false

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
        .frame(width: 42, height: 42)
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
