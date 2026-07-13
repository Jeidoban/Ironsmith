import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithAgentOutputWindowController: NSWindowController {
    private var hasCenteredWindow = false
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        let window = NSWindow()
        window.title = "Agent Output"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.setContentSize(NSSize(width: 680, height: 560))

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(toolID: UUID) {
        guard let window else { return }
        window.contentViewController = NSHostingController(
            rootView: AnyView(
                AgentOutputWindowView(toolID: toolID)
                    .modelContainer(modelContainer)
            )
        )

        if !hasCenteredWindow {
            window.center()
            hasCenteredWindow = true
        }

        window.deminiaturize(nil)
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}
