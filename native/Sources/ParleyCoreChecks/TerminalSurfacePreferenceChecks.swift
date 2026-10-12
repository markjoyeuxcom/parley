import Foundation
import GhosttyTerminal
import ParleyCore

private func tsExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "TerminalSurfacePreference", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// The defaults mirror Ghostty's own and render as explicit lines in a fixed
/// order, so a surface behaves the same whatever Ghostty's default becomes.
func checkTerminalSurfaceDefaultsRenderExplicitGhosttyLines() throws {
    let lines = TerminalSurfacePreference.ghosttyDefault.ghosttyLines.map(\.rendered)
    let expected = [
        "font-thicken = false",
        "font-thicken-strength = 255",
        "cursor-style = block",
        "cursor-opacity = 1",
        "minimum-contrast = 1",
        "background-opacity = 1",
        "background-blur = false",
        "window-padding-x = 2",
        "window-padding-y = 2",
        "scrollback-limit-bytes = 50000000",
        "mouse-hide-while-typing = false",
        "cursor-click-to-move = true",
        "copy-on-select = none",
        "clipboard-paste-protection = true",
        "link-url = true",
        "shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path",
    ]
    try tsExpect(lines == expected, "the default surface lines changed:\n\(lines.joined(separator: "\n"))")
    try tsExpect(TerminalSurfacePreference.ghosttyDefault.lightTheme == nil && TerminalSurfacePreference.ghosttyDefault.darkTheme == nil,
                 "the default preference names a theme")
}

/// Every optional or mapped field renders the Ghostty spelling, with numbers
/// formatted for Ghostty's parser whatever the device region.
func checkTerminalSurfaceLinesMapEachField() throws {
    var preference = TerminalSurfacePreference()
    preference.fontThicken = true
    preference.fontThickenStrength = 128
    preference.ligatures = false
    preference.cellHeightAdjustment = -10
    preference.cursorShape = .blockHollow
    preference.cursorBlink = .off
    preference.cursorOpacity = 0.75
    preference.minimumContrast = 1.1
    preference.backgroundOpacity = 0.925
    preference.backgroundBlur = 20
    preference.paddingX = 8
    preference.paddingY = 4
    preference.scrollbackLimitMegabytes = 200
    preference.hideMouseWhileTyping = true
    preference.clickToMoveCursor = false
    preference.scrollMultiplier = 1.5
    preference.copyOnSelect = true
    preference.pasteProtection = false
    preference.linkDetection = false
    preference.shellCursor = false
    preference.shellSudo = true
    preference.shellTitle = false
    preference.shellPath = false
    let lines = try preference.validated().ghosttyLines.map(\.rendered)
    let expected = [
        "font-thicken = true",
        "font-thicken-strength = 128",
        "font-feature = -calt,-liga,-dlig",
        "adjust-cell-height = -10%",
        "cursor-style = block_hollow",
        "cursor-style-blink = false",
        "cursor-opacity = 0.75",
        "minimum-contrast = 1.1",
        "background-opacity = 0.925",
        "background-blur = 20",
        "window-padding-x = 8",
        "window-padding-y = 4",
        "scrollback-limit-bytes = 200000000",
        "mouse-hide-while-typing = true",
        "cursor-click-to-move = false",
        "mouse-scroll-multiplier = 1.5",
        "copy-on-select = clipboard",
        "clipboard-paste-protection = false",
        "link-url = false",
        "shell-integration-features = no-cursor,sudo,no-title,no-ssh-env,no-ssh-terminfo,no-path",
    ]
    try tsExpect(lines == expected, "a field did not render as its Ghostty line:\n\(lines.joined(separator: "\n"))")
    var blinking = TerminalSurfacePreference()
    blinking.cursorBlink = .on
    try tsExpect(blinking.ghosttyLines.map(\.rendered).contains("cursor-style-blink = true"), "a blinking cursor did not render")
    try tsExpect(TerminalSurfacePreference.decimal(0.1, maximumFractionDigits: 3) == "0.1"
                 && TerminalSurfacePreference.decimal(2, maximumFractionDigits: 2) == "2",
                 "decimals are not formatted for Ghostty's parser")
}

