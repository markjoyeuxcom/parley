import Foundation

public enum ApplicationSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case terminal
    case voice
    case appearance
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general:
            "General"
        case .terminal:
            "Terminal"
        case .voice:
            "Voice"
        case .appearance:
            "Appearance"
        case .notifications:
            "Notifications"
        }
    }

    public var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .terminal:
            "terminal"
        case .voice:
            "mic"
        case .appearance:
            "textformat"
        case .notifications:
            "bell"
        }
    }

    /// The command palette lists one "<Title> Settings…" command per section,
    /// so every section is reachable without the Settings window open.
    public var paletteTitle: String { "\(title) Settings…" }

    public var paletteDetail: String {
        switch self {
        case .general:
            "Software updates, Swift package builds, local history retention and the session-only command-run switches"
        case .terminal:
            "Terminal type for new panes and the curated Ghostty surface options"
        case .voice:
            "Dictation language, local speech models and read-aloud"
        case .appearance:
            "Shared pane font and imported Ghostty colours"
        case .notifications:
            "Which workspaces send local attention notifications"
        }
    }

    /// Search words for the palette. Every section answers to "settings" and
    /// "preferences", then its own vocabulary.
    public var paletteKeywords: [String] {
        let shared = ["settings", "preferences"]
        switch self {
        case .general:
            return shared + ["updates", "sparkle", "release channel", "swiftpm", "swift package", "command runs", "retention", "history"]
        case .terminal:
            return shared + ["terminal type", "term", "xterm", "cursor", "scrollback", "mouse", "clipboard", "shell integration", "ghostty"]
        case .voice:
            return shared + ["dictate", "dictation", "speech", "microphone", "read aloud"]
        case .appearance:
            return shared + ["font", "size", "theme", "palette", "color", "colour", "import"]
        case .notifications:
            return shared + ["notification", "banner", "attention", "alert"]
        }
    }
}
