import Foundation
import ParleyCore

private struct Invocation {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let input: Data?
}

private final class RecordingRunner: CommandRunning {
    var calls: [Invocation] = []
    var respond: ([String], Data?) -> CommandOutput

    init(respond: @escaping ([String], Data?) -> CommandOutput = { _, _ in CommandOutput() }) {
        self.respond = respond
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?
    ) throws -> CommandOutput {
        calls.append(Invocation(executable: executable, arguments: arguments, environment: environment, input: input))
        return respond(arguments, input)
    }
}

private final class LockedDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (paneID: String, text: String, submit: Bool)?

    var value: (paneID: String, text: String, submit: Bool)? {
        lock.withLock { storage }
    }

    func set(paneID: String, text: String, submit: Bool) {
        lock.withLock { storage = (paneID, text, submit) }
    }
}

private final class LockedAskResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: RelayTextResponse?

    var value: RelayTextResponse? {
        lock.withLock { storage }
    }

    func set(_ value: RelayTextResponse) {
        lock.withLock { storage = value }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

private func eventually(
    timeout: TimeInterval = 2,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return predicate()
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func output(_ text: String = "", status: Int32 = 0) -> CommandOutput {
    CommandOutput(stdout: Data(text.utf8), status: status)
}

private func command(_ arguments: [String]) -> String {
    let known = [
        "has-session", "new-session", "new-window", "set-option", "select-pane", "select-window", "list-panes", "list-windows",
        "split-window", "capture-pane", "load-buffer", "paste-buffer", "send-keys",
        "respawn-pane", "kill-pane", "kill-window", "rename-window", "resize-pane", "select-layout", "delete-buffer",
    ]
    return arguments.first(where: known.contains) ?? ""
}

private func paneRow(
    id: String,
    kind: PaneKind,
    active: Bool,
    returnTo: String = "",
    relayEnabled: Bool = false,
    protocolVersion: String = "",
    windowID: String = "@0",
    workspaceActive: Bool = true,
    workspaceName: String = "parley"
) -> String {
    [id, kind.rawValue, kind.label, kind.label, "/tmp", kind.rawValue, active ? "1" : "0", windowID, returnTo, relayEnabled ? "1" : "", protocolVersion, workspaceActive ? "1" : "0", workspaceName]
        .joined(separator: "\u{1f}")
}

private func workspaceRow(
    id: String,
    windowName: String,
    active: Bool,
    name: String = "",
    folder: String = "",
    paneFolder: String = "/tmp"
) -> String {
    [id, windowName, active ? "1" : "0", name, folder, paneFolder]
        .joined(separator: "\u{1f}")
}

private func checkBootstrap() throws {
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output(status: 1)
        case "new-session": output("@0\u{1f}%0\n")
        default: output()
        }
    }
    let directory = try temporaryDirectory()
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tmux.conf").path), "tmux.conf was not written")
    let newSession = try require(runner.calls.first(where: { command($0.arguments) == "new-session" }), "new-session was not invoked")
    try expect(newSession.arguments.contains("-d"), "new-session was not detached")
    try expect(newSession.arguments.contains("/tmp"), "new-session lost its cwd")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-kind") && call.arguments.contains("shell")
    }, "initial pane was not stamped as a shell")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-name") && call.arguments.contains("tmp")
    }, "initial tmux window was not stamped with a workspace name")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-folder") && call.arguments.contains("/tmp")
    }, "initial tmux window was not stamped with its workspace folder")
}

private func checkExistingSessionAdoptsWorkspaceWithoutRestart() throws {
    let existing = workspaceRow(id: "@0", windowName: "agents", active: true)
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output()
        case "list-windows": output("\(existing)\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    try expect(!runner.calls.contains { command($0.arguments) == "new-session" }, "adoption replaced the existing tmux session")
    try expect(!runner.calls.contains { command($0.arguments) == "respawn-pane" }, "adoption restarted a live pane")
    try expect(!runner.calls.contains { command($0.arguments) == "kill-pane" }, "adoption killed a live pane")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@0")
            && call.arguments.contains("@parley-workspace-name") && call.arguments.contains("tmp")
    }, "adoption did not derive the workspace name from the live pane folder")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@0")
            && call.arguments.contains("@parley-workspace-folder") && call.arguments.contains("/tmp")
    }, "adoption did not persist the live pane folder")
}