/// No line Parley can render names a program, a file or an environment
/// variable, and every emitted key is declared.
func checkTerminalSurfaceLinesNeverReachForbiddenKeys() throws {
    let declared = Set(TerminalSurfacePreference.renderedKeys)
    try tsExpect(declared.isDisjoint(with: TerminalSurfacePreference.forbiddenKeys), "a declared key is forbidden")
    var everything = TerminalSurfacePreference()
    everything.ligatures = false
    everything.cellHeightAdjustment = 5
    everything.cursorBlink = .on
    everything.scrollMultiplier = 2
    let emitted = Set(everything.ghosttyLines.map(\.key))
    try tsExpect(emitted == declared, "the emitted keys differ from the declared ones: \(emitted.symmetricDifference(declared))")
    for line in everything.ghosttyLines {
        try tsExpect(!line.value.contains("\n") && !line.key.contains("\n"), "a line carries a newline: \(line.rendered)")
    }
}

/// Out-of-range values are refused by name; a theme name is one bounded line.
func checkTerminalSurfaceValidationIsBounded() throws {
    func refused(_ field: String, _ mutate: (inout TerminalSurfacePreference) -> Void) throws {
        var preference = TerminalSurfacePreference()
        mutate(&preference)
        do {
            _ = try preference.validated()
            throw NSError(domain: "TerminalSurfacePreference", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(field) out of range was accepted"])
        } catch let error as TerminalSurfacePreferenceError {
            try tsExpect(error == .outOfRange(field), "\(field) failed for the wrong reason: \(error)")
        }
    }
    try refused("fontThickenStrength") { $0.fontThickenStrength = 256 }
    try refused("cellHeightAdjustment") { $0.cellHeightAdjustment = -51 }
    try refused("cursorOpacity") { $0.cursorOpacity = 0 }
    try refused("cursorOpacity") { $0.cursorOpacity = .nan }
    try refused("minimumContrast") { $0.minimumContrast = 22 }
    try refused("backgroundOpacity") { $0.backgroundOpacity = 1.01 }
    try refused("backgroundBlur") { $0.backgroundBlur = 65 }
    try refused("paddingX") { $0.paddingX = -1 }
    try refused("paddingY") { $0.paddingY = 65 }
    try refused("scrollbackLimitMegabytes") { $0.scrollbackLimitMegabytes = 0 }
    try refused("scrollbackLimitMegabytes") { $0.scrollbackLimitMegabytes = 1001 }
    try refused("scrollMultiplier") { $0.scrollMultiplier = .infinity }
    for name in ["Two\nLines", "Tab\there", String(repeating: "x", count: 81)] {
        var preference = TerminalSurfacePreference()
        preference.lightTheme = name
        do {
            _ = try preference.validated()
            throw NSError(domain: "TerminalSurfacePreference", code: 1, userInfo: [NSLocalizedDescriptionKey: "an unsafe theme name was accepted"])
        } catch let error as TerminalSurfacePreferenceError {
            try tsExpect(error == .invalidThemeName, "a theme name failed for the wrong reason: \(error)")
        }
    }
    var padded = TerminalSurfacePreference()
    padded.lightTheme = "  Catppuccin Mocha  "
    padded.darkTheme = "   "
    let normalized = try padded.validated()
    try tsExpect(normalized.lightTheme == "Catppuccin Mocha" && normalized.darkTheme == nil, "theme names were not normalised")
}

/// Stored preferences round trip; one from another version keeps defaults
/// for fields it lacks, ignores fields it does not know, and is still
/// refused when out of range.
func checkTerminalSurfacePreferenceSurvivesVersions() throws {
    var preference = TerminalSurfacePreference()
    preference.scrollbackLimitMegabytes = 120
    preference.darkTheme = "Dracula"
    preference.scrollMultiplier = 2.5
    let decoded = try JSONDecoder().decode(TerminalSurfacePreference.self, from: JSONEncoder().encode(preference))
    try tsExpect(decoded == preference, "the preference did not round trip")
    let partial = try JSONDecoder().decode(TerminalSurfacePreference.self, from: Data(#"{"paddingX": 6, "futureField": 1}"#.utf8))
    try tsExpect(partial.paddingX == 6 && partial.paddingY == 2 && partial.scrollbackLimitMegabytes == 50 && partial.scrollMultiplier == nil,
                 "a partial preference did not keep the other defaults")
    try tsExpect(try JSONDecoder().decode(TerminalSurfacePreference.self, from: Data("{}".utf8)) == .ghosttyDefault, "an empty preference is not the default")
    do {
        _ = try JSONDecoder().decode(TerminalSurfacePreference.self, from: Data(#"{"backgroundBlur": 999}"#.utf8))
        throw NSError(domain: "TerminalSurfacePreference", code: 1, userInfo: [NSLocalizedDescriptionKey: "a stored out-of-range value was accepted"])
    } catch is TerminalSurfacePreferenceError {}
}

/// The lines are only as good as Ghostty's parser says: both the default
/// set and every field changed go through the wrapper's own configuration
/// path, the one the registry uses at runtime, with no issue reported; a
/// key Ghostty does not know is refused there, so a silent pass is
/// impossible.
func checkGhosttyAcceptsTheCuratedSurfaceLines() throws {
    try MainActor.assumeIsolated {
    let controller = TerminalController()
    func configuration(_ lines: [GhosttyConfigLine]) -> TerminalConfiguration {
        lines.reduce(TerminalConfiguration()) { $0.custom($1.key, $1.value) }
    }
    var everything = TerminalSurfacePreference()
    everything.fontThicken = true
    everything.fontThickenStrength = 128
    everything.ligatures = false
    everything.cellHeightAdjustment = 10
    everything.cursorShape = .blockHollow
    everything.cursorBlink = .on
    everything.cursorOpacity = 0.6
    everything.minimumContrast = 1.1
    everything.backgroundOpacity = 0.9
    everything.backgroundBlur = 20
    everything.paddingX = 10
    everything.paddingY = 6
    everything.scrollbackLimitMegabytes = 1000
    everything.hideMouseWhileTyping = true
    everything.clickToMoveCursor = false
    everything.scrollMultiplier = 1.5
    everything.copyOnSelect = true
    everything.pasteProtection = false
    everything.linkDetection = false
    everything.shellCursor = false
    everything.shellSudo = true
    everything.shellTitle = false
    everything.shellPath = false
    for (name, preference) in [("defaults", TerminalSurfacePreference.ghosttyDefault), ("everything", everything)] {
        try tsExpect(controller.setTerminalConfiguration(configuration(preference.ghosttyLines)),
                     "Ghostty refused the \(name) surface lines: \(String(describing: controller.lastConfigurationIssue))")
    }
    try tsExpect(!controller.setTerminalConfiguration(TerminalConfiguration().custom("parley-no-such-key", "1")),
                 "Ghostty accepted an unknown key, so this check could not tell a refusal from acceptance")
    try tsExpect(controller.setTerminalConfiguration(configuration(TerminalSurfacePreference.ghosttyDefault.ghosttyLines)),
                 "the defaults were refused after a bad configuration")
    }
}

@MainActor let terminalSurfacePreferenceChecks: [(String, () throws -> Void)] = [
    ("ghostty accepts the curated surface lines", checkGhosttyAcceptsTheCuratedSurfaceLines),
    ("terminal surface defaults render explicit ghostty lines", checkTerminalSurfaceDefaultsRenderExplicitGhosttyLines),
    ("terminal surface lines map each field", checkTerminalSurfaceLinesMapEachField),
    ("terminal surface lines never reach forbidden keys", checkTerminalSurfaceLinesNeverReachForbiddenKeys),
    ("terminal surface validation is bounded", checkTerminalSurfaceValidationIsBounded),
    ("terminal surface preference survives versions", checkTerminalSurfacePreferenceSurvivesVersions),
]
