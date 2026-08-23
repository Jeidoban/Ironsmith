import AppKit
import SwiftUI
import Testing
@testable import Ironsmith

struct MenuBarControllerTests {
    @MainActor
    @Test
    func applicationDeactivationClosesShownPopover() {
        let popover = TestPopover(isShown: true)
        let presentationStore = MenuBarPopoverPresentationStore()
        presentationStore.didShow()
        let controller = IronsmithMenuBarController(
            rootView: AnyView(EmptyView()),
            presentationStore: presentationStore,
            popover: popover
        )

        controller.applicationDidResignActive()

        #expect(popover.closeCount == 1)
        #expect(!presentationStore.isShown)
        #expect(presentationStore.closeCount == 1)
    }

    @MainActor
    @Test
    func applicationDeactivationDoesNothingWhenPopoverIsClosed() {
        let popover = TestPopover(isShown: false)
        let presentationStore = MenuBarPopoverPresentationStore()
        let controller = IronsmithMenuBarController(
            rootView: AnyView(EmptyView()),
            presentationStore: presentationStore,
            popover: popover
        )

        controller.applicationDidResignActive()

        #expect(popover.closeCount == 0)
        #expect(presentationStore.closeCount == 0)
    }
}

private final class TestPopover: NSPopover {
    private var reportsShown: Bool
    private(set) var closeCount = 0

    init(isShown: Bool) {
        reportsShown = isShown
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isShown: Bool {
        reportsShown
    }

    override func performClose(_ sender: Any?) {
        closeCount += 1
        reportsShown = false
    }
}
