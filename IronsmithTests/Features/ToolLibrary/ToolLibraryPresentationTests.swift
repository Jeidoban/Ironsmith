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

        #expect(ToolGridItemInteraction.canSelect(tool: readyTool))
        #expect(!ToolGridItemInteraction.canSelect(tool: stoppedTool))
        #expect(ToolGridItemInteraction.iconAction(tool: readyTool, state: idleState) == .run)
        #expect(ToolGridItemInteraction.iconAction(tool: readyTool, state: runningState) == nil)
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
    }

    private static func toolItemState(isRunning: Bool = false) -> ToolItemPresentationState {
        ToolItemPresentationState(
            isSelected: false,
            isRunning: isRunning,
            isExporting: false,
            isRebuilding: false,
            isRestoring: false,
            canRevert: false,
            showsStoreActions: false,
            canUpdateStoreVersion: false,
            activeCodingAgent: nil,
            canShowAgentOutput: false
        )
    }
}
