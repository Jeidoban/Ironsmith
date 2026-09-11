import AppKit
import SwiftUI

// TODO: Remove this and go back to a swiftui sheet once apple fixes the bug.
/// Presents the license view through AppKit because a fixed-size SwiftUI sheet can
/// incorrectly collapse `TabView` labels on macOS 27.
@MainActor
final class StoreLicenseSheetPresenter {
    private weak var attachmentView: StoreLicenseSheetAttachmentView?
    private weak var parentWindow: NSWindow?
    private var sheetWindow: NSWindow?

    func attach(_ view: StoreLicenseSheetAttachmentView) {
        attachmentView = view
        parentWindow = view.window
        view.presenter = self
    }

    func attachmentWindowDidChange(_ view: StoreLicenseSheetAttachmentView) {
        guard attachmentView === view else { return }

        if parentWindow !== view.window, sheetWindow != nil {
            dismiss()
        }
        parentWindow = view.window
    }

    func detach(_ view: StoreLicenseSheetAttachmentView) {
        guard attachmentView === view else { return }
        dismiss()
        attachmentView = nil
        parentWindow = nil
    }

    func present(
        license: StoreLicenseIdentifier,
        documents: StoreLegalDocuments,
        inheritedAttributions: [StoreLegalAttribution]
    ) {
        guard sheetWindow == nil,
            let parentWindow,
            parentWindow.attachedSheet == nil
        else { return }

        let sheet = NSWindow(
            contentViewController: NSHostingController(
                rootView: StoreLicenseDetailSheet(
                    license: license,
                    documents: documents,
                    inheritedAttributions: inheritedAttributions,
                    onDismiss: { [weak self] in self?.dismiss() }
                )
            )
        )
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        sheetWindow = sheet

        parentWindow.beginSheet(sheet) { [weak self, weak sheet] _ in
            sheet?.orderOut(nil)
            self?.sheetWindow = nil
        }
    }

    func dismiss() {
        guard let sheetWindow else { return }
        parentWindow?.endSheet(sheetWindow)
    }
}

struct StoreLicenseSheetAnchor: NSViewRepresentable {
    let presenter: StoreLicenseSheetPresenter

    func makeNSView(context: Context) -> StoreLicenseSheetAttachmentView {
        let view = StoreLicenseSheetAttachmentView()
        view.onWindowChange = { [weak presenter] view in
            presenter?.attachmentWindowDidChange(view)
        }
        presenter.attach(view)
        return view
    }

    func updateNSView(_ nsView: StoreLicenseSheetAttachmentView, context: Context) {
        presenter.attach(nsView)
    }

    static func dismantleNSView(
        _ nsView: StoreLicenseSheetAttachmentView,
        coordinator: Void
    ) {
        nsView.presenter?.detach(nsView)
        nsView.presenter = nil
        nsView.onWindowChange = nil
    }
}

final class StoreLicenseSheetAttachmentView: NSView {
    weak var presenter: StoreLicenseSheetPresenter?
    var onWindowChange: ((StoreLicenseSheetAttachmentView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self)
    }
}
