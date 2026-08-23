import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithAgentOutputWindowController: NSWindowController {
    private let rootViewBuilder: @MainActor (UUID) -> AnyView
    private var agentOutputWindow: NSWindow?
    private var hasCenteredWindow = false

    var hasCreatedWindow: Bool { agentOutputWindow != nil }

    convenience init(modelContainer: ModelContainer) {
        self.init { toolID in
            AnyView(
                AgentOutputWindowView(toolID: toolID)
                    .modelContainer(modelContainer)
            )
        }
    }

    init(rootViewBuilder: @escaping @MainActor (UUID) -> AnyView) {
        self.rootViewBuilder = rootViewBuilder
        super.init(window: nil)
    }

    private func loadAgentOutputWindowIfNeeded() {
        guard agentOutputWindow == nil else { return }
        let window = NSWindow()
        window.title = "Agent Output"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.setContentSize(NSSize(width: 680, height: 560))
        self.window = window
        agentOutputWindow = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(toolID: UUID) {
        loadAgentOutputWindowIfNeeded()
        guard let window = agentOutputWindow else { return }
        window.contentViewController = NSHostingController(
            rootView: rootViewBuilder(toolID)
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
    }
}