private func checkWorkspaceLifecycle() throws {
    let existing = [
        workspaceRow(id: "@0", windowName: "parley", active: true, name: "parley", folder: "/tmp"),
        workspaceRow(id: "@1", windowName: "client", active: false, name: "client", folder: "/private/tmp"),
    ].joined(separator: "\n") + "\n"
    let panes = [
        paneRow(id: "%1", kind: .shell, active: true, windowID: "@0", workspaceName: "parley"),
        paneRow(id: "%2", kind: .codex, active: true, windowID: "@1", workspaceActive: false, workspaceName: "client"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-windows": output(existing)
        case "list-panes": output(panes)
        case "new-window": output("@2\u{1f}%9\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    let created = try controller.createWorkspace(folder: "/tmp", name: "Server")
    try expect(created.id == "@2" && created.name == "Server", "new workspace lost its tmux id or name")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "new-window" && call.arguments.contains("/tmp") && call.arguments.contains("Server")
    }, "workspace creation did not create a tmux window in its folder")
    try expect(runner.calls.contains { command($0.arguments) == "select-window" && $0.arguments.contains("@2") }, "new workspace was not selected")

    try controller.renameWorkspace("@1", name: "Website")
    try expect(runner.calls.contains { command($0.arguments) == "rename-window" && $0.arguments.contains("Website") }, "workspace rename did not update the tmux window")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-name") && call.arguments.contains("Website")
    }, "workspace rename did not update durable metadata")

    try controller.setWorkspaceFolder("@1", folder: "/tmp")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-folder") && call.arguments.contains("/tmp")
    }, "workspace folder change was not persisted")

    try controller.closeWorkspace("@1")
    try expect(runner.calls.contains { command($0.arguments) == "kill-window" && $0.arguments.contains("@1") }, "workspace close did not close its tmux window")
}

private func checkActivePaneIsScopedToSelectedWorkspace() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true, windowID: "@0", workspaceActive: false, workspaceName: "api"),
        paneRow(id: "%2", kind: .codex, active: true, windowID: "@1", workspaceActive: true, workspaceName: "web"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    let listed = try controller.listPanes()
    try expect(listed.first(where: { $0.id == "%1" })?.isActive == false, "inactive workspace exposed its selected pane as globally active")
    try expect(listed.first(where: { $0.id == "%2" })?.isActive == true, "selected workspace lost its active pane")
    let active = try controller.activePane()
    try expect(active?.id == "%2", "controller targeted a pane in the wrong workspace")
}

