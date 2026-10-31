import AppKit
import SwiftUI

/// SwiftUI wrapper around `SQLTextView`, kept in sync with a `QueryDocument`.
struct SQLEditor: NSViewRepresentable {
    let document: QueryDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = SQLTextView.make()
        textView.delegate = context.coordinator
        textView.string = document.text
        scrollView.documentView = textView

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        textView.rehighlight()
        textView.setSelectedRange(clamped(document.selection, in: textView))
        textView.setWrapsLines(document.wrapsLines)
        textView.setShowsInvisibles(document.showsInvisibles)
        document.editor = textView
        context.coordinator.textView = textView

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }
        // Text set from outside the editor (opening a file, a new tab with SQL in it).
        if textView.string != document.text {
            textView.replaceAll(with: document.text)
        }
        textView.setWrapsLines(document.wrapsLines)
        textView.setShowsInvisibles(document.showsInvisibles)
    }

    private func clamped(_ range: NSRange, in textView: NSTextView) -> NSRange {
        let length = (textView.string as NSString).length
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: QueryDocument
        weak var textView: SQLTextView?

        init(document: QueryDocument) {
            self.document = document
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SQLTextView else { return }
            textView.rehighlight()
            document.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? SQLTextView else { return }
            document.selection = textView.selectedRange()
            textView.updateCurrentStatement()
        }
    }
}

/// Read-only, syntax-coloured SQL, e.g. a table's DDL.
struct SQLCodeView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = SQLTextView.make()
        textView.isEditable = false
        textView.highlightsCurrentStatement = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        scrollView.documentView = textView
        textView.string = text
        textView.rehighlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView, textView.string != text else { return }
        textView.string = text
        textView.rehighlight()
    }
}

/// Editable, syntax-coloured SQL bound to a string, e.g. the Apply dialog's script.
struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = SQLTextView.make()
        textView.highlightsCurrentStatement = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        textView.string = text
        textView.rehighlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView, textView.string != text else { return }
        textView.string = text
        textView.rehighlight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SQLTextView else { return }
            textView.rehighlight()
            text.wrappedValue = textView.string
        }
    }
}
