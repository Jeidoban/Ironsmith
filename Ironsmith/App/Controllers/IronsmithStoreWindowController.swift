import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithStoreWindowController: NSWindowController {
    private static let initialContentSize = NSSize(width: 1000, height: 660)
    private static let minimumContentSize = NSSize(width: 600, height: 400)

    private let rootViewBuilder: @MainActor () -> AnyView
    private let isStoreFeatureEnabled: @MainActor () -> Bool
    private var storeWindow: NSWindow?
    private var hasCenteredWindow = false

    var hasCreatedWindow: Bool { storeWindow != nil }

    convenience init(
        modelContainer: ModelContainer,
        inferenceStore: InferenceStore,
        routeStore: IronsmithRouteStore
    ) {
        self.init {
            AnyView(
                StoreWindowView()
                    .modelContainer(modelContainer)
                    .environment(inferenceStore)
                    .environment(routeStore)
            )
        }
    }

    init(
        rootViewBuilder: @escaping @MainActor () -> AnyView,
        isStoreFeatureEnabled: @escaping @MainActor () -> Bool = {
            IronsmithFeatureFlags.isStoreEnabled()
        }
    ) {
        self.rootViewBuilder = rootViewBuilder
        self.isStoreFeatureEnabled = isStoreFeatureEnabled
        super.init(window: nil)
    }

    private func loadStoreWindowIfNeeded() {
        guard storeWindow == nil else { return }
        let hostingController = NSHostingController(rootView: rootViewBuilder())
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
        self.window = window
        storeWindow = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard isStoreFeatureEnabled() else { return }
        loadStoreWindowIfNeeded()
        guard let window = storeWindow else { return }
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
