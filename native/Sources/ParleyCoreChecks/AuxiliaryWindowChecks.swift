import AppKit
import Foundation
import ParleyCore
import ParleyUI
import SwiftUI

private func windowExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "AuxiliaryWindow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func auxiliaryWindowPresenceChecks() throws {
    // SwiftUI hides a closed Window scene and keeps its view tree alive; the
    // root mounts real content only while the window itself is on screen.
    typealias Presence = AuxiliaryWindowPresence
    func next(_ previous: Presence.State, visible: Bool = false, minimised: Bool = false, appHidden: Bool = false, closing: Bool = false) -> Presence.State {
        Presence.next(after: previous, isVisible: visible, isMiniaturized: minimised, applicationHidden: appHidden, closing: closing)
    }
    for previous in [Presence.State.released, .suspended, .active] {
        try windowExpect(next(previous, visible: true) == .active, "a visible window was not active (from \(previous))")
        try windowExpect(next(previous) == .released, "a closed or ordered-out window kept its content (from \(previous))")
        try windowExpect(next(previous, visible: true, closing: true) == .released, "a closing window kept its content (from \(previous))")
        try windowExpect(next(previous, minimised: true, closing: true) == .released, "closing a minimised window kept its content (from \(previous))")
        try windowExpect(next(previous, appHidden: true, closing: true) == .released, "closing while the application was hidden kept content (from \(previous))")
    }
    // Only a window that was on screen (or already suspended) has drafts to keep.
    for previous in [Presence.State.active, .suspended] {
        try windowExpect(next(previous, minimised: true) == .suspended, "a minimised window lost its drafts (from \(previous))")
        try windowExpect(next(previous, appHidden: true) == .suspended, "an application-hidden window lost its drafts (from \(previous))")
        try windowExpect(next(previous, minimised: true, appHidden: true) == .suspended, "a minimised window hidden with the application lost its drafts (from \(previous))")
    }
    // A global application hide is reported to closed windows too; it must
    // never mount one. Likewise a minimised flag on a window that never showed.
    try windowExpect(next(.released, appHidden: true) == .released, "hiding the application mounted a closed window")
    try windowExpect(next(.released, minimised: true) == .released, "a never-shown window was suspended instead of staying released")
    try windowExpect(next(.released, minimised: true, appHidden: true) == .released, "hiding the application mounted a closed window flagged minimised")
    try windowExpect(Presence.shouldMount(.active) && Presence.shouldMount(.suspended) && !Presence.shouldMount(.released), "mount rule drifted from the state table")
}

/// Runs the current loop in `mode` until the deadline. `run(mode:before:)`
/// returns after one source fires, and earlier checks leave sources behind,
/// so a single call could return before the timer's first tick.
private func spinRunLoop(mode: RunLoop.Mode, seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: mode, before: min(deadline, Date().addingTimeInterval(0.02)))
    }
}

func windowRefreshClockChecks() throws {
    // The clock fires only in its run-loop mode (menu tracking is deferred as
    // before), stops on demand, and cannot outlive its owner.
    final class Counter { var ticks = 0 }
    let counter = Counter()
    var clock: WindowRefreshClock? = WindowRefreshClock(interval: 0.05, mode: MenuTrackingRefreshPolicy.runLoopMode) { counter.ticks += 1 }
    clock?.start()
    spinRunLoop(mode: MenuTrackingRefreshPolicy.runLoopMode, seconds: 0.3)
    let afterRun = counter.ticks
    try windowExpect(afterRun >= 2, "the clock did not fire in its own run-loop mode: \(afterRun)")
    spinRunLoop(mode: .eventTracking, seconds: 0.2)
    try windowExpect(counter.ticks == afterRun, "the clock fired while the run loop was tracking a menu")
    clock?.stop()
    spinRunLoop(mode: MenuTrackingRefreshPolicy.runLoopMode, seconds: 0.15)
    try windowExpect(counter.ticks == afterRun, "a stopped clock kept firing")
    clock?.start()
    spinRunLoop(mode: MenuTrackingRefreshPolicy.runLoopMode, seconds: 0.15)
    let afterRestart = counter.ticks
    try windowExpect(afterRestart > afterRun, "a restarted clock did not fire")
    weak let released = clock
    clock = nil
    try windowExpect(released == nil, "the clock was retained after its owner let go")
    spinRunLoop(mode: MenuTrackingRefreshPolicy.runLoopMode, seconds: 0.15)
    try windowExpect(counter.ticks == afterRestart, "a released clock kept firing from the run loop")
}

