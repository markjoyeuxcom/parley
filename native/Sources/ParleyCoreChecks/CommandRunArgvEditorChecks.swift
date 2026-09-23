import AppKit
import Foundation
import ParleyCore
import ParleyUI

private func argvExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "CommandRunArgvEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Found on 23 September 2026 approving a run in v0.1.61: the arguments
/// editor, a SwiftUI TextEditor, left macOS smart quotes on, so a closing
/// quote became `”` and approval failed with "The data couldn't be read
/// because it isn't in the correct format". The preview also showed every
/// `/` as `\/`, making the command harder to check.
func checkCommandRunArgvTextIsPlainAndExplained() throws {
    let argv = ["/bin/sh", "-c", "read x < /dev/tty", "line\nbreak", ""]
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let command = try ReviewedCommand(argv: argv, folder: folder, sourceFolder: folder)
    try argvExpect(!command.display.contains("\\/"), "the preview escapes slashes: \(command.display)")
    try argvExpect(command.display.contains("\\n") && command.display.contains("\"\""),
                   "control characters or an empty argument are no longer explicit: \(command.display)")
    try argvExpect(try ReviewedCommand.parseDisplay(command.display) == argv, "the preview does not read back as the same argv")
    // A typographic quote where JSON needs a plain one is named, not reported as a format error.
    let curly = command.display.replacingOccurrences(of: "\"]", with: "\u{201D}]")
    do {
        _ = try ReviewedCommand.parseDisplay(curly)
        throw NSError(domain: "CommandRunArgvEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "a curly closing quote parsed"])
    } catch let error as ReviewedCommandRunError {
        try argvExpect(error.localizedDescription.contains("\u{201D}") && error.localizedDescription.contains("plain"),
                       "the error does not name the typographic quote: \(error.localizedDescription)")
    }
    // A curly quote inside an argument is data and survives unchanged.
    let quoted = try ReviewedCommand(argv: ["/usr/bin/printf", "\u{201C}hi\u{201D}"], folder: folder, sourceFolder: folder)
    try argvExpect(try ReviewedCommand.parseDisplay(quoted.display) == quoted.argv, "a curly quote inside an argument was changed")
}

/// The editor turns off every automatic substitution that could change what
/// the person approves.
func checkPlainTextEditorDisablesSubstitutions() throws {
    try MainActor.assumeIsolated {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        PlainTextEditor.configure(view)
        try argvExpect(!view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled
                       && !view.isAutomaticTextReplacementEnabled && !view.isAutomaticSpellingCorrectionEnabled
                       && !view.isContinuousSpellCheckingEnabled && !view.isAutomaticLinkDetectionEnabled
                       && !view.isAutomaticDataDetectionEnabled && !view.isRichText,
                       "the arguments editor leaves an automatic substitution on")
    }
}

@MainActor let commandRunArgvEditorChecks: [(String, () throws -> Void)] = [
    ("command run argv text is plain and explained", checkCommandRunArgvTextIsPlainAndExplained),
    ("plain text editor disables substitutions", checkPlainTextEditorDisablesSubstitutions),
]
