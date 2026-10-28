import Foundation
import ParleyCore

// Parley started from inside a Claude Code session (the development build run
// from an agent's shell) handed that session's child marker to every pane, so
// a Claude pane reported "Transcript saving is off — inherited
// CLAUDE_CODE_CHILD_SESSION marker" and could not be resumed. These checks pin
// that a parent session's variables reach no pane or command run, while the
// person's own Claude configuration still does.

private func inheritedExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "InheritedSessionEnvironment", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A parent Claude Code session's variables, as a Bash tool hands them on.
private let parentSession: [String: String] = [
    "TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%3",
    "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "parent-session",
    "CLAUDE_CODE_BRIDGE_SESSION_ID": "parent-bridge", "CLAUDE_CODE_ENTRYPOINT": "cli",
    "CLAUDE_CODE_EXECPATH": "/usr/local/bin/claude", "CLAUDE_CODE_SESSION_ATTENDED": "1",
    "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/parent.sock", "CLAUDE_CODE_MESSAGING_TOKEN": "parent-messaging-token",
    "CLAUDE_PID": "4242",
]

/// The person's own configuration, which must pass through.
private let personConfiguration: [String: String] = [
    "CLAUDE_CONFIG_DIR": "/tmp/claude-config", "CLAUDE_CODE_USE_BEDROCK": "1",
    "ANTHROPIC_BASE_URL": "https://example.invalid", "CLAUDE_EFFORT": "high",
    ClaudeHostConfiguration.forceEnvironmentKey: "1",
]

@MainActor
let inheritedSessionEnvironmentChecks: [(String, () throws -> Void)] = [
    ("a parent Claude Code session's variables reach no pane, while the person's Claude configuration does", {
        let kept = InheritedSessionEnvironment.removing(from: parentSession.merging(personConfiguration) { first, _ in first })
        try inheritedExpect(kept == personConfiguration, "the scrub removed configuration or kept a parent marker: \(kept.keys.sorted())")
        try inheritedExpect(Set(InheritedSessionEnvironment.names) == Set(parentSession.keys),
                            "the list and the parent session fixture disagree")

        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("parley-inherited-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("app"), project = root.appendingPathComponent("project").path
        let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
            .merging(parentSession) { first, _ in first }.merging(personConfiguration) { first, _ in first }
        let controller = try WorkbenchController(applicationDirectory: app, environment: environment)
        try controller.bootstrap(cwd: project)
        let credentials = try RelayCredentials(file: app.appendingPathComponent("tokens.json"))
        controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("info"), shimDirectory: app.appendingPathComponent("bin"),
                                               transportDirectory: root.appendingPathComponent("transport"), credentials: credentials))
        // Ghostty overlays a launch's variables on the app's own environment,
        // so each marker must be unset by the launch command itself.
        for kind in [PaneKind.shell, .claude, .codex] {
            let pane = try controller.createPane(kind: kind, cwd: project)
            let launch = try controller.launchConfiguration(for: pane.id)
            for name in InheritedSessionEnvironment.names {
                try inheritedExpect(launch.command.contains("'-u' '\(name)'"), "a \(kind.rawValue) launch keeps the parent's \(name)")
                try inheritedExpect(launch.environment[name] == nil, "a \(kind.rawValue) launch sets the parent's \(name)")
            }
            for name in personConfiguration.keys {
                try inheritedExpect(!launch.command.contains("'-u' '\(name)'"), "a \(kind.rawValue) launch removes the person's \(name)")
            }
        }

        // A reviewed command run gets the person's environment without them.
        let command = try ReviewedCommand(argv: ["/usr/bin/env"], folder: project, sourceFolder: project)
        let output = try ApprovedCommandProcess.run(command, environment: environment).stdout
        for name in InheritedSessionEnvironment.names {
            try inheritedExpect(!output.contains("\n\(name)=") && !output.hasPrefix("\(name)="), "a command run inherited the parent's \(name)")
        }
        try inheritedExpect(output.contains("CLAUDE_CONFIG_DIR=/tmp/claude-config"), "a command run lost the person's Claude configuration")
    }),
]
