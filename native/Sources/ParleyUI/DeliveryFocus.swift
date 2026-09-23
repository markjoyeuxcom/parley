import AppKit

/// Lends first responder to a pane for one delivery that needs its pane
/// focused (Copilot's submission, `PaneSubmissionTiming.focusesTarget`) and
/// gives it back.
///
/// While the delivery runs, `paneID` names the pane: its focus callbacks are
/// not the person choosing it, so they must change no selection, and the
/// selected pane's focus repair must not pull focus away before Enter. Focus
/// is restored through the pane's own window, on every exit, and only if the
/// pane still holds it; focus the person moved meanwhile is left alone.
@MainActor
public final class DeliveryFocus {
    public private(set) var paneID: String?

    public init() {}

    private enum Restore {
        case responder(NSResponder?)
        /// A text field being edited is represented by the window's shared
        /// field editor, which leaves the view hierarchy the moment the field
        /// resigns. Restoring the editor would restore nothing; the field and
        /// the person's selection in it are what come back.
        case field(NSControl, NSRange)
    }

    /// Makes `view` first responder of its window, runs `deliver`, then
    /// restores the previous responder. `settle` pumps the run loop for
    /// `beforeRestoring` seconds after a delivery that completed, so the
    /// pane handles its input while still focused. Restoring never throws.
    public func deliver(focusing view: NSView, paneID: String, beforeRestoring: TimeInterval,
                        settle: (TimeInterval) -> Void, _ deliver: () throws -> Void) rethrows {
        guard let window = view.window, window.firstResponder !== view else {
            try deliver()
            return
        }
        let restore = Self.restorable(window.firstResponder)
        let previousPaneID = self.paneID
        self.paneID = paneID
        defer { self.paneID = previousPaneID }
        window.makeFirstResponder(view)
        var completed = false
        defer {
            if completed { settle(beforeRestoring) }
            Self.restore(restore, in: window, from: view)
        }
        try deliver()
        completed = true
    }

    private static func restorable(_ responder: NSResponder?) -> Restore {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSControl {
            return .field(field, editor.selectedRange())
        }
        return .responder(responder)
    }

    private static func restore(_ restore: Restore, in window: NSWindow, from view: NSView) {
        guard window.firstResponder === view else { return }
        switch restore {
        case let .field(field, range):
            guard field.window === window, window.makeFirstResponder(field) else {
                window.makeFirstResponder(nil)
                return
            }
            field.currentEditor()?.selectedRange = range
        case let .responder(responder):
            if let previous = responder as? NSView, previous.window !== window {
                // The person's view went away meanwhile. Leave nothing
                // focused rather than the other agent's pane; the next
                // keystroke's focus repair hands input to the selected pane.
                window.makeFirstResponder(nil)
            } else {
                window.makeFirstResponder(responder)
            }
        }
    }
}