// MARK: - Real AppKit lifetime of the window root

@MainActor
private final class WindowProbeLedger {
    var created = 0
    var destroyed = 0
    var appeared = 0
    var ticks = 0
    /// Times the content saw `auxiliaryWindowActive` turn false. The state
    /// lands on a later run-loop turn than the AppKit action that causes it,
    /// so a step must wait for this before asserting the clock is quiet.
    var suspended = 0
}

@MainActor
private final class WindowProbeInstance: ObservableObject {
    let ledger: WindowProbeLedger
    init(ledger: WindowProbeLedger) {
        self.ledger = ledger
        ledger.created += 1
    }
    deinit {
        let ledger = self.ledger
        MainActor.assumeIsolated { ledger.destroyed += 1 }
    }
}

/// Stands in for Status Center or Task Manager content: view state that must
/// survive temporary hiding, plus a refresh clock that must not.
private struct WindowProbeContent: View {
    let ledger: WindowProbeLedger
    @StateObject private var instance: WindowProbeInstance
    @StateObject private var clock = AuxiliaryWindowClock(interval: 0.03)
    @Environment(\.auxiliaryWindowActive) private var active

    init(ledger: WindowProbeLedger) {
        self.ledger = ledger
        _instance = StateObject(wrappedValue: WindowProbeInstance(ledger: ledger))
    }

    var body: some View {
        Text("probe")
            .frame(width: 300, height: 200)
            .onAppear {
                ledger.appeared += 1
                if active { clock.start { ledger.ticks += 1 } }
            }
            .onChange(of: active) { _, isActive in
                if isActive { clock.start { ledger.ticks += 1 } } else { clock.stop(); ledger.suspended += 1 }
            }
            .onDisappear { clock.stop() }
    }
}

private struct WindowProbeFailure: Error, CustomStringConvertible {
    let description: String
}

/// Drives a real NSWindow hosting the actual root through the AppKit event
/// loop (`NSApplication.run`, the only pump that delivers window server
/// state faithfully): first show, minimise, deminiaturise, application hide
/// and unhide, orderOut, reopen and close. Drafts (the content's own
/// StateObject) survive temporary hiding, the clock stops while hidden and
/// keeps menu-tracking deferral, and close or orderOut destroy everything.
@MainActor
private final class WindowProbeScenario {
    let app = NSApplication.shared
    let ledger = WindowProbeLedger()
    let window: NSWindow
    /// A second window that is never shown: a global application hide or
    /// unhide must not mount anything in it.
    let dormantLedger = WindowProbeLedger()
    let dormantWindow: NSWindow
    var steps: [(String, () -> String?)] = []
    var index = 0
    var failure: String?
    var notes: [String] = []
    var recordedTicks = 0
    var recordedAppearances = 0
    var recordedSuspensions = 0
    var minimiseSupported = true
    var hideSupported = true
    var settleRetries = 0

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let ledger = self.ledger
        window.contentView = NSHostingView(rootView: AuxiliaryWindowRoot(minimumSize: CGSize(width: 300, height: 200)) { WindowProbeContent(ledger: ledger) })
        dormantWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        dormantWindow.isReleasedWhenClosed = false
        let dormantLedger = self.dormantLedger
        dormantWindow.contentView = NSHostingView(rootView: AuxiliaryWindowRoot(minimumSize: CGSize(width: 300, height: 200)) { WindowProbeContent(ledger: dormantLedger) })
    }

    func stopLoop() {
        app.stop(nil)
        app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
    }

    func advance() {
        guard failure == nil, index < steps.count else {
            stopLoop()
            return
        }
        let step = steps[index]
        index += 1
        if let problem = step.1() { failure = "\(step.0): \(problem)" }
    }
}

