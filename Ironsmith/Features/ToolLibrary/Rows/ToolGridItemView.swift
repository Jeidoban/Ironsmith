import SwiftUI

struct ToolGridItemView: View {
    let tool: Tool
    let state: ToolItemPresentationState
    let actions: ToolItemActions
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            icon

            Text(tool.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            launchIfAvailable()
        }
        .contextMenu {
            ToolItemActionsMenu(tool: tool, state: state, actions: actions)
        }
        .onHover { isHovering = $0 }
        .help(tool.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tool.name)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            launchIfAvailable()
        }
        .accessibilityIdentifier("tool-grid-item-\(tool.id.uuidString)")
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            ToolIconImageView(tool: tool, size: 54, cornerRadius: 12)

            if let busyAccessibilityLabel {
                IconProgressBadge(
                    accessibilityLabel: busyAccessibilityLabel,
                    containerSize: 54
                )
            } else if tool.generationState == .stopped {
                statusBadge(systemImage: "pause.fill", color: .secondary)
            } else if tool.generationState == .failed {
                statusBadge(systemImage: "exclamationmark", color: .red)
            }
        }
        .frame(width: 54, height: 54)
    }

    private func statusBadge(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(color, in: Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1)
            }
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
    }

    private var busyAccessibilityLabel: String? {
        if tool.generationState == .generating {
            return "Generating \(tool.name)"
        }
        if state.isRunning {
            return "Running \(tool.name)"
        }
        if state.isRestoring {
            return "Restoring \(tool.name)"
        }
        if state.isRebuilding {
            return "Rebuilding \(tool.name)"
        }
        if state.isExporting {
            return "Exporting \(tool.name)"
        }
        return nil
    }

    private var accessibilityHint: String {
        if tool.isGenerationReady && !state.isBusy {
            return "Launches the app. Right-click for more actions."
        }
        return "Right-click for available actions."
    }

    private var backgroundStyle: some ShapeStyle {
        if state.isSelected {
            return AnyShapeStyle(.tint.opacity(0.22))
        }
        if isHovering {
            return AnyShapeStyle(.quaternary.opacity(0.58))
        }
        return AnyShapeStyle(.clear)
    }

    private func launchIfAvailable() {
        guard ToolGridItemInteraction.canLaunch(tool: tool, state: state) else { return }
        actions.onRun()
    }
}

@MainActor
enum ToolGridItemInteraction {
    static func canLaunch(tool: Tool, state: ToolItemPresentationState) -> Bool {
        tool.isGenerationReady && !state.isBusy
    }
}

#Preview("Tool Icon Grid") {
    let tools = [
        Tool(name: "File Scout", packageRootPath: "/tmp/FileScout"),
        Tool(name: "Mortgage Mate", packageRootPath: "/tmp/MortgageMate"),
        Tool(name: "Key Jam", packageRootPath: "/tmp/KeyJam"),
        Tool(name: "Jot Nest", packageRootPath: "/tmp/JotNest"),
    ]
    let state = ToolItemPresentationState(
        isSelected: false,
        isRunning: false,
        isExporting: false,
        isRebuilding: false,
        isRestoring: false,
        canRevert: false,
        showsStoreActions: false,
        canUpdateStoreVersion: false,
        activeCodingAgent: nil,
        canShowAgentOutput: false
    )

    LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
        spacing: 14
    ) {
        ForEach(tools) { tool in
            ToolGridItemView(tool: tool, state: state, actions: .noOp)
        }
    }
    .padding()
    .frame(width: 320)
}
