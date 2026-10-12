import Foundation

/// The cursor shapes Ghostty draws. `blockHollow` is Ghostty's `block_hollow`.
public enum TerminalCursorShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case block
    case bar
    case underline
    case blockHollow

    public var id: String { rawValue }

    public var ghosttyValue: String {
        self == .blockHollow ? "block_hollow" : rawValue
    }

    public var label: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        case .blockHollow: "Hollow block"
        }
    }
}

/// Whether the cursor blinks: Ghostty's own `cursor-style-blink`, where blank
/// means the program's DECSCUSR choice (or the system default) decides.
public enum TerminalCursorBlink: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case on
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "Follow the program"
        case .on: "Blink"
        case .off: "Steady"
        }
    }
}

/// One `key = value` line of Ghostty configuration.
public struct GhosttyConfigLine: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    public var rendered: String { "\(key) = \(value)" }
}

public enum TerminalSurfacePreferenceError: LocalizedError, Equatable, Sendable {
    case outOfRange(String)
    case invalidThemeName

    public var errorDescription: String? {
        switch self {
        case let .outOfRange(field):
            "The terminal setting \(field) is outside the range Parley allows."
        case .invalidThemeName:
            "A Ghostty theme name must be one line of printable text."
        }
    }
}

/// The Ghostty options a pane's surface takes from Settings › Terminal: a
/// curated set, every value bounded, rendered as explicit `key = value` lines
/// so a pane behaves the same whatever Ghostty's own default becomes. Nothing
/// here can name a program, a file or an environment variable; the keys that
/// could (`command`, `env`, `working-directory`, `config-file`, shaders, shell
/// integration's script) are never rendered, and `forbiddenKeys` keeps a check
/// honest about it. Fonts and imported colours stay with
/// `TerminalFontPreference` and `GhosttyAppearanceImport`.
///
/// Ghostty applies most of these to a live surface. The scrollback limit and
/// the background opacity reach only surfaces created afterwards, and Settings
/// says so beside them.
public struct TerminalSurfacePreference: Codable, Equatable, Sendable {
    public static let thickenStrengthRange = 0 ... 255
    public static let cellHeightAdjustmentRange = -50 ... 50
    public static let cursorOpacityRange = 0.1 ... 1.0
    public static let minimumContrastRange = 1.0 ... 21.0
    public static let backgroundOpacityRange = 0.1 ... 1.0
    public static let backgroundBlurRange = 0 ... 64
    public static let paddingRange = 0 ... 64
    public static let scrollbackMegabytesRange = 1 ... 1000
    public static let scrollMultiplierRange = 0.1 ... 100.0
    public static let maximumThemeNameLength = 80

    /// Ghostty keys Parley never renders from preferences, whatever a future
    /// field is called: each names a program, a file, an environment variable
    /// or the terminal's identity, which belong to the launch review.
    public static let forbiddenKeys: Set<String> = [
        "command", "initial-command", "env", "working-directory", "config-file",
        "config-default-files", "custom-shader", "shell-integration", "keybind",
        "term", "title", "class", "x11-instance-name", "font-family",
    ]

    // Font rendering
    public var fontThicken = false
    public var fontThickenStrength = 255
    public var ligatures = true
    public var cellHeightAdjustment = 0

    // Cursor
    public var cursorShape = TerminalCursorShape.block
    public var cursorBlink = TerminalCursorBlink.system
    public var cursorOpacity = 1.0

    // Theme and colours. Names come from the Ghostty theme catalogue the app
    // bundles; membership is checked where the catalogue lives.
    public var lightTheme: String?
    public var darkTheme: String?
    public var minimumContrast = 1.0

    // Background and padding
    public var backgroundOpacity = 1.0
    public var backgroundBlur = 0
    public var paddingX = 2
    public var paddingY = 2

    // Scrollback
    public var scrollbackLimitMegabytes = 50

    // Mouse and clipboard
    public var hideMouseWhileTyping = false
    public var clickToMoveCursor = true
    /// Nil keeps Ghostty's per-device default (3 for a wheel, 1 for a trackpad).
    public var scrollMultiplier: Double?
    public var copyOnSelect = false
    public var pasteProtection = true
    public var linkDetection = true

    // Shell integration features
    public var shellCursor = true
    public var shellSudo = false
    public var shellTitle = true
    public var shellPath = true

    public init() {}

    public static let ghosttyDefault = TerminalSurfacePreference()

    private enum CodingKeys: String, CodingKey {
        case fontThicken, fontThickenStrength, ligatures, cellHeightAdjustment
        case cursorShape, cursorBlink, cursorOpacity
        case lightTheme, darkTheme, minimumContrast
        case backgroundOpacity, backgroundBlur, paddingX, paddingY
        case scrollbackLimitMegabytes
        case hideMouseWhileTyping, clickToMoveCursor, scrollMultiplier, copyOnSelect, pasteProtection, linkDetection
        case shellCursor, shellSudo, shellTitle, shellPath
    }

