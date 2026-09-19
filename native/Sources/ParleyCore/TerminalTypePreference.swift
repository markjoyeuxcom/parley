import Foundation

/// The terminal type (`TERM`) a pane's process is told it is running in.
///
/// Ghostty advertises `xterm-ghostty` and points `TERMINFO` at the compiled
/// entry inside Parley's bundle, so every program on this Mac finds it. A
/// remote host reached over ssh has no such entry unless someone installed
/// it there: ncurses programs then refuse to start ("cannot initialize
/// terminal type"), and readline no longer knows which byte the backspace key
/// sends, so deleting a character moves the cursor the wrong way. The
/// compatible choice advertises `xterm-256color`, which every terminfo
/// database carries; Docker already gives container panes that value.
///
/// Ghostty applies its own `term` option after the surface environment, so
/// the choice travels inside the launch command as one `TERM=` word for
/// `/usr/bin/env`, where Parley alone decides it. It is read once per launch
/// generation: a changed setting reaches a pane at its next start or restart
/// and never alters a retained process.
public enum TerminalTypePreference: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Ghostty's own terminal type, with its full local feature set.
    case ghostty = "xterm-ghostty"
    /// The widely installed terminal type, which remote hosts know.
    case compatible = "xterm-256color"

    public static let `default` = TerminalTypePreference.ghostty

    /// The variable the choice sets. Container panes receive it from Docker.
    public static let environmentKey = "TERM"

    public var id: String { rawValue }

    /// The exact `TERM` value processes see.
    public var termValue: String { rawValue }

    public var label: String {
        switch self {
        case .ghostty: "Ghostty"
        case .compatible: "Compatible"
        }
    }

    public var detail: String {
        switch self {
        case .ghostty:
            "Advertises xterm-ghostty. Programs on this Mac find Ghostty's terminfo; a remote host needs it installed once."
        case .compatible:
            "Advertises xterm-256color. Works on remote hosts and with older tools without setup; Ghostty-only terminfo capabilities are not advertised."
        }
    }

    /// The `KEY=value` word a launch places before its executable, or nil
    /// when Ghostty's own value stands. It contains no shell metacharacters
    /// and is rendered as one literal word like every other argument.
    public var launchAssignment: String? {
        self == .default ? nil : "\(Self.environmentKey)=\(termValue)"
    }

    public static let explanation = "Parley's embedded Ghostty terminal advertises itself as xterm-ghostty and ships that terminfo entry for programs on this Mac. A remote host reached over ssh has no such entry unless it was installed there, so ncurses programs refuse to start with \"cannot initialize terminal type\" and the backspace key stops deleting correctly. Choose Compatible to advertise xterm-256color instead, or keep Ghostty and install its terminfo on each remote host once."

    /// Ghostty's documented way to teach one remote host its terminal type.
    public static let remoteTerminfoCommand = "infocmp -x xterm-ghostty | ssh <host> -- tic -x -"

    public static let scope = "Applies to shell and agent panes started or restarted after the change; a running pane keeps the value it started with. Container panes always receive xterm-256color from Docker."
}
