import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithStoreWindowController: NSWindowController {
    private var hasCenteredWindow = false
    private let modelContainer: ModelContainer
    private let inferenceStore: InferenceStore
    private let routeStore: IronsmithRouteStore

    init(
        modelContainer: ModelContainer,
        inferenceStore: InferenceStore,
        routeStore: IronsmithRouteStore
    ) {
        self.modelContainer = modelContainer
        self.inferenceStore = inferenceStore
        self.routeStore = routeStore

        let window = NSWindow()
        window.title = "App Store"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 680)
        window.setContentSize(NSSize(width: 1200, height: 800))

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if window.contentViewController == nil {
            window.contentViewController = NSHostingController(
                rootView: AnyView(
                    StoreWindowView()
                        .modelContainer(modelContainer)
                        .environment(inferenceStore)
                        .environment(routeStore)
                )
            )
        }

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
