import AppKit
import ParleyCore
import SwiftUI

/// True while the hosting auxiliary window is on screen. Mounted content
/// reads it to run refresh clocks and live labels only while visible.
public struct AuxiliaryWindowActiveKey: EnvironmentKey {
    public static let defaultValue = true
}

public extension EnvironmentValues {
    var auxiliaryWindowActive: Bool {
        get { self[AuxiliaryWindowActiveKey.self] }
        set { self[AuxiliaryWindowActiveKey.self] = newValue }
    }
}

/// Root of every auxiliary window scene (Status Center, Help, About,
/// Settings). It observes no model state itself. The real content,
/// with its model observation, timers and view state, is created when the
/// window comes on screen and destroyed when it is closed or ordered out, so
/// a closed window leaves no work behind. Minimising or hiding the
/// application suspends instead: content and unapplied drafts stay, and the
/// `auxiliaryWindowActive` environment turns false so clocks and live labels
/// stop. A placeholder keeps the window's minimum size stable.
public struct AuxiliaryWindowRoot<Content: View>: View {
    private let minimumSize: CGSize?
    private let content: () -> Content
    @State private var state: AuxiliaryWindowPresence.State = .released

    public init(minimumSize: CGSize?, @ViewBuilder content: @escaping () -> Content) {
        self.minimumSize = minimumSize
        self.content = content
    }

    public var body: some View {
        ZStack {
            if AuxiliaryWindowPresence.shouldMount(state) {
                content()
                    .environment(\.auxiliaryWindowActive, state == .active)
            } else {
                Color.clear
                    .frame(minWidth: minimumSize?.width ?? 1, minHeight: minimumSize?.height ?? 1)
            }
        }
        .background(WindowVisibilityReader { observed in
            if observed != state { state = observed }
        })
    }
}

/// Reports the hosting window's own on-screen state through AppKit window
/// notifications. `onDisappear` never fires for a hidden scene window and
/// key-window or application-active state is not visibility, so neither is
/// used. The observer keeps its window's last state so that an application
/// hide, which is delivered to every window, suspends only a window that was
/// on screen and leaves a closed one released.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (AuxiliaryWindowPresence.State) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class WindowObservingView: NSView {
    var onChange: ((AuxiliaryWindowPresence.State) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    /// This window's own history: the last state it reported.
    private var lastState: AuxiliaryWindowPresence.State = .released

    deinit {
        // NSView instances are released on the main thread; the block
        // observers must be removed explicitly or they would leak.
        MainActor.assumeIsolated { removeObservers() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observedWindow !== window else { return }
        removeObservers()
        observedWindow = window
        guard let window else {
            publish(.released)
            return
        }
        let center = NotificationCenter.default
        let windowNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExposeNotification,
        ]
        for name in windowNames {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate(closing: false) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate(closing: true) }
        })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate(closing: false) }
            })
        }
        reevaluate(closing: false)
    }

    private func reevaluate(closing: Bool) {
        guard let window = observedWindow else {
            publish(.released)
            return
        }
        publish(AuxiliaryWindowPresence.next(
            after: lastState,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            applicationHidden: NSApp.isHidden,
            closing: closing
        ))
    }

    private func publish(_ state: AuxiliaryWindowPresence.State) {
        // The history is recorded synchronously so the next notification,
        // even one on the same run-loop turn, sees this window's real state.
        lastState = state
        // Never mutate SwiftUI state from inside a layout or notification
        // delivery that may itself be part of a view update.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onChange?(state) } }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

/// A `WindowRefreshClock` owned by mounted content through `@StateObject`,
/// so it starts with the content and is invalidated when the content is
/// destroyed.
@MainActor
public final class AuxiliaryWindowClock: ObservableObject {
    private let interval: TimeInterval
    private let mode: RunLoop.Mode
    private var clock: WindowRefreshClock?

    public init(interval: TimeInterval, mode: RunLoop.Mode = MenuTrackingRefreshPolicy.runLoopMode) {
        self.interval = interval
        self.mode = mode
    }

    public var isRunning: Bool { clock?.isRunning ?? false }

    public func start(_ handler: @escaping () -> Void) {
        stop()
        let clock = WindowRefreshClock(interval: interval, mode: mode, handler: handler)
        clock.start()
        self.clock = clock
    }

    public func stop() {
        clock?.stop()
        clock = nil
    }
}
