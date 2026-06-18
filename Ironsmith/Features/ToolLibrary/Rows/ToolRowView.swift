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
    let onRun: () -> Void
    let onRevert: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onViewSource: () -> Void
    let onContinue: () -> Void
    let onDiscard: () -> Void
    let onDelete: () -> Void
    @State private var isHoveringRow = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                icon

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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                ToolRowClickHandlingView(
                    ignoredLeadingWidth: 64,
                    onSelect: tool.isGenerationReady ? onSelect : {},
                    onRun: tool.isGenerationReady ? onRun : {}
                )
            }

            if canContinue {
                generationActionButtons
            }

            Menu {
                Button("Go Back to Previous Version", action: onRevert)
                    .disabled(!tool.isGenerationReady || !canRevert)
                Button("Export App", action: onExport)
                    .disabled(!tool.isGenerationReady)
                Button("View Source", action: onViewSource)
                    .disabled(!tool.isGenerationReady)
                Button("Show in Finder", action: onShowInFinder)
                Divider()
                Button("Delete App", role: .destructive, action: onDelete)
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

            if tool.generationState == .generating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Generating \(tool.name)")
            } else if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Running \(tool.name)")
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

    private var generationActionButtons: some View {
        HStack(spacing: 4) {
            Button(action: onContinue) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Continue generation")
            .accessibilityLabel("Continue generation for \(tool.name)")

            Button(role: .destructive, action: onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Discard generation")
            .accessibilityLabel("Discard generation for \(tool.name)")
        }
        .fixedSize()
    }

    private var generationStatusText: String? {
        switch tool.generationState {
        case .ready:
            return nil
        case .generating:
            return phaseStatusText
        case .stopped:
            return "Stopped · \(phaseName)"
        case .failed:
            if let generationErrorSummary = tool.generationErrorSummary,
               !generationErrorSummary.isEmpty {
                return "Failed · \(phaseName): \(generationErrorSummary)"
            }
            return "Failed · \(phaseName)"
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
            return "Repairing source"
        case .repairing:
            return "Building"
        case .packaging:
            return "Packaging"
        case .completed, nil:
            return "Finishing"
        }
    }

    private var phaseName: String {
        switch tool.generationPhase {
        case .initializing:
            return "initializing"
        case .planning:
            return "naming"
        case .generatingIcon:
            return "icon"
        case .refiningPrompt:
            return "prompt"
        case .generatingSource:
            return "source"
        case .generatingEditDiff:
            return "edit"
        case .generatingRepairDiff, .repairing:
            return "repair"
        case .packaging:
            return "packaging"
        case .completed, nil:
            return "generation"
        }
    }

    private var canContinue: Bool {
        tool.generationState == .stopped || tool.generationState == .failed
    }

    private var statusStyle: some ShapeStyle {
        switch tool.generationState {
        case .ready:
            return AnyShapeStyle(.secondary)
        case .generating:
            return AnyShapeStyle(.secondary)
        case .stopped:
            return AnyShapeStyle(.orange)
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
        onRun: {},
        onRevert: {},
        onExport: {},
        onShowInFinder: {},
        onViewSource: {},
        onContinue: {},
        onDiscard: {},
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

private struct ToolRowClickHandlingView: NSViewRepresentable {
    let ignoredLeadingWidth: CGFloat
    let onSelect: () -> Void
    let onRun: () -> Void

    func makeNSView(context: Context) -> ClickHandlingNSView {
        let view = ClickHandlingNSView()
        view.ignoredLeadingWidth = ignoredLeadingWidth
        view.onSelect = onSelect
        view.onRun = onRun
        return view
    }

    func updateNSView(_ nsView: ClickHandlingNSView, context: Context) {
        nsView.ignoredLeadingWidth = ignoredLeadingWidth
        nsView.onSelect = onSelect
        nsView.onRun = onRun
    }

    final class ClickHandlingNSView: NSView {
        var ignoredLeadingWidth: CGFloat = 0
        var onSelect: (() -> Void)?
        var onRun: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard point.x >= ignoredLeadingWidth else {
                return nil
            }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onRun?()
            } else {
                onSelect?()
            }
        }
    }
}
