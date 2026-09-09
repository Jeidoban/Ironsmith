import AppKit
import Foundation
import Testing
@testable import Ironsmith

extension ToolLibraryTests {
    @Test
    func toolLibraryPresentationPreferencesUseSafeDefaults() {
        #expect(ToolLibraryViewMode.resolved("icons") == .icons)
        #expect(ToolLibraryViewMode.resolved("unknown") == .list)
        #expect(ToolLibrarySortOrder.resolved("alphabetical") == .alphabetical)
        #expect(ToolLibrarySortOrder.resolved("unknown") == .latest)
    }

    @MainActor
    @Test
    func generationSettingsMenuAddsNativeSelectionStatesAndTooltips() {
        let rootMenu = NSMenu()
        let appTypeMenu = submenu(named: "App Type", in: rootMenu)
        let appTypeAutomatic = addItem(named: "Automatic", to: appTypeMenu)
        appTypeAutomatic.state = .on

        let codingAgentMenu = submenu(named: "Coding Agent", in: rootMenu)
        let automaticAgent = addItem(named: "Automatic", to: codingAgentMenu)
        let flameAgent = addItem(named: "Ironsmith Flame", to: codingAgentMenu)
        let codexAgent = addItem(named: "Codex", to: codingAgentMenu)
        let customAgentMenu = submenu(named: "Custom", in: codingAgentMenu)
        let selectedCustomAgent = addItem(named: "Claude Code", to: customAgentMenu)
        let addAgent = addItem(named: "Add Agent…", to: customAgentMenu)

        let reasoningMenu = submenu(named: "Reasoning", in: rootMenu)
        let defaultReasoning = addItem(named: "Default", to: reasoningMenu)
        let highReasoning = addItem(named: "High", to: reasoningMenu)

        GenerationSettingsMenuHelp.apply(
            to: reasoningMenu,
            codingAgentPreference: .codex,
            reasoningEffort: .high,
            selectedCustomCodingAgentName: "Claude Code",
            isAutoRemixAvailable: true
        )

        #expect(appTypeAutomatic.state == .on)
        #expect(automaticAgent.state == .off)
        #expect(flameAgent.state == .off)
        #expect(codexAgent.state == .on)
        #expect(codexAgent.toolTip != nil)
        #expect(flameAgent.toolTip != nil)
        #expect(defaultReasoning.state == .off)
        #expect(highReasoning.state == .on)
        #expect(selectedCustomAgent.state == .off)
        #expect(addAgent.state == .off)

        GenerationSettingsMenuHelp.apply(
            to: customAgentMenu,
            codingAgentPreference: .custom,
            reasoningEffort: .default,
            selectedCustomCodingAgentName: "Claude Code",
            isAutoRemixAvailable: true
        )

        #expect(selectedCustomAgent.state == .on)
        #expect(addAgent.state == .off)
    }

    @MainActor
    @Test
    func toolLibraryPresentationFiltersNamesCaseInsensitivelyBeforeLatestSort() {
        let older = Tool(
            name: "Mortgage Mate",
            packageRootPath: "/tmp/mortgage-mate",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = Tool(
            name: "Mortgage Calculator",
            packageRootPath: "/tmp/mortgage-calculator",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let unrelated = Tool(
            name: "Notes",
            packageRootPath: "/tmp/notes",
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let visibleTools = ToolLibraryPresentation.visibleTools(
            from: [older, unrelated, newer],
            searchText: "  MORTGAGE ",
            sortOrder: .latest
        )

        #expect(visibleTools.map(\.name) == ["Mortgage Calculator", "Mortgage Mate"])
    }

    @MainActor
    @Test
    func toolLibraryPresentationSortsAlphabeticallyWithStableTieBreakers() {
        let newestBeta = Tool(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            name: "Beta",
            packageRootPath: "/tmp/beta-new",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let oldestBeta = Tool(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            name: "Beta",
            packageRootPath: "/tmp/beta-old",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let alpha = Tool(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            name: "Alpha",
            packageRootPath: "/tmp/alpha",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let visibleTools = ToolLibraryPresentation.visibleTools(
            from: [oldestBeta, newestBeta, alpha],
            searchText: "",
            sortOrder: .alphabetical
        )

        #expect(visibleTools.map(\.id) == [alpha.id, newestBeta.id, oldestBeta.id])
    }

    @MainActor
    @Test
    func toolGridItemsSeparateSelectionFromIconActions() {
        let readyTool = Tool(name: "Ready", packageRootPath: "/tmp/ready")
        let stoppedTool = Tool(
            name: "Stopped",
            packageRootPath: "/tmp/stopped",
            generationState: .stopped
        )
        let failedTool = Tool(
            name: "Failed",
            packageRootPath: "/tmp/failed",
            generationState: .failed
        )
        let generatingTool = Tool(
            name: "Generating",
            packageRootPath: "/tmp/generating",
            generationState: .generating
        )
        let idleState = Self.toolItemState()
        let runningState = Self.toolItemState(isRunning: true)
        let launchingState = Self.toolItemState(isLaunching: true)
        let preparingGenerationState = Self.toolItemState(isPreparingGeneration: true)

        #expect(ToolGridItemInteraction.canSelect(tool: readyTool, state: idleState))
        #expect(!ToolGridItemInteraction.canSelect(tool: stoppedTool, state: idleState))
        #expect(!ToolGridItemInteraction.canSelect(tool: readyTool, state: preparingGenerationState))
        #expect(ToolGridItemInteraction.iconAction(tool: readyTool, state: idleState) == .run)
        #expect(ToolGridItemInteraction.iconAction(tool: readyTool, state: runningState) == .run)
        #expect(ToolGridItemInteraction.iconAction(tool: readyTool, state: launchingState) == nil)
        #expect(ToolItemLaunchAction.resolve(tool: readyTool, state: idleState) == .launch)
        #expect(ToolItemLaunchAction.resolve(tool: readyTool, state: runningState) == .quit)
        #expect(ToolItemLaunchAction.resolve(tool: readyTool, state: runningState).title == "Quit App")
        #expect(
            ToolGridItemInteraction.iconAction(tool: stoppedTool, state: idleState)
                == .continueGeneration
        )
        #expect(
            ToolGridItemInteraction.iconAction(tool: failedTool, state: idleState)
                == .continueGeneration
        )
        #expect(
            ToolGridItemInteraction.iconAction(tool: generatingTool, state: idleState)
                == .pauseGeneration
        )
        #expect(
            ToolGridItemInteraction.iconAction(tool: readyTool, state: preparingGenerationState)
                == .pauseGeneration
        )
        #expect(
            ToolItemLaunchAction.resolve(tool: readyTool, state: preparingGenerationState)
                == .pauseGeneration
        )
    }

    private static func toolItemState(
        isRunning: Bool = false,
        isLaunching: Bool = false,
        isPreparingGeneration: Bool = false
    ) -> ToolItemPresentationState {
        ToolItemPresentationState(
            isSelected: false,
            isRunning: isRunning,
            isLaunching: isLaunching,
            isExporting: false,
            isRebuilding: false,
            isRestoring: false,
            isEditingDetails: false,
            isPreparingGeneration: isPreparingGeneration,
            canRevert: false,
            showsStoreActions: false,
            canUpdateStoreVersion: false,
            hasStoreSourceChanges: true,
            activeCodingAgent: nil,
            canShowAgentOutput: false
        )
    }

    @MainActor
    private func submenu(named title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        parent.addItem(item)
        return submenu
    }

    @MainActor
    private func addItem(named title: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.addItem(item)
        return item
    }
}
