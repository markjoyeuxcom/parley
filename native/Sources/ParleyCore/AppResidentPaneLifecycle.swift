import Foundation

/// Ghostty surfaces are owned by the Parley application process. A window
/// close only hides the retained surface tree; ending the application process
/// is the lifetime boundary for every pane process.
public enum AppResidentPaneLifecycle {
    public enum Action: Sendable {
        case closeWindow
        case quitApplication
        case stopEverything
    }

    public enum Effect: Sendable {
        case keepRunning
        case terminate
    }

    public static func effect(of action: Action) -> Effect {
        switch action {
        case .closeWindow:
            .keepRunning
        case .quitApplication, .stopEverything:
            .terminate
        }
    }
}

/// Vendor-specific settling intervals around the public Ghostty paste/key
/// APIs. Copilot ignores Enter immediately after a terminal focus transition;
/// other vendors require no artificial delay.
public struct PaneSubmissionTiming: Equatable, Sendable {
    public let afterFocus: TimeInterval
    public let afterPaste: TimeInterval
    public let beforeRestoringFocus: TimeInterval

    public init(
        afterFocus: TimeInterval,
        afterPaste: TimeInterval,
        beforeRestoringFocus: TimeInterval
    ) {
        self.afterFocus = afterFocus
        self.afterPaste = afterPaste
        self.beforeRestoringFocus = beforeRestoringFocus
    }

    /// Whether delivery must make the target pane first responder. Ghostty
    /// accepts paste and Enter on a surface without focus, so only Copilot's
    /// submission, which needs its pane focused, moves the person's focus.
    public var focusesTarget: Bool { afterFocus > 0 }

    public static func forKind(_ kind: PaneKind, submit: Bool) -> PaneSubmissionTiming {
        guard kind == .copilot, submit else {
            return PaneSubmissionTiming(
                afterFocus: 0,
                afterPaste: 0,
                beforeRestoringFocus: 0
            )
        }
        return PaneSubmissionTiming(
            afterFocus: 0.1,
            afterPaste: 0.25,
            beforeRestoringFocus: 0.1
        )
    }
}

/// Ghostty's exec surface accepts a command string. Parley still builds every
/// vendor launch as an argv array and encodes each item as one literal POSIX
/// shell word at the final library boundary. No prompt or agent-authored text
/// is ever included in this command.
public enum GhosttyLaunchCommand {
    public static func render(_ arguments: [String]) -> String {
        arguments.map(literalWord).joined(separator: " ")
    }

    private static func literalWord(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// The steps of one input delivery into a pane, in order, and how a failure
/// at each is reported. Everything before the paste refuses with an error
/// `ParleyWorkbenchError.refusedBeforeInput` recognises; everything after it
/// is `deliveryInterrupted`, because the text is already in the pane. The
/// registry runs these with its Ghostty surface; checks run them scripted.
public enum PaneInputDelivery {
    public struct Steps {
        public var settle: (TimeInterval) -> Void
        public var requireLive: () throws -> Void
        public var validate: () throws -> Void
        public var paste: (String) -> Bool
        public var enter: () -> Bool
        public init(settle: @escaping (TimeInterval) -> Void, requireLive: @escaping () throws -> Void, validate: @escaping () throws -> Void,
                    paste: @escaping (String) -> Bool, enter: @escaping () -> Bool) {
            self.settle = settle; self.requireLive = requireLive; self.validate = validate; self.paste = paste; self.enter = enter
        }
    }
    public static func deliver(_ text: String, into paneID: String, name: String, submit: Bool,
                               timing: PaneSubmissionTiming, steps: Steps) throws {
        steps.settle(timing.afterFocus)
        try steps.requireLive()
        try steps.validate()
        // False only when there is no surface, so nothing was written.
        guard steps.paste(text) else { throw ParleyWorkbenchError.unsafeRelayTarget(paneID) }
        guard submit else { return }
        do {
            steps.settle(timing.afterPaste)
            try steps.requireLive()
            try steps.validate()
            guard steps.enter() else { throw ParleyWorkbenchError.unsafeRelayTarget(paneID) }
        } catch {
            throw ParleyWorkbenchError.deliveryInterrupted(name, reason: error.localizedDescription)
        }
    }
}
