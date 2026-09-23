import Foundation
import ParleyCore

private func shortcutExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "PaneShortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026, c3074370: New Agy, Shell and Copilot Pane
/// used Shift-Command-3, 4 and 5, the macOS screenshot hotkeys, which the
/// system takes before any application. Mark chose Option-Command-1 to 5 on
/// 23 September 2026, beside Option-Command-N.
func checkPaneCreationShortcutsReachParley() throws {
    let shortcuts = PaneCreationShortcut.all
    try shortcutExpect(shortcuts.map(\.kind) == [.claude, .codex, .agy, .shell, .copilot],
                       "the pane creation shortcuts do not cover each kind once, in menu order: \(shortcuts.map(\.kind))")
    try shortcutExpect(shortcuts.map(\.key) == ["1", "2", "3", "4", "5"], "the pane creation keys changed: \(shortcuts.map(\.key))")
    for shortcut in shortcuts {
        let chord = SystemReservedShortcut.Chord(key: shortcut.key, command: true, shift: false, option: true, control: false)
        try shortcutExpect(!SystemReservedShortcut.macOSDefaults.contains(chord),
                           "\(shortcut.displayName) is a macOS default hotkey the system takes first")
        try shortcutExpect(WorkbenchKeyboardShortcut.resolve(key: String(shortcut.key), command: true, shift: false, option: true, control: false) == nil,
                           "\(shortcut.displayName) is taken by Parley's own key monitor before the menu")
    }
    // The table holds the chords that took the old shortcuts.
    for key: Character in ["3", "4", "5"] {
        try shortcutExpect(SystemReservedShortcut.macOSDefaults.contains(.init(key: key, command: true, shift: true, option: false, control: false)),
                           "Shift-Command-\(key) is missing from the macOS defaults")
    }
    let help = ParleyHelpGuide.topics.map(\.searchableText).joined(separator: "\n")
    for shortcut in shortcuts {
        try shortcutExpect(help.contains(shortcut.displayName), "Help does not list \(shortcut.displayName)")
    }
    for stale in ["Command-Shift-1", "Command-Shift-2", "Command-Shift-3", "Command-Shift-4", "Command-Shift-5", "Shift-Command-1, 2, 3 and 5"] {
        try shortcutExpect(!help.contains(stale), "Help still lists \(stale)")
    }
}

@MainActor let paneShortcutChecks: [(String, () throws -> Void)] = [
    ("pane creation shortcuts reach parley", checkPaneCreationShortcutsReachParley),
]
