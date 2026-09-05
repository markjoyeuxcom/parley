import Foundation
import ParleyCore

private func awarenessExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
        throw NSError(domain: "AgentAwareness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func checkAgentAwarenessReferenceAcrossProjects() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("parley-awareness-\(UUID().uuidString)")
    let project = root.appendingPathComponent("unrelated project ' $(literal)")
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let projectRules = project.appendingPathComponent("AGENTS.md")
    try "This unrelated project's own instructions.\n".write(to: projectRules, atomically: true, encoding: .utf8)
    let app = root.appendingPathComponent("application")
    let transport = root.appendingPathComponent("transport-never-started")
    let bin = try RelayShim.install(in: app, transportDirectory: transport)
    let command = bin.appendingPathComponent("parley")
    let runner = ProcessCommandRunner(timeout: 3)
    func run(_ args: [String], marker: String? = nil, command: URL? = nil) throws -> CommandOutput {
        var environment = ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": "awareness-private-sentinel"]
        if let marker { environment["PARLEY_RUNTIME"] = marker }
        return try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cd \"$1\" && shift && exec \"$@\"", "parley-awareness", project.path, (command ?? bin.appendingPathComponent("parley")).path] + args,
            environment: environment,
            input: Data("unrelated stdin must not become a handoff".utf8)
        )
    }

    let help = try run(["help"])
    try awarenessExpect(help.status == 0 && help.stderr.isEmpty, "parley help is not a successful local reference: \(help.stderrText)")
    for name in [
        "parley help", "parley protocol", "parley whoami", "parley panes", "parley events",
        "parley relay", "parley paste", "parley ask ", "parley ask-many", "parley answer",
        "parley delegate", "--parent", "parley progress", "parley done", "--file",
        "parley fail", "parley status", "parley wait", "parley cancel",
        "parley context draft", "parley context add", "parley context list",
        "parley context show", "parley context discard", "--context",
        "parley signal", "reserved", "parley open", "person-only"
    ] {
        try awarenessExpect(help.stdoutText.contains(name), "command help omitted \(name)")
    }
    for alias in ["--help", "-h"] {
        let result = try run([alias])
        try awarenessExpect(result.status == 0 && result.stdout == help.stdout && result.stderr.isEmpty, "\(alias) differs from help")
    }
    let reference = try run(["protocol"])
    try awarenessExpect(reference.status == 0 && reference.stdoutText == AgentProtocol.text && reference.stderr.isEmpty,
                        "parley protocol did not recover the exact canonical launch instructions")
    for result in [help, reference] {
        try awarenessExpect(!result.stdoutText.contains("awareness-private-sentinel") && !result.stdoutText.contains(project.path),
                            "local awareness output exposed runtime authority or project paths")
    }
    for args in [[], ["unknown-command"], ["help", "extra"], ["protocol", "extra"]] {
        let result = try run(args)
        try awarenessExpect(result.status == 2 && result.stdout.isEmpty && !result.stderr.isEmpty, "invalid reference invocation was not rejected: \(args)")
    }
    try awarenessExpect(!manager.fileExists(atPath: transport.path), "local reference commands touched the relay transport")
    try awarenessExpect(try String(contentsOf: projectRules, encoding: .utf8) == "This unrelated project's own instructions.\n",
                        "local discovery changed project instructions")

    let devBin = try RelayShim.install(in: root.appendingPathComponent("development"), transportDirectory: transport, runtimeMarker: "DEV")
    let router = try RelayShim.installStableRouter(
        in: root.appendingPathComponent("stable"), productionCommand: command,
        developmentCommand: devBin.appendingPathComponent("parley")
    )
    let prodHelp = try run(["help"], command: router)
    let devHelp = try run(["help"], marker: "DEV", command: router)
    try awarenessExpect(prodHelp.status == 0 && !prodHelp.stdoutText.contains("[DEV]"), "stable router changed the Production reference")
    try awarenessExpect(devHelp.status == 0 && devHelp.stdoutText.contains("[DEV]"), "stable router lost Development reference identity")
    let routed = try run(["protocol"], marker: "DEV", command: router)
    try awarenessExpect(routed.status == 0 && routed.stdoutText == AgentProtocol.text, "routed protocol changed the canonical wording")
    print("Local help and exact protocol work from an unrelated project without a broker; aliases, routing and invalid arguments verified")
}

func checkAgentAwarenessBoundariesAndRecovery() throws {
    for required in [
        "parley help", "parley protocol", "PARLEY_COMMAND", "200 UTF-8 bytes",
        "## Implemented", "## Tested", "## Unable to test", "agent-declared",
        "native UI", "Challenge", "Verify", "verdict", "RESTART FOR PROTOCOL",
        "Settings", "sandbox_apply", "PARLEY_SWIFT_COMMAND"
    ] {
        try awarenessExpect(AgentProtocol.text.contains(required), "canonical awareness omitted \(required)")
    }
    let directory = URL(fileURLWithPath: "/example/agent-protocol")
    for kind in PaneKind.allCases where kind.isAgent {
        let environment = AgentProtocol.environment(for: kind, protocolDirectory: directory)
        try awarenessExpect(environment["PARLEY_COMMAND"] == "/example/bin/parley", "\(kind) omitted PATH-independent command recovery")
        let custom = AgentProtocol.environment(for: kind, protocolDirectory: directory, commandPath: URL(fileURLWithPath: "/managed relay/parley"))
        try awarenessExpect(custom["PARLEY_COMMAND"] == "/managed relay/parley", "\(kind) ignored the actual managed shim path")
    }
    try awarenessExpect(AgentProtocol.environment(for: .shell, protocolDirectory: directory).isEmpty, "a human Shell inherited agent command recovery metadata")
}