private func checkDirectAgentSpawn() throws {
    let source = paneRow(id: "%1", kind: .shell, active: true)
    let created = paneRow(
        id: "%2",
        kind: .claude,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    )
    var lists = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes":
            lists += 1
            return output(lists == 1 ? "\(source)\n" : "\(source)\n\(created)\n")
        case "split-window": return output("%2\n")
        default: return output()
        }
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: directory.appendingPathComponent("bin"),
        credentials: credentials
    ))

    let pane = try controller.createPane(kind: .claude, cwd: "/tmp", direction: .horizontal)

    let split = try require(runner.calls.first(where: { command($0.arguments) == "split-window" }), "split-window was not invoked")
    try expect(split.arguments.suffix(2) == ["/bin/sleep", "30"], "split did not use the bounded holding process")
    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "agent pane was not respawned")
    try expect(respawn.arguments.contains("claude"), "Claude was not passed as a direct executable argument")
    try expect(respawn.arguments.contains("--append-system-prompt"), "Claude did not receive Parley's system-prompt adapter")
    try expect(respawn.arguments.contains(AgentProtocol.text), "Claude did not receive the canonical protocol text")
    try expect(respawn.arguments.contains("/usr/bin/env"), "agent environment was not scrubbed directly")
    try expect(respawn.arguments.contains("TMUX"), "agent retained tmux control discovery")
    try expect(respawn.arguments.contains("PARLEY_PANE_ID=%2"), "agent did not receive its pane identity")
    try expect(respawn.arguments.contains(where: { $0.hasPrefix("PARLEY_RELAY_TOKEN=") }), "agent did not receive a relay credential")
    try expect(respawn.arguments.contains("PARLEY_RELAY_INFO=\(directory.appendingPathComponent("relay-url").path)"), "agent did not receive the persistent relay locator")
    try expect(respawn.arguments.contains("PARLEY_PROTOCOL_VERSION=\(AgentProtocol.version)"), "agent did not receive the protocol version")
    try expect(!respawn.arguments.contains("/bin/sh"), "agent spawn invoked /bin/sh")
    try expect(!respawn.arguments.contains(where: { $0.contains("sh -c") }), "agent spawn built a shell command string")
    try expect(pane.relayEnabled, "new agent pane was not stamped relay-ready")
    try expect(pane.protocolVersion == AgentProtocol.version, "new agent pane was not stamped with its injected protocol version")
}

private func checkSharedProtocolLaunchAdapters() throws {
    let directory = try temporaryDirectory()
    let protocolDirectory = try AgentProtocol.install(in: directory)
    let rules = try String(contentsOf: protocolDirectory.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    try expect(rules == AgentProtocol.text, "Agy's rules file drifted from the canonical protocol text")
    try expect(AgentProtocol.text.contains("protocol v\(AgentProtocol.version)"), "protocol text does not identify its version")

    let claude = AgentProtocol.command(for: .claude, protocolDirectory: protocolDirectory)
    try expect(claude == ["claude", "--append-system-prompt", AgentProtocol.text], "Claude launch adapter changed the shared protocol")

    let codex = AgentProtocol.command(for: .codex, protocolDirectory: protocolDirectory)
    try expect(codex.first == "codex" && codex.dropFirst().first == "-c", "Codex launch adapter omitted its config override")
    try expect(codex.last?.hasPrefix("developer_instructions=") == true, "Codex launch adapter omitted developer instructions")
    let codexValue = try require(codex.last?.split(separator: "=", maxSplits: 1).last.map(String.init), "Codex protocol value disappeared")
    let decodedCodex = try JSONDecoder().decode(String.self, from: Data(codexValue.utf8))
    try expect(decodedCodex == AgentProtocol.text, "Codex launch adapter changed the shared protocol")

    let agy = AgentProtocol.command(for: .agy, protocolDirectory: protocolDirectory)
    try expect(agy == ["agy", "--add-dir", protocolDirectory.path], "Agy launch adapter did not add the canonical rules workspace")

    let copilot = AgentProtocol.command(for: .copilot, protocolDirectory: protocolDirectory)
    try expect(
        copilot == ["copilot", "--allow-tool=shell(parley)"],
        "Copilot launch adapter did not limit automatic approval to Parley's shim"
    )
    let copilotEnvironment = AgentProtocol.environment(
        for: .copilot,
        protocolDirectory: protocolDirectory,
        inherited: ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/user/rules"]
    )
    try expect(
        copilotEnvironment["COPILOT_CUSTOM_INSTRUCTIONS_DIRS"] == "\(protocolDirectory.path),/user/rules",
        "Copilot did not receive the canonical protocol alongside inherited custom instructions"
    )
    try expect(AgentProtocol.command(for: .shell, protocolDirectory: protocolDirectory).isEmpty, "shell panes received agent instructions")
    try expect(
        AgentProtocol.environment(for: .shell, protocolDirectory: protocolDirectory).isEmpty,
        "shell panes received an agent protocol environment"
    )

    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil, protocolVersion: "0"),
        TmuxPane(id: "%3", kind: .agy, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, protocolVersion: AgentProtocol.version),
        TmuxPane(id: "%4", kind: .shell, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "zsh", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%5", kind: .copilot, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    try expect(AgentProtocol.stalePaneIDs(in: panes) == ["%1", "%2", "%5"], "protocol restart targeting missed Copilot or included a current agent or shell")
}

private func checkCopilotAgentSpawn() throws {
    let source = paneRow(id: "%1", kind: .shell, active: true)
    let created = paneRow(
        id: "%2",
        kind: .copilot,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    )
    var lists = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes":
            lists += 1
            return output(lists == 1 ? "\(source)\n" : "\(source)\n\(created)\n")
        case "split-window": return output("%2\n")
        default: return output()
        }
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/user/rules",
        ],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: directory.appendingPathComponent("bin"),
        credentials: credentials
    ))

    let pane = try controller.createPane(kind: .copilot, cwd: "/tmp", direction: .horizontal)

    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "Copilot pane was not respawned")
    try expect(
        respawn.arguments.suffix(2) == ["copilot", "--allow-tool=shell(parley)"],
        "Copilot was not launched directly with only its narrow Parley permission"
    )
    try expect(
        respawn.arguments.contains("--allow-tool=shell(parley)"),
        "Copilot still requires approval before it can return a Parley answer"
    )
    try expect(
        respawn.arguments.contains("COPILOT_CUSTOM_INSTRUCTIONS_DIRS=\(controller.protocolDirectory.path),/user/rules"),
        "Copilot did not receive Parley's shared protocol directory"
    )
    try expect(!respawn.arguments.contains("--allow-all"), "Copilot launch bypassed permission prompts")
    try expect(!respawn.arguments.contains("--allow-all-tools"), "Copilot launch automatically approved tools")
    try expect(!respawn.arguments.contains("--yolo"), "Copilot launch used the unsafe yolo alias")
    try expect(pane.relayEnabled, "new Copilot pane was not relay-ready")
    try expect(pane.protocolVersion == AgentProtocol.version, "new Copilot pane was not stamped with its protocol version")
}

