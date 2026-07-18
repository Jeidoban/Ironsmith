import AppKit
import SwiftUI

struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let isSubmitEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: isFocused,
            isSubmitEnabled: isSubmitEnabled,
            onSubmit: onSubmit
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = PromptNSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.onUnmodifiedReturn = context.coordinator.handleUnmodifiedReturn
        textView.unregisterDraggedTypes()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PromptNSTextView else { return }

        context.coordinator.update(
            text: $text,
            isFocused: isFocused,
            isSubmitEnabled: isSubmitEnabled,
            onSubmit: onSubmit
        )

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        textView.unregisterDraggedTypes()

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(
                    location: min(selectedRange.location, textView.string.utf16.count),
                    length: 0
                )
            )
        }

        guard isFocused.wrappedValue else { return }
        DispatchQueue.main.async { [weak scrollView, weak textView] in
            guard let window = scrollView?.window,
                let textView,
                window.firstResponder !== textView
            else { return }
            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private var isFocused: FocusState<Bool>.Binding
        private var isSubmitEnabled: Bool
        private var onSubmit: () -> Void

        init(
            text: Binding<String>,
            isFocused: FocusState<Bool>.Binding,
            isSubmitEnabled: Bool,
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.isSubmitEnabled = isSubmitEnabled
            self.onSubmit = onSubmit
        }

        func update(
            text: Binding<String>,
            isFocused: FocusState<Bool>.Binding,
            isSubmitEnabled: Bool,
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.isSubmitEnabled = isSubmitEnabled
            self.onSubmit = onSubmit
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func handleUnmodifiedReturn() -> Bool {
            if isSubmitEnabled {
                onSubmit()
            }
            return true
        }
    }
}

private final class PromptNSTextView: NSTextView {
    var onUnmodifiedReturn: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76

        if isReturn,
            !modifiers.contains(.shift),
            onUnmodifiedReturn?() == true
        {
            return
        }

        super.keyDown(with: event)
    }
}
