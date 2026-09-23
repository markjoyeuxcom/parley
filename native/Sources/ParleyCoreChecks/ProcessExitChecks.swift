import AppKit
import Foundation
import GhosttyTerminal
import ParleyCore
import ParleyUI

private func exitExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ProcessExit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026, a090bc40: a pane's exit was recorded only
/// through Ghostty's close callback, and with wait-after-command forced on
/// every surface Ghostty never closes by itself. After `/exit`, or when a CLI
/// is missing from PATH, the pane stayed RUNNING with relay enabled. Ghostty
/// itself records the child's exit; this reads that record on real surfaces.
func checkGhosttyReportsItsChildsExit() throws {
    try GhosttyLaunchPreflight.check()
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let controller = TerminalController { $0.withBackgroundOpacity(1) }
        @MainActor final class Attach: TerminalSurfaceLifecycleDelegate {
            var surface: TerminalSurface?
            func terminalDidAttachSurface(_ surface: TerminalSurface) { self.surface = surface }
            func terminalDidDetachSurface() { surface = nil }
        }
        @MainActor func terminal(_ arguments: [String], x: CGFloat, delegate: Attach) -> AppTerminalView {
            let view = AppTerminalView(frame: NSRect(x: x, y: 0, width: 300, height: 200))
            view.delegate = delegate
            view.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: NSTemporaryDirectory(),
                                                        command: GhosttyLaunchCommand.render(arguments), waitAfterCommand: true)
            return view
        }
        let exiting = Attach(), running = Attach()
        let exitingView = terminal(["/bin/sh", "-c", "exit 3"], x: 0, delegate: exiting)
        let runningView = terminal(["/bin/sleep", "30"], x: 300, delegate: running)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        container.addSubview(exitingView)
        container.addSubview(runningView)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        exitingView.controller = controller
        runningView.controller = controller
        window.orderFront(nil)
        defer {
            exitingView.controller = nil
            runningView.controller = nil
            window.close()
        }
        @MainActor func pump(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        try exitExpect(pump(until: { exiting.surface != nil && running.surface != nil }), "the surfaces did not attach")
        let exitingSurface = try exiting.surface.unwrapOrThrow("no exiting surface")
        let runningSurface = try running.surface.unwrapOrThrow("no running surface")
        try exitExpect(GhosttyProcessExit.hasExited(runningSurface) == false,
                       "Ghostty's exit record could not be read, or a running child read as exited: \(String(describing: GhosttyProcessExit.hasExited(runningSurface)))")
        try exitExpect(pump(until: { GhosttyProcessExit.hasExited(exitingSurface) == true }),
                       "Ghostty did not report the exited child: \(String(describing: GhosttyProcessExit.hasExited(exitingSurface)))")
        try exitExpect(GhosttyProcessExit.hasExited(runningSurface) == false, "the running child read as exited")
    }
}

private extension Optional {
    func unwrapOrThrow(_ message: String) throws -> Wrapped {
        guard let self else { throw NSError(domain: "ProcessExit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return self
    }
}

/// Each launch generation's exit is reported once; unknown is never an exit,
/// and a restart is a new generation with its own report.
func checkProcessExitTrackerReportsEachGenerationOnce() throws {
    var tracker = ProcessExitTracker()
    try exitExpect(tracker.exits([.init(paneID: "a", generation: 1, exited: nil), .init(paneID: "b", generation: 1, exited: false)]).isEmpty,
                   "an unknown or running process was reported as exited")
    let first = tracker.exits([.init(paneID: "a", generation: 1, exited: true), .init(paneID: "b", generation: 1, exited: false)])
    try exitExpect(first == [.init(paneID: "a", generation: 1)], "the exit was not reported: \(first)")
    try exitExpect(tracker.exits([.init(paneID: "a", generation: 1, exited: true)]).isEmpty, "the same exit was reported twice")
    let restarted = tracker.exits([.init(paneID: "a", generation: 2, exited: true)])
    try exitExpect(restarted == [.init(paneID: "a", generation: 2)], "a restarted generation's exit was not reported: \(restarted)")
    // A pane that went away is forgotten, so the record stays bounded.
    _ = tracker.exits([])
    try exitExpect(tracker.exits([.init(paneID: "a", generation: 2, exited: true)]) == [.init(paneID: "a", generation: 2)],
                   "a pane absent from a pass was not forgotten")
}

@MainActor let processExitChecks: [(String, () throws -> Void)] = [
    ("ghostty reports its child's exit", checkGhosttyReportsItsChildsExit),
    ("process exit tracker reports each generation once", checkProcessExitTrackerReportsEachGenerationOnce),
]
