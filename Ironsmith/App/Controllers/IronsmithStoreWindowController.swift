import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithStoreWindowController: NSWindowController {
    private static let initialContentSize = NSSize(width: 1000, height: 660)
    private static let minimumContentSize = NSSize(width: 600, height: 400)

    private var hasCenteredWindow = false

    init(
        modelContainer: ModelContainer,
        inferenceStore: InferenceStore,
        routeStore: IronsmithRouteStore
    ) {
        let hostingController = NSHostingController(
            rootView: AnyView(
                StoreWindowView()
                    .modelContainer(modelContainer)
                    .environment(inferenceStore)
                    .environment(routeStore)
            )
        )
        hostingController.sceneBridgingOptions = [.toolbars]
        let window = NSWindow()
        window.title = "Ironsmith Store"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.minSize = Self.minimumContentSize
        window.setContentSize(Self.initialContentSize)

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
