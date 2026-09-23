import AppKit
import Foundation
import ParleyCore
import ParleyUI
import SwiftUI

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
    // A curly quote inside an argument is not blamed for an unrelated error.
    let legit = try ReviewedCommand(argv: ["/usr/bin/printf", "\u{201C}hi\u{201D}"], folder: folder, sourceFolder: folder)
    let broken = String(legit.display.dropLast()) // missing the closing ]
    do {
        _ = try ReviewedCommand.parseDisplay(broken)
        throw NSError(domain: "CommandRunArgvEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "an unclosed array parsed"])
    } catch let error as ReviewedCommandRunError {
        try argvExpect(!error.localizedDescription.contains("typographic"), "a legitimate curly quote was blamed: \(error.localizedDescription)")
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

/// Agy's review of 09bf4d0 (HIGH-1): a text view reused for different
/// content kept the undo history of the previous content, and ⌘Z then
/// replayed an edit at offsets past the end of the new text.
func checkPlainTextEditorUndoBelongsToItsText() throws {
    try MainActor.assumeIsolated {
        var bound = "abc"
        let coordinator = PlainTextEditor.Coordinator(text: Binding(get: { bound }, set: { bound = $0 }))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        PlainTextEditor.configure(view)
        view.delegate = coordinator
        view.string = "part A with a long body"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(" plus typing", replacementRange: view.selectedRange())
        try argvExpect(coordinator.undo.canUndo, "typing did not register with the editor's own undo history")
        PlainTextEditor.replaceText(of: view, with: "B", coordinator: coordinator)
        try argvExpect(!coordinator.undo.canUndo, "undo history for the previous text survived an outside replacement")
        coordinator.undo.undo()
        try argvExpect(view.string == "B", "undo changed the replaced text: \(view.string)")
    }
}

@MainActor let commandRunArgvEditorChecks: [(String, () throws -> Void)] = [
    ("command run argv text is plain and explained", checkCommandRunArgvTextIsPlainAndExplained),
    ("plain text editor disables substitutions", checkPlainTextEditorDisablesSubstitutions),
    ("plain text editor undo belongs to its text", checkPlainTextEditorUndoBelongsToItsText),
]
