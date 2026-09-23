import AppKit
import SwiftUI

/// A text editor for exact values the person approves or sends, such as a
/// command's argument array or a message to an agent. SwiftUI's TextEditor
/// leaves macOS's automatic substitutions on, so a `"` could become `”` and
/// `--` could become `—`, changing what is approved or sent; every
/// substitution, correction and detector is off here.
///
/// Each editor keeps its own undo history, cleared whenever its text is
/// replaced from outside: a text view reused for different content (a
/// context pack switching parts) must never undo an edit made to the
/// previous content at its offsets.
public struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let accessibilityLabel: String
    let font: NSFont
    let drawsBackground: Bool
    let focusRequest: AnyHashable?

    /// `focusRequest`: whenever this value changes (including its first
    /// non-nil value), the editor becomes first responder one run-loop turn
    /// later, once it is in its window.
    public init(text: Binding<String>, isEditable: Bool = true, accessibilityLabel: String,
                font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular),
                drawsBackground: Bool = true, focusRequest: AnyHashable? = nil) {
        _text = text
        self.isEditable = isEditable
        self.accessibilityLabel = accessibilityLabel
        self.font = font
        self.drawsBackground = drawsBackground
        self.focusRequest = focusRequest
    }

    /// Turns off everything that could rewrite typed or pasted text.
    @MainActor
    public static func configure(_ view: NSTextView) {
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.allowsUndo = true
    }

    /// Replaces the text from outside the editor. The undo history belongs to
    /// the text it was recorded against, so it is dropped with it.
    @MainActor
    public static func replaceText(of view: NSTextView, with text: String, coordinator: Coordinator) {
        guard view.string != text else { return }
        view.string = text
        coordinator.undo.removeAllActions()
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        Self.configure(view)
        view.delegate = context.coordinator
        view.string = text
        apply(to: scroll, view: view, context: context)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        Self.replaceText(of: view, with: text, coordinator: context.coordinator)
        apply(to: scroll, view: view, context: context)
    }

    private func apply(to scroll: NSScrollView, view: NSTextView, context: Context) {
        view.isEditable = isEditable
        view.font = font
        view.drawsBackground = drawsBackground
        scroll.drawsBackground = drawsBackground
        view.setAccessibilityLabel(accessibilityLabel)
        if let focusRequest, focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// This editor's own undo history, never the window's shared one.
        public let undo = UndoManager()
        var lastFocusRequest: AnyHashable?

        public init(text: Binding<String>) { self.text = text }

        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        public func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}
