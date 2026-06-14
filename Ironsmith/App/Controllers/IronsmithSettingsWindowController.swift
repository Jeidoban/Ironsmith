import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithSettingsWindowController: NSWindowController {
    private var hasCenteredWindow = false

    init(
        modelContainer: ModelContainer,
        inferenceStore: InferenceStore,
        routeStore: IronsmithRouteStore
    ) {
        let hostingController = NSHostingController(
            rootView: AnyView(
                SettingsWindowView()
                    .modelContainer(modelContainer)
                    .environment(inferenceStore)
                    .environment(routeStore)
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 720)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }

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