private func checkCopilotSubmitUsesEnterAfterTrust() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(id: "%4", kind: .copilot, active: false),
    ].joined(separator: "\n") + "\n"
    var pauses: [TimeInterval] = []
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner,
        pause: { pauses.append($0) }
    )

    try controller.paste("queued question", into: "%4", submit: true)

    let submit = try require(runner.calls.first(where: { command($0.arguments) == "send-keys" }), "Copilot submission sent no key")
    try expect(submit.arguments.contains("Enter"), "trusted Copilot submission did not start the turn")
    try expect(!submit.arguments.contains("C-q"), "Copilot submission only queued the prompt instead of starting it")
    let focusCalls = runner.calls.filter { command($0.arguments) == "select-pane" }
    try expect(focusCalls.count == 2, "inactive Copilot was not focused and then restored")
    try expect(focusCalls[0].arguments.contains("%4"), "Copilot was not focused before submission")
    try expect(focusCalls[1].arguments.contains("%1"), "the original pane was not restored after Copilot submission")
    let focusIndex = try require(runner.calls.firstIndex(where: {
        command($0.arguments) == "select-pane" && $0.arguments.contains("%4")
    }), "Copilot focus call disappeared")
    let submitIndex = try require(runner.calls.firstIndex(where: {
        command($0.arguments) == "send-keys" && $0.arguments.contains("Enter")
    }), "Copilot submit call disappeared")
    let restoreIndex = try require(runner.calls.firstIndex(where: {
        command($0.arguments) == "select-pane" && $0.arguments.contains("%1")
    }), "Copilot restore call disappeared")
    try expect(focusIndex < submitIndex && submitIndex < restoreIndex, "Copilot focus handoff happened in the wrong order")
    try expect(pauses == [0.1, 0.25, 0.1], "Copilot focus, paste, and restore were not separated by settling delays")
}

