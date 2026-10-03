import Darwin
import Foundation
import ParleyCore

// The third branch of the 3 October 2026 polish discussion: Compare that
// uses the window, a launch review that says rather than recites, files
// checked before a pack is sent, and readable consequences.

private func reviewExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "CompareAndReview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func nativeText(_ folder: String, _ file: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8)).text
}

/// Compare's answers were fixed 330 by 390 point cards in a sideways scroller.
func checkCompareAnswersShareTheWindow() throws {
    let two = AskManyComparisonLayout.columns(available: 1_000, count: 2)
    try reviewExpect(two == (494, false), "two answers in 1,000 points are \(two)")
    let four = AskManyComparisonLayout.columns(available: 1_000, count: 4)
    try reviewExpect(four == (AskManyComparisonLayout.minimumColumnWidth, true), "four answers in 1,000 points are \(four)")
    try reviewExpect(AskManyComparisonLayout.columns(available: 1_000, count: 0).scrolls == false, "no answers scroll")
    try reviewExpect(!AskManyComparisonLayout.questionNeedsExpanding("One line."), "a short question offered to expand")
    try reviewExpect(AskManyComparisonLayout.questionNeedsExpanding("a\nb\nc\nd\ne"), "a five-line question was not offered in full")
    try reviewExpect(AskManyComparisonLayout.questionNeedsExpanding(String(repeating: "x", count: 400)), "a long one-line question was not offered in full")
    let view = try nativeText("ParleyNative", "AskManyComparisonView.swift")
    try reviewExpect(!view.contains(".frame(width: 330, height: 390)"), "Compare's fixed card size is back")
    try reviewExpect(view.contains("AskManyComparisonLayout.columns("), "Compare no longer sizes its columns to the window")
    try reviewExpect(view.contains("case oneAtATime"), "Compare lost One at a Time")
}

