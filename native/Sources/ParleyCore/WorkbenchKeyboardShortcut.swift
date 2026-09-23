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
    case quickRelaySelection

    case nextAttention
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
            if key == "a" { return .quickRelaySelection }
            if key == "j" { return .nextAttention }
        }
        if command, option, !shift, !control, key == "t" {
            return .focusActiveTerminal
        }
        return nil
    }
}

/// The Pane menu's New Claude, Codex, Agy, Shell and Copilot Pane chords:
/// Option-Command with a digit, beside Option-Command-N for New Agent Pane.
/// Until 23 September 2026 they were Shift-Command-1 to 5, and macOS takes
/// Shift-Command-3, 4 and 5 for screenshots before any application sees
/// them, so three of the five never reached Parley.
public struct PaneCreationShortcut: Equatable, Sendable {
    public let kind: PaneKind
    public let key: Character

    public static let all: [PaneCreationShortcut] = [
        .init(kind: .claude, key: "1"),
        .init(kind: .codex, key: "2"),
        .init(kind: .agy, key: "3"),
        .init(kind: .shell, key: "4"),
        .init(kind: .copilot, key: "5"),
    ]

    public static func key(for kind: PaneKind) -> Character? {
        all.first { $0.kind == kind }?.key
    }

    /// As Help writes it.
    public var displayName: String { "Option-Command-\(key)" }
}

/// Chords macOS takes system-wide in its default configuration, before the
/// frontmost application receives them. A Parley menu shortcut must avoid
/// every one of these.
public enum SystemReservedShortcut {
    public struct Chord: Hashable, Sendable {
        public let key: Character
        public let command: Bool
        public let shift: Bool
        public let option: Bool
        public let control: Bool
        public init(key: Character, command: Bool, shift: Bool, option: Bool, control: Bool) {
            self.key = key
            self.command = command
            self.shift = shift
            self.option = option
            self.control = control
        }
    }

    public static let macOSDefaults: Set<Chord> = [
        // Screenshots and the screenshot toolbar.
        .init(key: "3", command: true, shift: true, option: false, control: false),
        .init(key: "4", command: true, shift: true, option: false, control: false),
        .init(key: "5", command: true, shift: true, option: false, control: false),
        .init(key: "6", command: true, shift: true, option: false, control: false),
        .init(key: "3", command: true, shift: true, option: false, control: true),
        .init(key: "4", command: true, shift: true, option: false, control: true),
        // Spotlight, Finder search, input sources and Character Viewer.
        .init(key: " ", command: true, shift: false, option: false, control: false),
        .init(key: " ", command: true, shift: false, option: true, control: false),
        .init(key: " ", command: false, shift: false, option: false, control: true),
        .init(key: " ", command: true, shift: false, option: false, control: true),
        // Lock Screen, Dock hiding and Force Quit Applications.
        .init(key: "q", command: true, shift: false, option: false, control: true),
        .init(key: "d", command: true, shift: false, option: true, control: false),
        .init(key: "\u{1b}", command: true, shift: false, option: true, control: false),
    ]
}
