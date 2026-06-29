import AppKit
import SwiftData
import SwiftUI

@MainActor
final class IronsmithAppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: IronsmithApplicationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        IronsmithEditCommandMenu.installIfNeeded()
        applicationController = IronsmithApplicationController()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        applicationController?.handle(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applicationController?.applicationDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private enum IronsmithEditCommandMenu {
    static func installIfNeeded() {
        let mainMenu = NSApp.mainMenu ?? NSMenu(title: "Ironsmith")
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = mainMenu
        }

        if mainMenu.items.isEmpty {
            let appMenuItem = NSMenuItem()
            let appMenu = NSMenu(title: "Ironsmith")
            appMenu.addItem(withTitle: "Quit Ironsmith", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appMenuItem.submenu = appMenu
            mainMenu.addItem(appMenuItem)
        }

        guard !mainMenu.items.contains(where: { $0.submenu?.title == "Edit" }) else { return }

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(makeMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(makeMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(makeMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        mainMenu.addItem(editMenuItem)
    }

    private static func makeMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.command]
        item.target = nil
        return item
    }
}

@MainActor
final class IronsmithApplicationController {
    private let modelContainer: ModelContainer
    private let inferenceStore: InferenceStore
    private let routeStore: IronsmithRouteStore
    private let commandLineToolsGate: CommandLineToolsGate
    private let menuBarPopoverPresentationStore: MenuBarPopoverPresentationStore
    private let menuBarController: IronsmithMenuBarController?
    private let settingsWindowController: IronsmithSettingsWindowController?
    private let storeWindowController: IronsmithStoreWindowController?

    init() {
        let isRunningTests = IronsmithRuntimeEnvironment.isRunningTests
        let inferenceStore = InferenceStore()
        var appKitSettingsWindowController: IronsmithSettingsWindowController?
        var appKitStoreWindowController: IronsmithStoreWindowController?
        var appKitMenuBarController: IronsmithMenuBarController?
        let routeStore = IronsmithRouteStore(
            openSettingsWindow: {
                appKitSettingsWindowController?.show()
            },
            openStoreWindow: {
                appKitStoreWindowController?.show()
            },
            openToolLibraryPopover: {
                appKitMenuBarController?.show()
            }
        )
        let commandLineToolsGate = CommandLineToolsGate()
        let menuBarPopoverPresentationStore = MenuBarPopoverPresentationStore()

        do {
            modelContainer = try IronsmithModelContainerFactory.make(isRunningTests: isRunningTests)
            let context = ModelContext(modelContainer)
            try AppDataBootstrapper.bootstrapIfNeeded(in: context)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        self.inferenceStore = inferenceStore
        self.routeStore = routeStore
        self.commandLineToolsGate = commandLineToolsGate
        self.menuBarPopoverPresentationStore = menuBarPopoverPresentationStore
        if isRunningTests {
            settingsWindowController = nil
            storeWindowController = nil
            menuBarController = nil
        } else {
            let settingsWindowController = IronsmithSettingsWindowController(
                modelContainer: modelContainer,
                inferenceStore: inferenceStore,
                routeStore: routeStore
            )
            appKitSettingsWindowController = settingsWindowController
            self.settingsWindowController = settingsWindowController
            let storeWindowController = IronsmithStoreWindowController(
                modelContainer: modelContainer,
                inferenceStore: inferenceStore,
                routeStore: routeStore
            )
            appKitStoreWindowController = storeWindowController
            self.storeWindowController = storeWindowController
            let menuBarController = IronsmithMenuBarController(
                rootView: AnyView(
                    LaunchRouterView(gate: commandLineToolsGate)
                        .modelContainer(modelContainer)
                        .environment(inferenceStore)
                        .environment(routeStore)
                        .environment(menuBarPopoverPresentationStore)
                ),
                presentationStore: menuBarPopoverPresentationStore
            )
            appKitMenuBarController = menuBarController
            self.menuBarController = menuBarController
        }
    }

    func handle(_ urls: [URL]) {
        for url in urls {
            routeStore.handle(url)
        }
    }

    func applicationDidBecomeActive() {
        Task {
            await inferenceStore.refreshIronsmithAccountSummaryIfNeededAfterCheckout()
        }
    }
}