private func checkCopilotTrustPromptRefusesSubmission() throws {
    let panes = paneRow(id: "%4", kind: .copilot, active: true) + "\n"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes": output(panes)
        case "capture-pane": output("Confirm folder trust\nDo you trust the files in this folder?\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    do {
        try controller.paste("do not queue behind trust", into: "%4", submit: true)
        throw CheckFailure(description: "Copilot accepted an Ask behind its folder-trust dialog")
    } catch ParleyTmuxError.copilotTrustRequired {
        // Expected: only the person can grant repository trust.
    }
    try expect(!runner.calls.contains { command($0.arguments) == "load-buffer" }, "a refused Copilot Ask still pasted its prompt")
}

private func checkAsk() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(id: "%2", kind: .codex, active: false),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.ask(from: "%1", to: "%2", text: "Should this cache be per worktree?")

    let load = try require(runner.calls.first(where: { command($0.arguments) == "load-buffer" }), "Ask did not load a tmux buffer")
    let body = String(decoding: try require(load.input, "Ask buffer had no stdin"), as: UTF8.self)
    try expect(body.contains("Claude asked:"), "Ask omitted source attribution")
    try expect(body.contains("per worktree"), "Ask omitted its body")
    let paste = try require(runner.calls.first(where: { command($0.arguments) == "paste-buffer" }), "Ask did not paste the buffer")
    try expect(paste.arguments.contains("-p") && paste.arguments.contains("-r"), "Ask did not use a multiline bracketed paste")
    try expect(paste.arguments.contains("%2"), "Ask targeted the wrong pane")
    try expect(runner.calls.contains { command($0.arguments) == "send-keys" && $0.arguments.contains("Enter") }, "human Ask action did not submit")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-return-to") && call.arguments.contains("%1")
    }, "Ask did not record its return route")
}

private func checkReturn() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: false),
        paneRow(id: "%2", kind: .codex, active: true, returnTo: "%1"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.returnAnswer(from: "%2", text: "No; worktrees can have different state.")

    let load = try require(runner.calls.first(where: { command($0.arguments) == "load-buffer" }), "Return did not load a tmux buffer")
    let body = String(decoding: try require(load.input, "Return buffer had no stdin"), as: UTF8.self)
    try expect(body.contains("Codex answered:"), "Return omitted source attribution")
    let paste = try require(runner.calls.first(where: { command($0.arguments) == "paste-buffer" }), "Return did not paste the buffer")
    try expect(paste.arguments.contains("%1"), "Return targeted the wrong pane")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("-u") && call.arguments.contains("@parley-return-to")
    }, "Return did not consume its route")
}

private func checkCrossVendorGuard() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(id: "%2", kind: .claude, active: false),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    do {
        try controller.ask(from: "%1", to: "%2", text: "review this")
        throw CheckFailure(description: "same-vendor Ask was accepted")
    } catch ParleyTmuxError.sameVendor {
        // Expected: Parley only automates the cross-vendor gap.
    }
    try expect(!runner.calls.contains { command($0.arguments) == "load-buffer" }, "rejected Ask still relayed content")
}

private func checkRelayCleaning() throws {
    let cleaned = RelayText.clean("\u{1b}[31m│ - old\r\n│ + new\u{7}\n\n\n")
    try expect(!cleaned.contains("\u{1b}"), "relay preserved an escape control")
    try expect(!cleaned.contains("│"), "relay preserved a terminal frame")
    try expect(cleaned.contains("- old") && cleaned.contains("+ new"), "relay damaged diff markers")
    try expect(!cleaned.hasSuffix("\n"), "relay retained trailing blank lines")
}

private func checkRelayDraftStartsWithSelectionOrNothing() throws {
    try expect(RelayDraft.initialText(selection: nil).isEmpty, "an unselected relay copied pane history")
    try expect(RelayDraft.initialText(selection: "  selected question  ") == "selected question", "relay did not use only the selection")
}

