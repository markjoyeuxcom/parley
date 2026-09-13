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

/// What one scenario step reports when the driver runs it. A pending step
/// runs again on the next driver tick until it is done or its bound passes.
private enum WindowProbeStepOutcome {
    case done
    case pending(String)
    case failed(String)
}

/// Drives a real NSWindow hosting the actual root through the AppKit event
/// loop (`NSApplication.run`, the only pump that delivers window server
/// state faithfully): first show, minimise, deminiaturise, application hide
/// and unhide, orderOut, reopen and close. Drafts (the content's own
/// StateObject) survive temporary hiding, the clock stops while hidden and
/// keeps menu-tracking deferral, and close or orderOut destroy everything.
///
/// The check process is an unbundled executable, so its activation policy is
/// prohibited: no window of it can become key and no key notification ever
/// reaches the root. Content therefore mounts and is released only through
/// `NSWindow.didChangeOcclusionStateNotification`, which the window server
/// delivers asynchronously (tens to hundreds of milliseconds after the
/// ordering call, later on a loaded machine) and coalesces, so a window
/// ordered out before the server ever reported it on screen produces no
/// change and no notification at all. Every step that acts on a shown
/// window therefore first waits, bounded, for the window server to report
/// it on screen and for the content to mount, and every release waits for
/// the content to go; a fixed delay was the flake.
@MainActor
private final class WindowProbeScenario {
    let app = NSApplication.shared
    let ledger = WindowProbeLedger()
    let window: NSWindow
    /// A second window that is never shown: a global application hide or
    /// unhide must not mount anything in it.
    let dormantLedger = WindowProbeLedger()
    let dormantWindow: NSWindow
    var steps: [(String, () -> WindowProbeStepOutcome)] = []
    var index = 0
    var failure: String?
    var notes: [String] = []
    var recordedTicks = 0
    var recordedAppearances = 0
    var recordedSuspensions = 0
    /// Decided by the scenario once the minimise has or has not taken effect.
    var minimiseSupported = false
    var hideSupported = true
    /// Driver ticks the current step has reported pending.
    var pendingTicks = 0
    static let driverInterval: TimeInterval = 0.3
    /// Six seconds at the driver interval: far above the window server's
    /// usual latency, small enough that a real regression fails promptly.
    static let pendingTickLimit = 20
    /// Two seconds without the window minimising means the environment
    /// cannot minimise at all, not that the animation is still running.
    static let minimiseDecisionTicks = 7

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

    var live: Int { ledger.created - ledger.destroyed }

    /// The AppKit facts a failure needs to be diagnosed without a rerun.
    var facts: String {
        "window isVisible \(window.isVisible), miniaturized \(window.isMiniaturized), key \(window.isKeyWindow), occlusion visible \(window.occlusionState.contains(.visible)); app hidden \(app.isHidden), active \(app.isActive), activation policy \(app.activationPolicy().rawValue); ledger created \(ledger.created), destroyed \(ledger.destroyed), appeared \(ledger.appeared), ticks \(ledger.ticks), suspended \(ledger.suspended)"
    }

    /// Nil once the window is ordered in and the window server has reported
    /// it on screen, which is the only mount signal this process receives
    /// and the precondition for a later orderOut to change anything.
    var notYetOnScreen: String? {
        guard window.isVisible else { return "waiting for the window to be ordered in" }
        guard window.occlusionState.contains(.visible) else { return "waiting for the window server to report the window on screen" }
        return nil
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
        let (name, step) = steps[index]
        switch step() {
        case .done:
            index += 1
            pendingTicks = 0
        case .pending(let reason):
            pendingTicks += 1
            guard pendingTicks >= Self.pendingTickLimit else { return }
            let waited = String(format: "%.1f", Double(pendingTicks) * Self.driverInterval)
            failure = "\(name): still \(reason) after \(waited) s; \(facts)"
        case .failed(let problem):
            failure = "\(name): \(problem); \(facts)"
        }
    }
}

