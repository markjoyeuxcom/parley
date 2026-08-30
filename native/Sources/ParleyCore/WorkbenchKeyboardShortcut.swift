import Foundation

/// Commands Parley must receive even while Ghostty owns the first responder.
/// Matching is deliberately exact so ordinary terminal input and familiar
/// copy/paste shortcuts remain vendor-owned.
public enum WorkbenchKeyboardShortcut: Equatable, Sendable {
    case nextWorkspace
    case previousWorkspace
    case nextPane
    case previousPane
    case selectPane(Int)
    case toggleFocusCanvas
    case focusActiveTerminal
    case toggleCollaborationDock

    public static func resolve(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> WorkbenchKeyboardShortcut? {
        let key = key.lowercased()

        if control, !command, !option, key == "tab" {
            return shift ? .previousWorkspace : .nextWorkspace
        }
        if control, option, !command, !shift {
            if key == "right" { return .nextPane }
            if key == "left" { return .previousPane }
        }
        if command, !control, !option, !shift,
           key.count == 1,
           let value = Int(key),
           (1 ... 9).contains(value) {
            return .selectPane(value - 1)
        }
        if command, shift, !option, !control {
            if key == "f" { return .toggleFocusCanvas }
            if key == "d" { return .toggleCollaborationDock }
        }
        if command, option, !shift, !control, key == "t" {
            return .focusActiveTerminal
        }
        return nil
    }
}