private func checkAgentRelaySubmitsAndExplicitPasteDoesNot() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let pasted = LockedDelivery()
    let submitted = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { paneID, text in pasted.set(paneID: paneID, text: text, submit: false) },
        submit: { paneID, text in submitted.set(paneID: paneID, text: text, submit: true) }
    )

    let response = broker.handle(token: token, target: "codex", text: "Only send this sentence.")

    try expect(response.status == 200, "valid agent relay was refused")
    try expect(response.body.submitted == true, "agent relay did not report submission")
    try expect(submitted.value?.paneID == "%2", "agent relay targeted the wrong pane")
    try expect(submitted.value?.text == "Agy said:\n\nOnly send this sentence.", "agent relay changed or failed to attribute the explicit text")
    try expect(submitted.value?.submit == true, "agent relay did not press Enter")
    try expect(pasted.value == nil, "agent relay used the unsent paste path")

    let pasteResponse = broker.handlePaste(token: token, target: "codex", text: "Leave this as a draft.")
    try expect(pasteResponse.status == 200, "valid agent paste was refused")
    try expect(pasteResponse.body.submitted == false, "explicit paste claimed it submitted")
    try expect(pasted.value?.text == "Agy said:\n\nLeave this as a draft.", "explicit paste changed the supplied text")
    try expect(pasted.value?.submit == false, "explicit paste pressed Enter")
}

private func checkCrossWorkspaceRelayAddressing() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "api"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/api", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, workspaceName: "api"),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/web", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web"),
        TmuxPane(id: "%4", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/web", currentCommand: "claude", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web"),
    ]
    let submitted = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, text in submitted.set(paneID: paneID, text: text, submit: true) }
    )

    let local = broker.handle(token: token, target: "agy", text: "local question")
    try expect(local.status == 200 && submitted.value?.paneID == "%2", "bare target did not prefer the sender's workspace")

    let qualified = broker.handle(token: token, target: "web/agy", text: "cross-workspace question")
    try expect(qualified.status == 200 && submitted.value?.paneID == "%3", "qualified target did not cross to the named workspace")

    let uniqueFallback = broker.handle(token: token, target: "Reviewer", text: "unique global question")
    try expect(uniqueFallback.status == 200 && submitted.value?.paneID == "%4", "unique target in another workspace was not reachable by name")
}

private func checkRelayCredentialPersistsAndIdentifiesSender() throws {
    let file = try temporaryDirectory().appendingPathComponent("relay-tokens.json")
    let first = try RelayCredentials(file: file)
    let token = try first.token(for: "%7")
    let reopened = try RelayCredentials(file: file)
    try expect(reopened.paneID(for: token) == "%7", "relay credential did not survive UI restart")
    try expect(reopened.paneID(for: "wrong") == nil, "wrong relay credential identified a pane")
}

private func checkRelayHTTPRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let pasted = LockedDelivery()
    let submitted = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { paneID, text in pasted.set(paneID: paneID, text: text, submit: false) },
        submit: { paneID, text in submitted.set(paneID: paneID, text: text, submit: true) }
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let shimDirectory = try RelayShim.install(in: directory)
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile)
    _ = try server.start()
    defer { server.stop() }
    let locator = try String(contentsOf: infoFile, encoding: .utf8)
    try expect(locator.hasPrefix("unix:"), "relay broker exposed TCP instead of a sandbox-safe Unix socket")
    let result = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "relay", "codex", "exact body"],
        environment: ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_INFO": infoFile.path,
            "PARLEY_RELAY_TOKEN": token,
        ]) { _, supplied in supplied },
        input: nil
    )

    try expect(result.status == 0, "relay shim request failed: \(result.stderrText)")
    let response = try JSONDecoder().decode(RelayResponseBody.self, from: result.stdout)
    try expect(response.ok && response.submitted == true, "relay HTTP response did not report submission")
    try expect(submitted.value?.text == "Agy said:\n\nexact body", "relay HTTP server changed the explicit body")

    let pasteResult = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "paste", "codex", "draft body"],
        environment: ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_INFO": infoFile.path,
            "PARLEY_RELAY_TOKEN": token,
        ]) { _, supplied in supplied },
        input: nil
    )
    try expect(pasteResult.status == 0, "paste shim request failed: \(pasteResult.stderrText)")
    let pasteResponse = try JSONDecoder().decode(RelayResponseBody.self, from: pasteResult.stdout)
    try expect(pasteResponse.ok && pasteResponse.submitted == false, "paste HTTP response claimed submission")
    try expect(pasted.value?.text == "Agy said:\n\ndraft body", "paste HTTP server changed the explicit body")
}

