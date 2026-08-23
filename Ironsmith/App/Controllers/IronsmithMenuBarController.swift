import AppKit
import SwiftUI

@MainActor
final class IronsmithMenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<AnyView>
    private let presentationStore: MenuBarPopoverPresentationStore?

    convenience init(
        rootView: AnyView,
        presentationStore: MenuBarPopoverPresentationStore? = nil
    ) {
        self.init(
            rootView: rootView,
            presentationStore: presentationStore,
            popover: NSPopover()
        )
    }

    init(
        rootView: AnyView,
        presentationStore: MenuBarPopoverPresentationStore?,
        popover: NSPopover
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = popover
        hostingController = NSHostingController(rootView: rootView)
        self.presentationStore = presentationStore

        super.init()

        configurePopover()
        configureStatusItem()
    }

    private func configurePopover() {
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = hostingController
        popover.delegate = self
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        let image = NSImage(named: "IronsmithMenubarIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 26, height: 26)
        image?.accessibilityDescription = "Ironsmith"

        button.image = image
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Ironsmith"
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover()
        }
    }

    func show() {
        showPopover()
    }

    func applicationDidResignActive() {
        closePopover(nil)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let popoverWindow = popover.contentViewController?.view.window {
            // NSPopover uses a menu-style window level by default, which can cover
            // the app's Settings, About, Store, Agent Output, and open panels.
            // Ironsmith keeps this popover open while those windows are presented,
            // so use the normal app-window level and let key-window ordering win.
            popoverWindow.level = .normal
            popoverWindow.makeKey()
        }
        button.state = .on
        presentationStore?.didShow()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.state = .off
    }

    private func closePopover(_ sender: Any?) {
        guard popover.isShown else { return }
        presentationStore?.willClose()
        dismissAttachedSheetIfNeeded()
        popover.performClose(sender)
    }

    private func dismissAttachedSheetIfNeeded() {
        guard
            let window = popover.contentViewController?.view.window,
            let attachedSheet = window.attachedSheet
        else {
            return
        }

        window.endSheet(attachedSheet)
    }
}
