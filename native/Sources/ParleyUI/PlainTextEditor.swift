import AppKit
import SwiftUI

/// A text editor for exact values the person approves, such as a command's
/// argument array. SwiftUI's TextEditor leaves macOS's automatic
/// substitutions on, so a `"` could become `”` and change what is approved;
/// every substitution, correction and detector is off here.
public struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let accessibilityLabel: String

    public init(text: Binding<String>, isEditable: Bool = true, accessibilityLabel: String) {
        _text = text
        self.isEditable = isEditable
        self.accessibilityLabel = accessibilityLabel
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
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        Self.configure(view)
        view.delegate = context.coordinator
        view.string = text
        view.isEditable = isEditable
        view.setAccessibilityLabel(accessibilityLabel)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if view.string != text { view.string = text }
        view.isEditable = isEditable
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