private func checkStableShimInstallationDoesNotOverwriteForeignCommands() throws {
    let directory = try temporaryDirectory()
    let executable = try RelayShim.installCommand(in: directory)
    let installed = try String(contentsOf: executable, encoding: .utf8)
    try expect(installed.contains("Parley Native managed relay shim"), "stable relay command was not recognisably managed")

    let foreign = "#!/bin/sh\necho foreign\n"
    try foreign.write(to: executable, atomically: true, encoding: .utf8)
    do {
        _ = try RelayShim.installCommand(in: directory)
        throw CheckFailure(description: "stable shim overwrote a foreign parley command")
    } catch RelayShimError.commandCollision {
        // Expected: a command Parley does not own is never replaced.
    }
    let preserved = try String(contentsOf: executable, encoding: .utf8)
    try expect(preserved == foreign, "foreign parley command was changed")
}

private func checkAgentAskSubmitsAndBlocksUntilTheTargetAnswers() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let wrongToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submitted = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in submitted.set(paneID: paneID, text: prompt, submit: true) },
        consultationTimeout: 2
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(token: sourceToken, target: "agy", text: "Which board representation should the plan use?"))
    }

    try expect(eventually { submitted.value != nil }, "agent Ask did not automatically submit the question")
    try expect(result.value == nil, "agent Ask returned before the target answered")
    let pending = try require(broker.consultations().first, "active consultation disappeared")
    try expect(pending.state == .awaitingAnswer, "automatic Ask did not wait for an answer")
    try expect(pending.sourcePaneID == "%1" && pending.targetPaneID == "%2", "consultation lost its route")
    try expect(submitted.value?.paneID == "%2" && submitted.value?.submit == true, "automatic Ask submitted to the wrong pane")
    try expect(submitted.value?.text.contains("Planner asked:") == true, "automatic Ask omitted source attribution")
    try expect(submitted.value?.text.contains("parley answer current") == true, "target was not given the pane-correlated answer command")
    try expect(submitted.value?.text.contains(pending.id) == false, "target was asked to copy a fragile consultation UUID")

    let refused = broker.handleAnswer(token: wrongToken, consultationID: "current", text: "I should not be accepted")
    try expect(refused.status == 404, "a different pane resolved somebody else's current consultation")
    try expect(result.value == nil, "a refused answer unblocked the requester")

    let accepted = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Use a flat seven-column array.")
    try expect(accepted.status == 200, "the target pane's answer was refused")
    try expect(eventually { result.value != nil }, "the correlated answer did not unblock agent Ask")
    try expect(result.value?.status == 200, "completed agent Ask returned an error")
    try expect(result.value?.text == "Use a flat seven-column array.", "agent Ask did not return the exact answer as command output")
    try expect(broker.consultations().isEmpty, "completed consultation remained in the UI queue")
}

private func checkAgentAskRejectsBusyTargetAndTimesOut() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(token: token, target: "agy", text: "Should this plan use minimax?"))
    }
    try expect(eventually { broker.consultations().count == 1 }, "busy-target check never started its consultation")
    let busy = broker.handleAsk(token: token, target: "agy", text: "Can I interrupt the first question?")
    try expect(busy.status == 409 && busy.text.contains("already has a consultation"), "a second Ask interrupted a target already answering")
    broker.cancelAll(reason: "Busy-target check complete.")
    try expect(eventually { result.value != nil }, "cancelling the check left the source agent blocked")

    let timeoutBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 0.05
    )
    let timedOut = timeoutBroker.handleAsk(token: token, target: "agy", text: "This should expire.")
    try expect(timedOut.status == 408, "unanswered agent Ask did not time out")
    try expect(timeoutBroker.consultations().isEmpty, "expired consultation remained in the UI queue")
}

