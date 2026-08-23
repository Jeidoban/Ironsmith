import SwiftUI
import Testing
@testable import Ironsmith

struct AuxiliaryWindowControllerTests {
    @MainActor
    @Test
    func settingsContentIsNotCreatedUntilSettingsAreShown() {
        var rootViewBuildCount = 0
        let controller = IronsmithSettingsWindowController {
            rootViewBuildCount += 1
            return AnyView(EmptyView())
        }

        #expect(!controller.hasCreatedWindow)
        #expect(rootViewBuildCount == 0)
    }

    @MainActor
    @Test
    func agentOutputContentIsNotCreatedUntilAgentOutputIsShown() {
        var rootViewBuildCount = 0
        let controller = IronsmithAgentOutputWindowController { _ in
            rootViewBuildCount += 1
            return AnyView(EmptyView())
        }

        #expect(!controller.hasCreatedWindow)
        #expect(rootViewBuildCount == 0)
    }
}