/// Drives a real NSWindow hosting the actual root through the AppKit event
/// loop (`NSApplication.run`, the only pump that delivers window server
/// state faithfully): first show, minimise, deminiaturise, application hide
/// and unhide, orderOut, reopen and close. Drafts (the content's own
/// StateObject) survive temporary hiding, the clock stops while hidden and
/// keeps menu-tracking deferral, and close or orderOut destroy everything.
func auxiliaryWindowLifetimeChecks() throws {
    try MainActor.assumeIsolated {
        let scenario = WindowProbeScenario()
        let ledger = scenario.ledger
        let window = scenario.window
        let app = scenario.app
        // Each step asserts the settled result of the previous action, then acts.
        var createdBefore = 0
        @MainActor func live() -> Int { ledger.created - ledger.destroyed }
        scenario.steps = [
            ("show", {
                guard ledger.created == 0 else { return "content was mounted before the window was shown" }
                window.makeKeyAndOrderFront(nil); return nil
            }),
            ("minimise", {
                guard live() == 1, ledger.ticks > 0 else { return "showing the window did not mount content and start its clock (created \(ledger.created), destroyed \(ledger.destroyed), ticks \(ledger.ticks))" }
                createdBefore = ledger.created
                scenario.recordedSuspensions = ledger.suspended
                window.miniaturize(nil)
                scenario.minimiseSupported = window.isMiniaturized
                if !scenario.minimiseSupported {
                    scenario.notes.append("minimise is not available in this environment; its assertions were skipped")
                    window.makeKeyAndOrderFront(nil)
                }
                return nil
            }),
            // The suspended state lands on a later run-loop turn than the
            // action; wait for the content to report it before asserting
            // that the clock is quiet, so a tick in between is not a failure.
            ("settle after minimise", {
                if scenario.minimiseSupported, ledger.suspended == scenario.recordedSuspensions, scenario.settleRetries < 10 {
                    scenario.settleRetries += 1
                    scenario.index -= 1
                    return nil
                }
                scenario.settleRetries = 0
                scenario.recordedTicks = ledger.ticks
                return nil
            }),
            ("deminiaturise", {
                if scenario.minimiseSupported {
                    guard ledger.destroyed == 0 else { return "minimising destroyed the content and its drafts" }
                    guard ledger.suspended > scenario.recordedSuspensions else { return "minimising did not suspend the content" }
                    guard ledger.ticks == scenario.recordedTicks else { return "the clock kept ticking while minimised (\(ledger.ticks) vs \(scenario.recordedTicks))" }
                    window.deminiaturize(nil)
                }
                return nil
            }),
            ("hide", {
                if scenario.minimiseSupported {
                    guard ledger.created == createdBefore, live() == 1 else { return "deminiaturising rebuilt the content instead of resuming it (created \(ledger.created), destroyed \(ledger.destroyed))" }
                    guard ledger.ticks > scenario.recordedTicks else { return "the clock did not resume after deminiaturising" }
                } else {
                    guard live() == 1 else { return "restoring the window after the skipped minimise left no live content (created \(ledger.created), destroyed \(ledger.destroyed))" }
                }
                createdBefore = ledger.created
                scenario.recordedSuspensions = ledger.suspended
                app.hide(nil)
                scenario.hideSupported = app.isHidden
                if !scenario.hideSupported {
                    scenario.notes.append("application hide is not available in this environment; its assertions were skipped")
                }
                return nil
            }),
            ("settle after hide", {
                if scenario.hideSupported, ledger.suspended == scenario.recordedSuspensions, scenario.settleRetries < 10 {
                    scenario.settleRetries += 1
                    scenario.index -= 1
                    return nil
                }
                scenario.settleRetries = 0
                scenario.recordedTicks = ledger.ticks
                return nil
            }),
            ("unhide", {
                if scenario.hideSupported {
                    guard ledger.suspended > scenario.recordedSuspensions else { return "hiding the application did not suspend the content" }
                    guard live() == 1, ledger.created == createdBefore else { return "hiding the application destroyed the content and its drafts (created \(ledger.created), destroyed \(ledger.destroyed))" }
                    guard ledger.ticks == scenario.recordedTicks else { return "the clock kept ticking while the application was hidden" }
                    app.unhide(nil)
                    window.makeKeyAndOrderFront(nil)
                }
                return nil
            }),
            ("menu deferral", {
                guard live() == 1, ledger.created == createdBefore else { return "unhiding rebuilt the content instead of resuming it (created \(ledger.created), destroyed \(ledger.destroyed))" }
                guard ledger.ticks > scenario.recordedTicks else { return "the clock did not resume after unhiding (ticks \(ledger.ticks) vs \(scenario.recordedTicks))" }
                let before = ledger.ticks
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.12))
                guard ledger.ticks == before else { return "the clock fired while the run loop tracked a menu" }
                scenario.recordedTicks = ledger.ticks
                createdBefore = ledger.created
                window.orderOut(nil)
                return nil
            }),
            // SwiftUI commits the removal on its next update, so the clock may
            // fire once or twice before the content is destroyed; what must
            // hold is that nothing ticks once it is gone.
            ("settle after orderOut", {
                // The commit that destroys the content lands on a later run-loop
                // turn; wait for it (bounded) before measuring quiescence.
                if live() > 0, scenario.settleRetries < 10 {
                    scenario.settleRetries += 1
                    scenario.index -= 1
                    return nil
                }
                scenario.settleRetries = 0
                scenario.recordedTicks = ledger.ticks
                return nil
            }),
            ("reopen", {
                guard live() == 0 else {
                    return "ordering the window out did not release the content (created \(ledger.created), destroyed \(ledger.destroyed); isVisible \(window.isVisible), miniaturized \(window.isMiniaturized), appHidden \(app.isHidden), occlusion visible \(window.occlusionState.contains(.visible)), onScreen \(window.isOnActiveSpace))"
                }
                guard ledger.ticks == scenario.recordedTicks else { return "the clock kept ticking after the content was released by orderOut" }
                window.makeKeyAndOrderFront(nil)
                return nil
            }),
            ("close", {
                guard live() == 1, ledger.created == createdBefore + 1 else { return "reopening did not build fresh content (created \(ledger.created), destroyed \(ledger.destroyed))" }
                guard ledger.ticks > scenario.recordedTicks else { return "the clock did not start for the reopened content" }
                scenario.recordedTicks = ledger.ticks
                window.close()
                return nil
            }),
            ("settle after close", {
                if live() > 0, scenario.settleRetries < 10 {
                    scenario.settleRetries += 1
                    scenario.index -= 1
                    return nil
                }
                scenario.settleRetries = 0
                scenario.recordedTicks = ledger.ticks
                return nil
            }),
            ("closed", {
                guard live() == 0 else { return "closing did not release the content (created \(ledger.created), destroyed \(ledger.destroyed); isVisible \(window.isVisible), appHidden \(app.isHidden))" }
                guard ledger.ticks == scenario.recordedTicks else { return "the clock kept ticking after the content was released by close" }
                createdBefore = ledger.created
                scenario.recordedAppearances = ledger.appeared
                if scenario.hideSupported { app.hide(nil) }
                return nil
            }),
            // A closed window must stay closed through a global application
            // hide and unhide: no new content, no onAppear, no ticks.
            ("unhide after close", {
                guard live() == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return "hiding the application resurrected a closed window's content (created \(ledger.created), destroyed \(ledger.destroyed), appeared \(ledger.appeared) vs \(scenario.recordedAppearances))"
                }
                guard ledger.ticks == scenario.recordedTicks else { return "the clock ticked for a closed window while the application was hidden" }
                if scenario.hideSupported { app.unhide(nil) }
                return nil
            }),
            ("reopen after hide cycle", {
                guard live() == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return "unhiding the application resurrected a closed window's content (created \(ledger.created), destroyed \(ledger.destroyed), appeared \(ledger.appeared) vs \(scenario.recordedAppearances))"
                }
                guard ledger.ticks == scenario.recordedTicks else { return "the clock ticked for a closed window after the application was unhidden" }
                window.makeKeyAndOrderFront(nil)
                return nil
            }),
            ("orderOut before hide", {
                guard live() == 1, ledger.created == createdBefore + 1, ledger.appeared == scenario.recordedAppearances + 1 else {
                    return "reopening after the hide cycle did not build fresh content exactly once (created \(ledger.created), destroyed \(ledger.destroyed), appeared \(ledger.appeared))"
                }
                createdBefore = ledger.created
                scenario.recordedAppearances = ledger.appeared
                window.orderOut(nil)
                return nil
            }),
            ("settle after second orderOut", {
                if live() > 0, scenario.settleRetries < 10 {
                    scenario.settleRetries += 1
                    scenario.index -= 1
                    return nil
                }
                scenario.settleRetries = 0
                scenario.recordedTicks = ledger.ticks
                return nil
            }),
            ("hide after orderOut", {
                guard live() == 0 else { return "the second orderOut did not release the content (created \(ledger.created), destroyed \(ledger.destroyed))" }
                if scenario.hideSupported { app.hide(nil) }
                return nil
            }),
            ("unhide after orderOut", {
                guard live() == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return "hiding the application resurrected an ordered-out window's content (created \(ledger.created), destroyed \(ledger.destroyed), appeared \(ledger.appeared) vs \(scenario.recordedAppearances))"
                }
                guard ledger.ticks == scenario.recordedTicks else { return "the clock ticked for an ordered-out window while the application was hidden" }
                if scenario.hideSupported { app.unhide(nil) }
                return nil
            }),
            ("released windows stay released", {
                guard live() == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return "unhiding the application resurrected an ordered-out window's content (created \(ledger.created), destroyed \(ledger.destroyed), appeared \(ledger.appeared) vs \(scenario.recordedAppearances))"
                }
                guard ledger.ticks == scenario.recordedTicks else { return "the clock ticked for an ordered-out window after the application was unhidden" }
                let dormant = scenario.dormantLedger
                guard dormant.created == 0, dormant.appeared == 0, dormant.ticks == 0 else {
                    return "a never-shown window mounted content during application hide/unhide (created \(dormant.created), appeared \(dormant.appeared), ticks \(dormant.ticks))"
                }
                return nil
            }),
        ]
        let driver = Timer(timeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { scenario.advance() }
        }
        RunLoop.main.add(driver, forMode: .common)
        let watchdog = Timer(timeInterval: 25, repeats: false) { _ in
            MainActor.assumeIsolated {
                scenario.failure = scenario.failure ?? "the window lifetime scenario timed out at step \(scenario.index)"
                scenario.stopLoop()
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        app.run()
        driver.invalidate()
        watchdog.invalidate()
        window.contentView = nil
        scenario.dormantWindow.contentView = nil
        for note in scenario.notes { print("  note: \(note)") }
        if let failure = scenario.failure { throw WindowProbeFailure(description: failure) }
        try windowExpect(ledger.created == ledger.destroyed && ledger.created == 3 && ledger.appeared == 3, "final ledger mismatch: \(ledger.created) created, \(ledger.destroyed) destroyed, \(ledger.appeared) appeared (expected three mounts: show, reopen, reopen after hide cycle)")
        try windowExpect(scenario.dormantLedger.created == 0, "the never-shown window mounted content \(scenario.dormantLedger.created) times")
    }
}

@MainActor
let auxiliaryWindowChecks: [(String, () throws -> Void)] = [
    ("auxiliary window content survives hiding and minimising but not close or orderOut, and a released window stays released through application hide/unhide", auxiliaryWindowLifetimeChecks),
    ("auxiliary window content mounts only while its window is on screen", auxiliaryWindowPresenceChecks),
    ("window refresh clock keeps menu-tracking deferral, stops on demand and dies with its owner", windowRefreshClockChecks),
]