private func checkConsultationShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let shimDirectory = try RelayShim.install(in: directory)
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile)
    _ = try server.start()
    defer { server.stop() }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "What should move first?"],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_INFO": infoFile.path,
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            askResult.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }

    try expect(eventually { broker.consultations().count == 1 }, "parley ask did not reach the local broker")
    let consultation = try require(broker.consultations().first, "shim consultation disappeared")
    try expect(consultation.state == .awaitingAnswer, "shim Ask was not submitted automatically")
    let answerOutput = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "answer", "current", "Move the rules engine first."],
        environment: ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_INFO": infoFile.path,
            "PARLEY_RELAY_TOKEN": targetToken,
        ]) { _, supplied in supplied },
        input: nil
    )
    try expect(answerOutput.status == 0, "parley answer failed: \(answerOutput.stderrText)")
    try expect(eventually { askResult.value != nil }, "parley ask stayed blocked after parley answer")
    try expect(askResult.value?.status == 0, "parley ask command exited unsuccessfully")
    try expect(askResult.value?.text == "Move the rules engine first.", "parley ask stdout did not become the target's exact answer")
}

private func checkCommandTimeout() throws {
    let runner = ProcessCommandRunner(timeout: 0.05)
    let started = Date()
    let result = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        environment: ProcessInfo.processInfo.environment,
        input: nil
    )
    try expect(result.status == 124, "timed-out command did not return status 124")
    try expect(result.stderrText.contains("timed out"), "timed-out command did not explain its failure")
    try expect(Date().timeIntervalSince(started) < 2, "command timeout did not bound the wait")
}

let checks: [(String, () throws -> Void)] = [
    ("bootstrap", checkBootstrap),
    ("existing session workspace adoption", checkExistingSessionAdoptsWorkspaceWithoutRestart),
    ("workspace lifecycle", checkWorkspaceLifecycle),
    ("active pane workspace scope", checkActivePaneIsScopedToSelectedWorkspace),
    ("direct agent argv", checkDirectAgentSpawn),
    ("shared protocol launch adapters", checkSharedProtocolLaunchAdapters),
    ("Copilot agent argv", checkCopilotAgentSpawn),
    ("Copilot trusted submission", checkCopilotSubmitUsesEnterAfterTrust),
    ("Copilot folder trust gate", checkCopilotTrustPromptRefusesSubmission),
    ("Ask and route", checkAsk),
    ("Return and consume route", checkReturn),
    ("cross-vendor guard", checkCrossVendorGuard),
    ("relay cleaning", checkRelayCleaning),
    ("selection-or-empty relay draft", checkRelayDraftStartsWithSelectionOrNothing),
    ("agent relay submits; paste does not", checkAgentRelaySubmitsAndExplicitPasteDoesNot),
    ("cross-workspace relay addressing", checkCrossWorkspaceRelayAddressing),
    ("persistent relay identity", checkRelayCredentialPersistsAndIdentifiesSender),
    ("relay shim round trip", checkRelayHTTPRoundTrip),
    ("safe stable relay shim", checkStableShimInstallationDoesNotOverwriteForeignCommands),
    ("agent Ask auto-submits and returns", checkAgentAskSubmitsAndBlocksUntilTheTargetAnswers),
    ("agent Ask busy target and timeout", checkAgentAskRejectsBusyTargetAndTimesOut),
    ("consultation shim round trip", checkConsultationShimRoundTrip),
    ("child-process timeout", checkCommandTimeout),
]

var failureCount = 0
for (name, check) in checks {
    do {
        try check()
        print("PASS \(name)")
    } catch {
        failureCount += 1
        print("FAIL \(name): \(error)")
    }
}

guard failureCount == 0 else {
    print("\(failureCount) native check(s) failed")
    exit(1)
}
print("All \(checks.count) native checks passed")
