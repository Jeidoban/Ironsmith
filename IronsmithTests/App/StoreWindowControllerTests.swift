import SwiftUI
import Testing
@testable import Ironsmith

struct StoreWindowControllerTests {
    @MainActor
    @Test
    func disabledStoreDoesNotLoadStoreContent() {
        var rootViewBuildCount = 0
        let controller = IronsmithStoreWindowController(
            rootViewBuilder: {
                rootViewBuildCount += 1
                return AnyView(EmptyView())
            },
            isStoreFeatureEnabled: { false }
        )

        controller.show()

        #expect(!controller.hasCreatedWindow)
        #expect(rootViewBuildCount == 0)
    }

    @MainActor
    @Test
    func directStoreLinkCanLoadStoreContentWhileFeatureIsDisabled() {
        var rootViewBuildCount = 0
        let controller = IronsmithStoreWindowController(
            rootViewBuilder: {
                rootViewBuildCount += 1
                return AnyView(EmptyView())
            },
            isStoreFeatureEnabled: { false }
        )

        controller.show(allowWhenFeatureDisabled: true)

        #expect(controller.hasCreatedWindow)
        #expect(rootViewBuildCount == 1)
        controller.close()
    }
}
