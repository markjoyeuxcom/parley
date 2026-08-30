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