/// The launch review recited Agy's settings recipe and could not say
/// whether it had been followed. It now reads the file without changing it.
func checkAgyAllowEntryIsReadNotRecited() throws {
    func fact(_ json: String) -> AgyParleyAllowFact { AgyHostConfiguration.parleyAllowFact(settingsData: Data(json.utf8)) }
    let entry = AgyHostConfiguration.allowEntry
    try reviewExpect(entry == #"command("$PARLEY_COMMAND")"#, "the recommended entry changed: \(entry)")
    try reviewExpect(AgyHostConfiguration.parleyAllowFact(settingsData: nil) == .unknown, "unreadable settings read as known")
    try reviewExpect(fact("not json") == .unknown, "invalid settings read as known")
    try reviewExpect(fact(#"{"trustedWorkspaces": []}"#) == .absent, "settings with no permissions did not read as absent")
    try reviewExpect(fact(#"{"permissions": {"allow": ["command(git)"]}}"#) == .absent, "an unrelated allow rule counted")
    try reviewExpect(fact(#"{"permissions": {"allow": ["command(\"$PARLEY_COMMAND\")"]}}"#) == .allowed(byWildcard: false), "the entry was not found")
    try reviewExpect(fact(#"{"permissions": {"allow": ["command(*)"]}}"#) == .allowed(byWildcard: true), "command(*) was not recognised")
    try reviewExpect(fact(#"{"permissions": {"allow": ["command(\"$PARLEY_COMMAND\")"], "ask": ["command(*)"]}}"#) == .overridden(list: "ask"),
                     "an ask rule did not override allow (Agy: Deny > Ask > Allow)")
    try reviewExpect(fact(#"{"permissions": {"allow": ["command(*)"], "deny": ["command(\"$PARLEY_COMMAND\")"]}}"#) == .overridden(list: "deny"),
                     "a deny rule did not override allow")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parley-agy-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try reviewExpect(AgyHostConfiguration.parleyAllowFact(settingsFile: directory.appendingPathComponent("none.json")) == .absent,
                     "a missing settings file did not read as absent")
    // A FIFO must be refused, never waited on.
    let fifo = directory.appendingPathComponent("settings.json")
    try reviewExpect(mkfifo(fifo.path, 0o600) == 0, "could not make the FIFO fixture")
    try reviewExpect(AgyHostConfiguration.parleyAllowFact(settingsFile: fifo) == .unknown, "a FIFO in place of the settings read as known")

    let review = try nativeText("ParleyNative", "PermissionProfilePickerView.swift")
    try reviewExpect(review.contains("agyAllowSection") && review.contains("Button(\"Copy Allow Entry\")"), "the review no longer reads Agy's settings")
    try reviewExpect(!review.contains("~/.gemini/antigravity-cli/settings.json yourself. Allow that absolute form"),
                     "the review recites the whole Agy recipe in its caption again")
    try reviewExpect(!review.contains("settings.json\", atomically") && !review.contains(".write(to: AgyHostConfiguration"),
                     "the review writes Agy's settings")
}

/// A file edited after it was added to a pack was sent as it had been, with
/// nothing said.
func checkPackFilesAreCheckedBeforeSending() throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("parley-fresh-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let builder = ContextPackBuilder()
    func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    let same = try builder.file(at: try file("same.md", "unchanged\n"))
    let changed = try builder.file(at: try file("changed.md", "before\n"))
    let edited = try builder.file(at: try file("edited.md", "before\n")).replacingText("my edit\n")
    let gone = try builder.file(at: try file("gone.md", "here\n"))
    let binary = try builder.file(at: try file("binary.md", "text\n"))
    _ = try file("changed.md", "after\n")
    _ = try file("edited.md", "after\n")
    try FileManager.default.removeItem(at: directory.appendingPathComponent("gone.md"))
    try Data([0, 1, 2]).write(to: directory.appendingPathComponent("binary.md"))
    let parts = [same, changed, edited, gone, binary]

    let items = ContextPackFreshness.check(parts, builder: builder)
    try reviewExpect(items.map(\.state) == [.unchanged, .changed, .changed, .missing, .unreadable], "states were \(items.map(\.state))")
    try reviewExpect(items.map(\.edited) == [false, false, true, false, false], "edited parts were not told apart")
    let summary = try ContextPackFreshness.summary(items) ?? ""
    try reviewExpect(summary.contains("changed.md: changed on disk") && summary.contains("gone.md: no longer there")
                     && summary.contains("binary.md: no longer reads") && !summary.contains("same.md"),
                     "the warning names the wrong files: \(summary)")
    try reviewExpect(ContextPackFreshness.summary(ContextPackFreshness.check([same], builder: builder)) == nil, "an unchanged pack warned")

    let recaptured = ContextPackFreshness.recaptured(parts, items: items)
    try reviewExpect(recaptured[1].capturedText.contains("after") && recaptured[1].id != changed.id, "a changed file was not captured again")
    try reviewExpect(recaptured[2] == edited, "a part the person edited was replaced")
    try reviewExpect(recaptured[0] == same && recaptured[3] == gone && recaptured[4] == binary, "an unchanged, missing or unreadable part was replaced")
    let agentPart = ContextPackPart(source: ContextPackSource(kind: .agentFileDraft, label: "x", detail: directory.path + "/same.md"), capturedText: "y")
    try reviewExpect(ContextPackFreshness.checkable([agentPart]).isEmpty, "an agent's claim was read again as the person's capture")

    let app = try nativeText("ParleyNative", "AppModel.swift")
    try reviewExpect(app.components(separatedBy: "whenContextFilesAreCurrent {").count == 3, "Ask and Compare do not both check the pack's files first")
    try reviewExpect(app.contains("ContextPackFreshness.check(parts, builder: contextPackBuilder)") && app.contains("Task.detached"),
                     "the files are not read again off the main actor")
}

/// Add Files took text only though packs hold images; image previews could
/// not be read at full size; consequences and recovery steps were 9-point grey.
func checkImageFilesAndReadableConsequences() throws {
    let image = ContextPackImage(format: .png, width: 4, height: 3, byteCount: 10, sha256: String(repeating: "a", count: 64))
    let part = ContextPackPart.personImageFile(image, path: "/private/project/shot.png")
    try reviewExpect(part.source.kind == .file && part.image == image && part.source.label == "shot.png", "an image file part is \(part.source)")
    try reviewExpect(ContextPackError.notText.errorDescription?.contains("PNG or JPEG") == true, "the not-text error does not name images")
    let app = try nativeText("ParleyNative", "AppModel.swift")
    try reviewExpect(app.contains("addContextImageFiles(images") && app.contains("kind: .imageFile"), "Add Files does not take images")
    let pack = try nativeText("ParleyNative", "ContextPackView.swift")
    try reviewExpect(pack.contains("Button(\"Inspect Full Size…\")") && pack.contains("ContextImageFullSizeSheet"), "image previews cannot be opened at full size")
    let status = try nativeText("ParleyNative", "StatusCenterView.swift")
    try reviewExpect(!status.contains("Text(\"\\(step + 1). \\(text)\")\n                                .font(.system(size: 9))"), "recovery steps are 9-point again")
}

@MainActor let compareAndReviewChecks: [(String, () throws -> Void)] = [
    ("compare answers share the window", checkCompareAnswersShareTheWindow),
    ("agy allow entry is read, not recited", checkAgyAllowEntryIsReadNotRecited),
    ("pack files are checked before sending", checkPackFilesAreCheckedBeforeSending),
    ("image files and readable consequences", checkImageFilesAndReadableConsequences),
]