/// See `WindowProbeScenario`. Each acting step asserts the settled result of
/// the previous action, then acts; each settle step waits for that result.
func auxiliaryWindowLifetimeChecks() throws {
    try MainActor.assumeIsolated {
        let scenario = WindowProbeScenario()
        let ledger = scenario.ledger
        let window = scenario.window
        let app = scenario.app
        var createdBefore = 0
        scenario.steps = [
            ("show", {
                guard ledger.created == 0 else { return .failed("content was mounted before the window was shown") }
                window.makeKeyAndOrderFront(nil)
                return .done
            }),
            ("content mounts once the window is on screen", {
                if let reason = scenario.notYetOnScreen { return .pending(reason) }
                guard scenario.live == 1 else { return .pending("waiting for the content to mount") }
                guard ledger.ticks > 0 else { return .pending("waiting for the mounted content's clock to tick") }
                createdBefore = ledger.created
                scenario.recordedSuspensions = ledger.suspended
                return .done
            }),
            ("minimise", {
                window.miniaturize(nil)
                return .done
            }),
            // AppKit reports the minimise on a later turn, even in this
            // unbundled process; deciding from the flag right after the call
            // read "unavailable" while the window was on its way to the Dock.
            // Wait for it, and only treat minimise as unavailable when the
            // window is still up after a bound well past the animation.
            ("minimise takes effect", {
                if window.isMiniaturized {
                    scenario.minimiseSupported = true
                    return .done
                }
                guard scenario.pendingTicks >= WindowProbeScenario.minimiseDecisionTicks else { return .pending("waiting for the window to minimise") }
                scenario.minimiseSupported = false
                scenario.notes.append("minimise is not available in this environment; its assertions were skipped")
                return .done
            }),
            // The suspended state lands on a later run-loop turn than the
            // action; wait for the content to report it before recording the
            // tick count that must then stay put.
            ("content suspends after minimise", {
                if scenario.minimiseSupported, ledger.suspended == scenario.recordedSuspensions {
                    return .pending("waiting for the minimised content to suspend")
                }
                scenario.recordedTicks = ledger.ticks
                return .done
            }),
            ("deminiaturise", {
                if scenario.minimiseSupported {
                    guard ledger.destroyed == 0 else { return .failed("minimising destroyed the content and its drafts") }
                    guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock kept ticking while minimised (\(ledger.ticks) vs \(scenario.recordedTicks))") }
                    window.deminiaturize(nil)
                }
                return .done
            }),
            ("content resumes on screen after deminiaturise", {
                guard ledger.created == createdBefore else { return .failed("deminiaturising rebuilt the content instead of resuming it") }
                if let reason = scenario.notYetOnScreen { return .pending(reason) }
                guard scenario.live == 1 else { return .pending("waiting for the content to be live") }
                if scenario.minimiseSupported, ledger.ticks == scenario.recordedTicks { return .pending("waiting for the clock to resume") }
                scenario.recordedSuspensions = ledger.suspended
                return .done
            }),
            ("hide", {
                app.hide(nil)
                scenario.hideSupported = app.isHidden
                if !scenario.hideSupported {
                    scenario.notes.append("application hide is not available in this environment; its assertions were skipped")
                }
                return .done
            }),
            ("content suspends after hide", {
                if scenario.hideSupported, ledger.suspended == scenario.recordedSuspensions {
                    return .pending("waiting for the hidden content to suspend")
                }
                scenario.recordedTicks = ledger.ticks
                return .done
            }),
            ("unhide", {
                if scenario.hideSupported {
                    guard scenario.live == 1, ledger.created == createdBefore else { return .failed("hiding the application destroyed the content and its drafts") }
                    guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock kept ticking while the application was hidden") }
                    app.unhide(nil)
                    window.makeKeyAndOrderFront(nil)
                }
                return .done
            }),
            // Only a window the server has reported on screen changes state
            // when ordered out; act on it before that and nothing follows.
            ("content resumes on screen after unhide", {
                guard ledger.created == createdBefore else { return .failed("unhiding rebuilt the content instead of resuming it") }
                if let reason = scenario.notYetOnScreen { return .pending(reason) }
                guard scenario.live == 1 else { return .pending("waiting for the content to be live") }
                guard ledger.ticks > scenario.recordedTicks else { return .pending("waiting for the clock to resume") }
                return .done
            }),
            ("menu deferral", {
                let before = ledger.ticks
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.12))
                guard ledger.ticks == before else { return .failed("the clock fired while the run loop tracked a menu") }
                scenario.recordedTicks = ledger.ticks
                createdBefore = ledger.created
                window.orderOut(nil)
                return .done
            }),
            // SwiftUI commits the removal on a later run-loop turn, so the
            // clock may tick once or twice first; what must hold is that
            // nothing ticks once the content is gone.
            ("content is released after orderOut", {
                guard scenario.live == 0 else { return .pending("waiting for orderOut to release the content") }
                scenario.recordedTicks = ledger.ticks
                return .done
            }),
            ("reopen", {
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock kept ticking after the content was released by orderOut") }
                window.makeKeyAndOrderFront(nil)
                return .done
            }),
            ("fresh content mounts after reopen", {
                guard ledger.created <= createdBefore + 1 else { return .failed("reopening built the content more than once") }
                if let reason = scenario.notYetOnScreen { return .pending(reason) }
                guard scenario.live == 1, ledger.created == createdBefore + 1 else { return .pending("waiting for fresh content to mount") }
                guard ledger.ticks > scenario.recordedTicks else { return .pending("waiting for the reopened content's clock to tick") }
                return .done
            }),
            ("close", {
                scenario.recordedTicks = ledger.ticks
                window.close()
                return .done
            }),
            ("content is released after close", {
                guard scenario.live == 0 else { return .pending("waiting for close to release the content") }
                scenario.recordedTicks = ledger.ticks
                return .done
            }),
            ("closed", {
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock kept ticking after the content was released by close") }
                createdBefore = ledger.created
                scenario.recordedAppearances = ledger.appeared
                if scenario.hideSupported { app.hide(nil) }
                return .done
            }),
            // A closed window must stay closed through a global application
            // hide and unhide: no new content, no onAppear, no ticks.
            ("unhide after close", {
                guard scenario.live == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return .failed("hiding the application resurrected a closed window's content")
                }
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock ticked for a closed window while the application was hidden") }
                if scenario.hideSupported { app.unhide(nil) }
                return .done
            }),
            ("reopen after hide cycle", {
                guard scenario.live == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return .failed("unhiding the application resurrected a closed window's content")
                }
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock ticked for a closed window after the application was unhidden") }
                window.makeKeyAndOrderFront(nil)
                return .done
            }),
            ("fresh content mounts after the hide cycle", {
                guard ledger.created <= createdBefore + 1, ledger.appeared <= scenario.recordedAppearances + 1 else {
                    return .failed("reopening after the hide cycle built or showed the content more than once")
                }
                if let reason = scenario.notYetOnScreen { return .pending(reason) }
                guard scenario.live == 1, ledger.created == createdBefore + 1, ledger.appeared == scenario.recordedAppearances + 1 else {
                    return .pending("waiting for fresh content to mount")
                }
                guard ledger.ticks > scenario.recordedTicks else { return .pending("waiting for the reopened content's clock to tick") }
                createdBefore = ledger.created
                scenario.recordedAppearances = ledger.appeared
                return .done
            }),
            ("orderOut before hide", {
                window.orderOut(nil)
                return .done
            }),
            ("content is released after the second orderOut", {
                guard scenario.live == 0 else { return .pending("waiting for the second orderOut to release the content") }
                scenario.recordedTicks = ledger.ticks
                return .done
            }),
            ("hide after orderOut", {
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock kept ticking after the content was released by the second orderOut") }
                if scenario.hideSupported { app.hide(nil) }
                return .done
            }),
            ("unhide after orderOut", {
                guard scenario.live == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return .failed("hiding the application resurrected an ordered-out window's content")
                }
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock ticked for an ordered-out window while the application was hidden") }
                if scenario.hideSupported { app.unhide(nil) }
                return .done
            }),
            ("released windows stay released", {
                guard scenario.live == 0, ledger.created == createdBefore, ledger.appeared == scenario.recordedAppearances else {
                    return .failed("unhiding the application resurrected an ordered-out window's content")
                }
                guard ledger.ticks == scenario.recordedTicks else { return .failed("the clock ticked for an ordered-out window after the application was unhidden") }
                let dormant = scenario.dormantLedger
                guard dormant.created == 0, dormant.appeared == 0, dormant.ticks == 0 else {
                    return .failed("a never-shown window mounted content during application hide/unhide (created \(dormant.created), appeared \(dormant.appeared), ticks \(dormant.ticks))")
                }
                return .done
            }),
        ]
        let driver = Timer(timeInterval: WindowProbeScenario.driverInterval, repeats: true) { _ in
            MainActor.assumeIsolated { scenario.advance() }
        }
        RunLoop.main.add(driver, forMode: .common)
        // Every settle is bounded by `pendingTickLimit`; this only catches a
        // run loop that stopped delivering the driver at all.
        let watchdog = Timer(timeInterval: 60, repeats: false) { _ in
            MainActor.assumeIsolated {
                let step = scenario.index < scenario.steps.count ? scenario.steps[scenario.index].0 : "the end"
                scenario.failure = scenario.failure ?? "the window lifetime scenario timed out at \(step); \(scenario.facts)"
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
