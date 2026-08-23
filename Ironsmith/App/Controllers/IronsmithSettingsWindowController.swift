import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithSettingsWindowController: NSWindowController {
    private let rootViewBuilder: @MainActor () -> AnyView
    private var settingsWindow: NSWindow?
    private var hasCenteredWindow = false

    var hasCreatedWindow: Bool { settingsWindow != nil }

    convenience init(
        modelContainer: ModelContainer,
        inferenceStore: InferenceStore,
        routeStore: IronsmithRouteStore
    ) {
        self.init {
            AnyView(
                SettingsWindowView()
                    .modelContainer(modelContainer)
                    .environment(inferenceStore)
                    .environment(routeStore)
            )
        }
    }

    init(rootViewBuilder: @escaping @MainActor () -> AnyView) {
        self.rootViewBuilder = rootViewBuilder
        super.init(window: nil)
    }

    private func loadSettingsWindowIfNeeded() {
        guard settingsWindow == nil else { return }
        let hostingController = NSHostingController(
            rootView: rootViewBuilder()
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 720)
        self.window = window
        settingsWindow = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        loadSettingsWindowIfNeeded()
        guard let window = settingsWindow else { return }

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
