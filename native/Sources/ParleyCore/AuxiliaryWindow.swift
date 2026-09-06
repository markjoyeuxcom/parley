import Foundation

/// SwiftUI hides a closed `Window` or `Settings` scene on macOS and keeps its
/// view tree alive, so an ungated view keeps observing the model, running its
/// timers and laying out. Auxiliary windows therefore mount their real
/// content only while the window itself is on screen: closed, ordered out,
/// hidden with the application or minimised all mean "nothing to run".
///
/// The state is a per-window transition, not a function of the current
/// AppKit flags alone: hiding or minimising suspends only a window that was
/// on screen, because a global application hide is also reported to every
/// closed window, and a closed window must stay closed until it is really
/// opened again.
public enum AuxiliaryWindowPresence {
    public enum State: Equatable, Sendable {
        /// On screen: content mounted, clocks and live labels running.
        case active
        /// Minimised or hidden with the application: content and its drafts
        /// are kept, clocks and live labels are stopped.
        case suspended
        /// Closed or ordered out: content destroyed, nothing left running.
        case released
    }

    /// The next state for one window given its previous state and the AppKit
    /// facts at notification time. `closing` is `willClose`; `isVisible` is
    /// `NSWindow.isVisible`, which is false while minimised or application
    /// hidden, so those flags are consulted first and suspend only a window
    /// that has content to keep.
    public static func next(after previous: State, isVisible: Bool, isMiniaturized: Bool, applicationHidden: Bool, closing: Bool) -> State {
        if closing { return .released }
        if isMiniaturized || applicationHidden {
            return previous == .released ? .released : .suspended
        }
        return isVisible ? .active : .released
    }

    /// Whether content exists at all for this state.
    public static func shouldMount(_ state: State) -> Bool { state != .released }
}

/// A refresh timer owned by mounted window content. It runs in one run-loop
/// mode (the menu-tracking policy mode, so an open AppKit menu is never
/// rebuilt while tracking the pointer), stops on demand, and invalidates
/// itself when its owner is released, so it cannot outlive the content that
/// created it.
public final class WindowRefreshClock {
    private let interval: TimeInterval
    private let mode: RunLoop.Mode
    private let handler: () -> Void
    private var timer: Timer?

    public init(interval: TimeInterval, mode: RunLoop.Mode, handler: @escaping () -> Void) {
        self.interval = max(0.01, interval)
        self.mode = mode
        self.handler = handler
    }

    deinit { timer?.invalidate() }

    public var isRunning: Bool { timer != nil }

    /// Schedules on the calling thread's run loop; content calls this from the
    /// main actor, so the timer joins the main loop in the policy mode.
    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.handler() }
        RunLoop.current.add(timer, forMode: mode)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}
