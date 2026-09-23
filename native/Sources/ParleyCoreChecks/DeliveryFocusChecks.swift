import AppKit
import Foundation
import GhosttyTerminal
import ParleyCore
import ParleyUI

private func focusExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "DeliveryFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026, M11: every delivery focused its target pane,
/// the focus callback made that pane the person's active pane, and focus was
/// restored only through `NSApp.keyWindow`. With Parley in the background or
/// Status Center key, the person was left on the other agent's pane and their
/// next keystrokes went there. Only Copilot's submission needs its pane
/// focused; every other delivery must leave focus alone.
func checkOnlyCopilotSubmissionMovesFocus() throws {
    for kind in PaneKind.allCases {
        for submit in [true, false] {
            let timing = PaneSubmissionTiming.forKind(kind, submit: submit)
            try focusExpect(timing.focusesTarget == (kind == .copilot && submit),
                            "\(kind) \(submit ? "submit" : "paste") \(timing.focusesTarget ? "moves" : "keeps") focus")
        }
    }
}

/// The premise of delivering without focus, on real Ghostty surfaces: text
/// and Enter sent to a pane that is not first responder run there, and the
/// person's pane keeps focus throughout.
func checkGhosttyDeliveryWithoutFocusKeepsThePersonsPane() throws {
    try GhosttyLaunchPreflight.check()
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("parley-focus-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TerminalController { $0.withBackgroundOpacity(1) }
        @MainActor func terminal(_ x: CGFloat) -> AppTerminalView {
            let view = AppTerminalView(frame: NSRect(x: x, y: 0, width: 400, height: 300))
            view.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: directory.path,
                                                        command: GhosttyLaunchCommand.render(["/bin/zsh", "-f"]), waitAfterCommand: true)
            return view
        }
        let person = terminal(0), target = terminal(400)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.addSubview(person)
        container.addSubview(target)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = container
        person.controller = controller
        target.controller = controller
        window.orderFront(nil)
        defer {
            person.controller = nil
            target.controller = nil
            window.close()
        }
        @MainActor func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        @MainActor func run(_ view: AppTerminalView, touching marker: URL) -> Bool {
            view.paste(text: GhosttyLaunchCommand.render(["/usr/bin/touch", marker.path])) && view.sendKey(.enter)
        }

        _ = person.acquireProgrammaticFocus()
        try focusExpect(window.firstResponder === person, "the person's pane did not take focus")
        let delivered = directory.appendingPathComponent("delivered")
        try focusExpect(run(target, touching: delivered), "Ghostty refused input for a pane without focus")
        try focusExpect(pump(until: { FileManager.default.fileExists(atPath: delivered.path) }),
                        "a pane without focus did not run the delivered command")
        try focusExpect(window.firstResponder === person, "delivering to another pane moved the person's focus")

        // Copilot's path: the pane is lent focus for the delivery and the
        // person's pane gets it back.
        let focus = DeliveryFocus()
        let lent = directory.appendingPathComponent("lent")
        var settled: [TimeInterval] = []
        try focus.deliver(focusing: target, paneID: "target", beforeRestoring: 0.1, settle: { settled.append($0) }) {
            try focusExpect(window.firstResponder === target && focus.paneID == "target", "the delivery did not hold the target's focus")
            try focusExpect(run(target, touching: lent), "Ghostty refused input for the focused target")
        }
        try focusExpect(pump(until: { FileManager.default.fileExists(atPath: lent.path) }), "the focused delivery did not run")
        try focusExpect(window.firstResponder === person && focus.paneID == nil && settled == [0.1],
                        "a focused delivery did not give the person's pane its focus back")
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct Refused: Error {}

/// `DeliveryFocus` on every exit: a refusal part-way, a text field being
/// edited, focus the person moved, a view that went away and a target that
/// already had focus.
func checkDeliveryFocusRestoresThePersonsFocusOnEveryExit() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let person = FocusableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let target = FocusableView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        let other = FocusableView(frame: NSRect(x: 400, y: 100, width: 200, height: 100))
        let field = NSTextField(frame: NSRect(x: 400, y: 0, width: 200, height: 24))
        for view in [person, target, other, field] { container.addSubview(view) }
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let focus = DeliveryFocus()
        var settled = 0
        func settle(_: TimeInterval) { settled += 1 }

        // A refusal part-way still restores, without the settle.
        try focusExpect(window.makeFirstResponder(person), "the person's view did not take focus")
        do {
            try focus.deliver(focusing: target, paneID: "target", beforeRestoring: 0.1, settle: settle) { throw Refused() }
            throw NSError(domain: "DeliveryFocus", code: 1, userInfo: [NSLocalizedDescriptionKey: "the refusal was swallowed"])
        } catch is Refused {}
        try focusExpect(window.firstResponder === person && focus.paneID == nil && settled == 0,
                        "a refused delivery left focus on the target or settled")

        // A text field being edited comes back with the person's selection.
        field.stringValue = "filter text"
        try focusExpect(window.makeFirstResponder(field), "the field did not take focus")
        field.currentEditor()?.selectedRange = NSRange(location: 3, length: 2)
        try focus.deliver(focusing: target, paneID: "target", beforeRestoring: 0, settle: settle) {}
        let editor = window.firstResponder as? NSTextView
        try focusExpect(editor?.isFieldEditor == true && editor?.delegate === field,
                        "the text field being edited did not get focus back: \(String(describing: window.firstResponder))")
        try focusExpect(editor?.selectedRange() == NSRange(location: 3, length: 2),
                        "the person's selection in the field was not kept: \(String(describing: editor?.selectedRange()))")

        // Focus the person moved during the delivery stays where they put it.
        try focusExpect(window.makeFirstResponder(person), "the person's view did not take focus")
        try focus.deliver(focusing: target, paneID: "target", beforeRestoring: 0, settle: settle) { window.makeFirstResponder(other) }
        try focusExpect(window.firstResponder === other, "restoring overrode focus the person moved")

        // The person's view went away: nothing is left focused rather than the target.
        try focusExpect(window.makeFirstResponder(person), "the person's view did not take focus")
        try focus.deliver(focusing: target, paneID: "target", beforeRestoring: 0, settle: settle) { person.removeFromSuperview() }
        try focusExpect(window.firstResponder === window, "focus stayed on the target after the person's view went away")

        // A target that already has focus is not lent it: nothing to restore.
        try focusExpect(window.makeFirstResponder(target), "the target did not take focus")
        try focus.deliver(focusing: target, paneID: "target", beforeRestoring: 0, settle: settle) {
            try focusExpect(focus.paneID == nil, "a target that already had focus was marked as lent it")
        }
        try focusExpect(window.firstResponder === target, "a target that already had focus lost it")
    }
}

@MainActor let deliveryFocusChecks: [(String, () throws -> Void)] = [
    ("only copilot submission moves focus", checkOnlyCopilotSubmissionMovesFocus),
    ("ghostty delivery without focus keeps the person's pane", checkGhosttyDeliveryWithoutFocusKeepsThePersonsPane),
    ("delivery focus restores the person's focus on every exit", checkDeliveryFocusRestoresThePersonsFocusOnEveryExit),
]