    /// A stored preference from another version keeps its defaults for any
    /// field it lacks, and is still bounded.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var preference = TerminalSurfacePreference()
        preference.fontThicken = try values.decodeIfPresent(Bool.self, forKey: .fontThicken) ?? preference.fontThicken
        preference.fontThickenStrength = try values.decodeIfPresent(Int.self, forKey: .fontThickenStrength) ?? preference.fontThickenStrength
        preference.ligatures = try values.decodeIfPresent(Bool.self, forKey: .ligatures) ?? preference.ligatures
        preference.cellHeightAdjustment = try values.decodeIfPresent(Int.self, forKey: .cellHeightAdjustment) ?? preference.cellHeightAdjustment
        preference.cursorShape = try values.decodeIfPresent(TerminalCursorShape.self, forKey: .cursorShape) ?? preference.cursorShape
        preference.cursorBlink = try values.decodeIfPresent(TerminalCursorBlink.self, forKey: .cursorBlink) ?? preference.cursorBlink
        preference.cursorOpacity = try values.decodeIfPresent(Double.self, forKey: .cursorOpacity) ?? preference.cursorOpacity
        preference.lightTheme = try values.decodeIfPresent(String.self, forKey: .lightTheme)
        preference.darkTheme = try values.decodeIfPresent(String.self, forKey: .darkTheme)
        preference.minimumContrast = try values.decodeIfPresent(Double.self, forKey: .minimumContrast) ?? preference.minimumContrast
        preference.backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? preference.backgroundOpacity
        preference.backgroundBlur = try values.decodeIfPresent(Int.self, forKey: .backgroundBlur) ?? preference.backgroundBlur
        preference.paddingX = try values.decodeIfPresent(Int.self, forKey: .paddingX) ?? preference.paddingX
        preference.paddingY = try values.decodeIfPresent(Int.self, forKey: .paddingY) ?? preference.paddingY
        preference.scrollbackLimitMegabytes = try values.decodeIfPresent(Int.self, forKey: .scrollbackLimitMegabytes) ?? preference.scrollbackLimitMegabytes
        preference.hideMouseWhileTyping = try values.decodeIfPresent(Bool.self, forKey: .hideMouseWhileTyping) ?? preference.hideMouseWhileTyping
        preference.clickToMoveCursor = try values.decodeIfPresent(Bool.self, forKey: .clickToMoveCursor) ?? preference.clickToMoveCursor
        preference.scrollMultiplier = try values.decodeIfPresent(Double.self, forKey: .scrollMultiplier)
        preference.copyOnSelect = try values.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? preference.copyOnSelect
        preference.pasteProtection = try values.decodeIfPresent(Bool.self, forKey: .pasteProtection) ?? preference.pasteProtection
        preference.linkDetection = try values.decodeIfPresent(Bool.self, forKey: .linkDetection) ?? preference.linkDetection
        preference.shellCursor = try values.decodeIfPresent(Bool.self, forKey: .shellCursor) ?? preference.shellCursor
        preference.shellSudo = try values.decodeIfPresent(Bool.self, forKey: .shellSudo) ?? preference.shellSudo
        preference.shellTitle = try values.decodeIfPresent(Bool.self, forKey: .shellTitle) ?? preference.shellTitle
        preference.shellPath = try values.decodeIfPresent(Bool.self, forKey: .shellPath) ?? preference.shellPath
        self = try preference.validated()
    }

    /// The same preference, or the first field outside its range.
    public func validated() throws -> TerminalSurfacePreference {
        func check(_ name: String, _ ok: Bool) throws {
            guard ok else { throw TerminalSurfacePreferenceError.outOfRange(name) }
        }
        try check("fontThickenStrength", Self.thickenStrengthRange.contains(fontThickenStrength))
        try check("cellHeightAdjustment", Self.cellHeightAdjustmentRange.contains(cellHeightAdjustment))
        try check("cursorOpacity", cursorOpacity.isFinite && Self.cursorOpacityRange.contains(cursorOpacity))
        try check("minimumContrast", minimumContrast.isFinite && Self.minimumContrastRange.contains(minimumContrast))
        try check("backgroundOpacity", backgroundOpacity.isFinite && Self.backgroundOpacityRange.contains(backgroundOpacity))
        try check("backgroundBlur", Self.backgroundBlurRange.contains(backgroundBlur))
        try check("paddingX", Self.paddingRange.contains(paddingX))
        try check("paddingY", Self.paddingRange.contains(paddingY))
        try check("scrollbackLimitMegabytes", Self.scrollbackMegabytesRange.contains(scrollbackLimitMegabytes))
        if let scrollMultiplier {
            try check("scrollMultiplier", scrollMultiplier.isFinite && Self.scrollMultiplierRange.contains(scrollMultiplier))
        }
        var result = self
        result.lightTheme = try Self.normalizedThemeName(lightTheme)
        result.darkTheme = try Self.normalizedThemeName(darkTheme)
        return result
    }

    /// Trimmed, non-empty, one line, bounded; nil stays nil and an empty
    /// field becomes nil.
    public static func normalizedThemeName(_ name: String?) throws -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= maximumThemeNameLength,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw TerminalSurfacePreferenceError.invalidThemeName }
        return trimmed
    }

    /// Every key `ghosttyLines` can emit, for the check that none is forbidden.
    public static let renderedKeys: [String] = [
        "font-thicken", "font-thicken-strength", "font-feature", "adjust-cell-height",
        "cursor-style", "cursor-style-blink", "cursor-opacity", "minimum-contrast",
        "background-opacity", "background-blur", "window-padding-x", "window-padding-y",
        "scrollback-limit-bytes", "mouse-hide-while-typing", "cursor-click-to-move",
        "mouse-scroll-multiplier", "copy-on-select", "clipboard-paste-protection", "link-url",
        "shell-integration-features",
    ]

    /// The configuration lines for a surface, in a fixed order. Themes are
    /// not lines: their colours are applied as the surface's light and dark
    /// theme by the caller that owns the catalogue.
    public var ghosttyLines: [GhosttyConfigLine] {
        var lines: [GhosttyConfigLine] = [
            GhosttyConfigLine("font-thicken", String(fontThicken)),
            GhosttyConfigLine("font-thicken-strength", String(fontThickenStrength)),
        ]
        if !ligatures {
            lines.append(GhosttyConfigLine("font-feature", "-calt,-liga,-dlig"))
        }
        if cellHeightAdjustment != 0 {
            lines.append(GhosttyConfigLine("adjust-cell-height", "\(cellHeightAdjustment)%"))
        }
        lines.append(GhosttyConfigLine("cursor-style", cursorShape.ghosttyValue))
        switch cursorBlink {
        case .system: break
        case .on: lines.append(GhosttyConfigLine("cursor-style-blink", "true"))
        case .off: lines.append(GhosttyConfigLine("cursor-style-blink", "false"))
        }
        lines.append(GhosttyConfigLine("cursor-opacity", Self.decimal(cursorOpacity, maximumFractionDigits: 3)))
        lines.append(GhosttyConfigLine("minimum-contrast", Self.decimal(minimumContrast, maximumFractionDigits: 2)))
        lines.append(GhosttyConfigLine("background-opacity", Self.decimal(backgroundOpacity, maximumFractionDigits: 3)))
        lines.append(GhosttyConfigLine("background-blur", backgroundBlur == 0 ? "false" : String(backgroundBlur)))
        lines.append(GhosttyConfigLine("window-padding-x", String(paddingX)))
        lines.append(GhosttyConfigLine("window-padding-y", String(paddingY)))
        lines.append(GhosttyConfigLine("scrollback-limit-bytes", String(scrollbackLimitMegabytes * 1_000_000)))
        lines.append(GhosttyConfigLine("mouse-hide-while-typing", String(hideMouseWhileTyping)))
        lines.append(GhosttyConfigLine("cursor-click-to-move", String(clickToMoveCursor)))
        if let scrollMultiplier {
            lines.append(GhosttyConfigLine("mouse-scroll-multiplier", Self.decimal(scrollMultiplier, maximumFractionDigits: 2)))
        }
        lines.append(GhosttyConfigLine("copy-on-select", copyOnSelect ? "clipboard" : "none"))
        lines.append(GhosttyConfigLine("clipboard-paste-protection", String(pasteProtection)))
        lines.append(GhosttyConfigLine("link-url", String(linkDetection)))
        let features = [
            shellCursor ? "cursor" : "no-cursor",
            shellSudo ? "sudo" : "no-sudo",
            shellTitle ? "title" : "no-title",
            "no-ssh-env",
            "no-ssh-terminfo",
            shellPath ? "path" : "no-path",
        ]
        lines.append(GhosttyConfigLine("shell-integration-features", features.joined(separator: ",")))
        return lines
    }

    /// Ghostty parses numbers with a `.` separator and ASCII digits only, so
    /// the device region must not shape them.
    public static func decimal(_ value: Double, maximumFractionDigits: Int) -> String {
        value.formatted(
            FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0 ... maximumFractionDigits))
                .grouping(.never)
        )
    }
}
