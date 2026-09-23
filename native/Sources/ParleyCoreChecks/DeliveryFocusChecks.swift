import AppKit
import Foundation
import GhosttyTerminal
import ParleyCore

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
    }
}

@MainActor let deliveryFocusChecks: [(String, () throws -> Void)] = [
    ("only copilot submission moves focus", checkOnlyCopilotSubmissionMovesFocus),
    ("ghostty delivery without focus keeps the person's pane", checkGhosttyDeliveryWithoutFocusKeepsThePersonsPane),
]
