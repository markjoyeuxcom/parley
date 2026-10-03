import AppKit

/// Keeps a pointer that has not moved from taking a list's selection.
///
/// A row that selects itself on hover also receives a hover when the list
/// scrolls, or its rows change, under a pointer resting in it. In the command
/// palette that undid every arrow-key step that scrolled, and after typing it
/// replaced the top match that Return opens (Agy's review of 3 October 2026).
/// The keyboard records where the pointer was; a hover counts only once the
/// pointer is somewhere else.
public struct KeyboardSelectionHoverGuard: Equatable {
    private var pointerAtKeyboardSelection: NSPoint?

    public init() {}

    /// The keyboard, or a change of the list, chose the selection.
    public mutating func keyboardSelected(pointer: NSPoint) {
        pointerAtKeyboardSelection = pointer
    }

    /// Whether a hover may take the selection; true once the pointer moved.
    public mutating func acceptsHover(pointer: NSPoint) -> Bool {
        if let recorded = pointerAtKeyboardSelection, recorded == pointer { return false }
        pointerAtKeyboardSelection = nil
        return true
    }
}
