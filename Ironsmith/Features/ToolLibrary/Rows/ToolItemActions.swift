import SwiftUI

struct ToolItemPresentationState {
    let isSelected: Bool
    let isRunning: Bool
    let isLaunching: Bool
    let isExporting: Bool
    let isRebuilding: Bool
    let isRestoring: Bool
    let canRevert: Bool
    let showsStoreActions: Bool
    let canUpdateStoreVersion: Bool
    let activeCodingAgent: ToolCodingAgent?
    let canShowAgentOutput: Bool

    var isBusy: Bool {
        isLaunching || isExporting || isRebuilding || isRestoring
    }
}

struct ToolItemActions {
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onRun: () -> Void
    let onQuit: () -> Void
    let onRename: () -> Void
    let onRebuild: () -> Void
    let onPublishToStore: () -> Void
    let onRevert: () -> Void
    let onExport: () -> Void
    let onShowInFinder: () -> Void
    let onViewSource: () -> Void
    let onShowAgentOutput: () -> Void
    let onContinue: () -> Void
    let onDiscard: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void

    static let noOp = ToolItemActions(
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
}

struct ToolItemActionsMenu: View {
    let tool: Tool
    let state: ToolItemPresentationState
    let actions: ToolItemActions

    var body: some View {
        Button(editActionTitle) {
            if state.isSelected {
                actions.onSelect()
            } else {
                actions.onEdit()
            }
        }
        .disabled(!(state.isSelected || tool.isGenerationReady))

        Button(launchAction.title) {
            switch launchAction {
            case .pauseGeneration:
                actions.onStop()
            case .continueGeneration:
                actions.onContinue()
            case .quit:
                actions.onQuit()
            case .launch:
                actions.onRun()
            }
        }
        .disabled(state.isBusy || !(tool.isGenerationReady || canContinue || isGenerating))

        Divider()
        Button("Rename App...", action: actions.onRename)
            .disabled(isGenerating || state.isBusy)
        Button("Rebuild App", action: actions.onRebuild)
            .disabled(!tool.isRebuildable || state.isBusy)
        if state.showsStoreActions {
            Button(storePublishActionTitle, action: actions.onPublishToStore)
                .disabled(!tool.isGenerationReady || state.isBusy)
        }
        Button("Go Back to Previous Version", action: actions.onRevert)
            .disabled(!tool.isGenerationReady || !state.canRevert || state.isBusy)
        Button("Export App", action: actions.onExport)
            .disabled(!tool.isGenerationReady || state.isBusy)
        Button("View Source", action: actions.onViewSource)
            .disabled(!tool.isGenerationReady)
        Button("Show Agent Output", action: actions.onShowAgentOutput)
            .disabled(!state.canShowAgentOutput)
        Button("Show in Finder", action: actions.onShowInFinder)
        Divider()
        if shouldDiscardFromMenu {
            Button("Discard Edit", role: .destructive, action: actions.onDiscard)
                .disabled(state.isBusy)
        } else {
            Button("Delete App", role: .destructive, action: actions.onDelete)
                .disabled(state.isBusy)
        }
    }

    private var editActionTitle: String {
        state.isSelected ? "Exit Edit Mode" : "Edit App"
    }

    private var launchAction: ToolItemLaunchAction {
        ToolItemLaunchAction.resolve(tool: tool, state: state)
    }

    private var storePublishActionTitle: String {
        state.canUpdateStoreVersion ? "Update Store Version..." : "Publish to App Store..."
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
}

@MainActor
enum ToolItemLaunchAction: Equatable {
    case pauseGeneration
    case continueGeneration
    case quit
    case launch

    static func resolve(
        tool: Tool,
        state: ToolItemPresentationState
    ) -> ToolItemLaunchAction {
        if tool.generationState == .generating {
            return .pauseGeneration
        }
        if tool.generationState == .stopped || tool.generationState == .failed {
            return .continueGeneration
        }
        if state.isRunning {
            return .quit
        }
        return .launch
    }

    var title: String {
        switch self {
        case .pauseGeneration:
            return "Pause Generation"
        case .continueGeneration:
            return "Continue Generating"
        case .quit:
            return "Quit App"
        case .launch:
            return "Launch App"
        }
    }
}
