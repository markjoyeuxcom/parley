/// Variables that describe the session Parley itself was started from, never
/// a pane's own: a parent terminal multiplexer, and a parent Claude Code
/// session. Parley started from inside Claude Code (the development build run
/// from an agent's shell, for one) would otherwise hand every pane that
/// session's child marker, which turns transcript saving off in a Claude pane,
/// and that session's messaging socket and token. Every pane, container client
/// and reviewed command run starts without them.
///
/// The list is exact, not a prefix: a person's own configuration
/// (`CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_USE_BEDROCK`, `ANTHROPIC_*`) and
/// Parley's `ClaudeHostConfiguration.forceEnvironmentKey` pass through.
public enum InheritedSessionEnvironment {
    public static let names: [String] = [
        "TMUX",
        "TMUX_PANE",
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_PID",
    ]

    /// `/usr/bin/env` arguments that unset every name, in this order.
    public static var unsetArguments: [String] { names.flatMap { ["-u", $0] } }

    public static func removing(from environment: [String: String]) -> [String: String] {
        environment.filter { !names.contains($0.key) }
    }
}
