import Darwin
import Dispatch
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private struct RecordedSubmission: Sendable {
    let paneID: String
    let text: String
}

private final class LockedSubmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedSubmission] = []

    var values: [RecordedSubmission] {
        lock.withLock { storage }
    }

    func append(paneID: String, text: String) {
        lock.withLock { storage.append(RecordedSubmission(paneID: paneID, text: text)) }
    }
}

private final class LockedPanes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TmuxPane]

    init(_ panes: [TmuxPane]) {
        storage = panes
    }

    var value: [TmuxPane] {
        lock.withLock { storage }
    }

    func set(_ panes: [TmuxPane]) {
        lock.withLock { storage = panes }
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

private func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func argument(named name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func output(_ text: String = "", status: Int32 = 0) -> CommandOutput {
    CommandOutput(stdout: Data(text.utf8), status: status)
}

private func command(_ arguments: [String]) -> String {
    let known = [
        "has-session", "new-session", "new-window", "set-option", "select-pane", "select-window", "list-panes", "list-windows",
        "split-window", "capture-pane", "load-buffer", "paste-buffer", "send-keys",
        "respawn-pane", "kill-pane", "kill-window", "rename-window", "resize-pane", "select-layout", "delete-buffer", "display-message",
    ]
    return arguments.first(where: known.contains) ?? ""
}

private func checkAdjacentNavigationOrder() throws {
    let ids = ["workspace-a", "workspace-b", "workspace-c"]

    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-a", offset: 1, orderedIDs: ids) == "workspace-b",
        "next navigation did not select the following item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-b", offset: -1, orderedIDs: ids) == "workspace-a",
        "previous navigation did not select the preceding item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-c", offset: 1, orderedIDs: ids) == "workspace-a",
        "next navigation did not wrap to the first item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-a", offset: -1, orderedIDs: ids) == "workspace-c",
        "previous navigation did not wrap to the last item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "missing", offset: 1, orderedIDs: ids) == "workspace-a",
        "next navigation did not recover a missing selection at the first item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: nil, offset: -1, orderedIDs: ids) == "workspace-c",
        "previous navigation did not recover a missing selection at the last item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "only", offset: 1, orderedIDs: ["only"]) == "only",
        "single-item navigation should remain on that item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: nil, offset: 1, orderedIDs: []) == nil,
        "empty navigation should have no target"
    )
}

private func checkWorkbenchStateProjection() throws {
    let readyAgent = TmuxPane(
        id: "%1",
        kind: .codex,
        customName: "Builder",
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        isStarted: true
    )

    try expect(
        WorkbenchStateProjection.connection(tmuxAvailable: false, coreAvailable: false) == .tmuxDisconnected,
        "tmux loss did not take precedence over core loss"
    )
    try expect(
        WorkbenchStateProjection.connection(tmuxAvailable: true, coreAvailable: false) == .coreDisconnected,
        "core loss was not distinguished from terminal loss"
    )
    try expect(
        WorkbenchStateProjection.connection(tmuxAvailable: true, coreAvailable: true) == .connected,
        "healthy services did not project as connected"
    )
    try expect(
        WorkbenchStateProjection.pane(nil) == .empty,
        "an empty workspace projected a running pane"
    )

    let stopped = TmuxPane(
        id: "%2",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "sleep",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        isDead: true,
        exitStatus: 7,
        isStarted: false
    )
    try expect(
        WorkbenchStateProjection.pane(stopped) == .stopped,
        "an intentionally stopped agent placeholder was misreported as exited"
    )

    let exited = TmuxPane(
        id: "%3",
        kind: .codex,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        isDead: true,
        exitStatus: 7,
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.pane(exited) == .exited(status: 7),
        "a retained dead pane lost its exit status"
    )
    let exitedSnapshot = StatusCenterProjection.snapshot(
        panes: [exited],
        handoffs: [],
        workspaceID: nil,
        coreAvailable: true
    )
    try expect(
        exitedSnapshot.counts.runningAgents == 0 && exitedSnapshot.counts.stoppedAgents == 1,
        "Status Center counted an exited agent as running"
    )

    let stale = TmuxPane(
        id: "%4",
        kind: .agy,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "agy",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: false,
        protocolVersion: "1",
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.pane(stale) == .protocolStale(reportedVersion: "1"),
        "a stale protocol was hidden by the secondary relay state"
    )

    let relayUnavailable = TmuxPane(
        id: "%5",
        kind: .copilot,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "copilot",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: false,
        protocolVersion: AgentProtocol.version,
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.pane(relayUnavailable) == .relayUnavailable,
        "a current agent without relay capability projected as ready"
    )
    try expect(
        WorkbenchStateProjection.pane(readyAgent) == .running,
        "a ready agent did not project as running"
    )
}

private func checkExitedPaneRetention() throws {
    let retainedRow = paneRow(id: "%9", kind: .shell, active: true)
        + "\u{1f}1\u{1f}7"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output()
        case "list-windows": output(workspaceRow(id: "@0", windowName: "tmp", active: true) + "\n")
        case "list-panes": output(retainedRow + "\n")
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

    let configuration = try String(contentsOf: directory.appendingPathComponent("tmux.conf"), encoding: .utf8)
    try expect(configuration.contains("remain-on-exit on"), "tmux configuration did not retain exited panes")
    try expect(
        runner.calls.contains {
            $0.arguments.contains("set-window-option")
                && $0.arguments.contains("remain-on-exit")
                && $0.arguments.contains("on")
        },
        "reattaching to an existing tmux server did not enable exited-pane retention"
    )
    let pane = try require(controller.listPanes().first, "retained dead pane was not parsed")
    try expect(pane.isDead, "retained pane was not marked dead")
    try expect(pane.exitStatus == 7, "retained pane lost its exit status")
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
    workspaceName: String = "parley",
    bracketedPasteActive: Bool = true,
    started: Bool = true
) -> String {
    [id, kind.rawValue, kind.label, kind.label, "/tmp", kind.rawValue, active ? "1" : "0", windowID, returnTo, relayEnabled ? "1" : "", protocolVersion, workspaceActive ? "1" : "0", workspaceName, bracketedPasteActive ? "1" : "0", started ? "1" : "0"]
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

    let qualified = try controller.createWorkspace(folder: "/tmp", name: "CLIENT")
    try expect(qualified.name == "CLIENT (2)", "duplicate workspace name was not visibly qualified")

    do {
        try controller.renameWorkspace("@1", name: "PARLEY")
        throw CheckFailure(description: "workspace rename accepted a duplicate name")
    } catch let error as ParleyTmuxError {
        try expect(error.errorDescription?.localizedCaseInsensitiveContains("already exists") == true, "duplicate workspace rename failed without an explanation")
    }

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

private func checkWorkspaceContinuityState() throws {
    let api = TmuxWorkspace(id: "@0", name: "api", defaultFolder: "/tmp/api", isActive: false)
    let renamedWeb = TmuxWorkspace(id: "@1", name: "website", defaultFolder: "/tmp/web", isActive: true)
    let worker = TmuxWorkspace(id: "@2", name: "worker", defaultFolder: "/tmp/worker", isActive: false)
    var state = WorkspaceContinuityState(
        favouriteFolders: ["/tmp/api/", "/tmp/api", "/tmp/web"],
        workspaceOrder: [
            WorkspaceBookmark(name: "web", folder: "/tmp/web"),
            WorkspaceBookmark(name: "closed", folder: "/tmp/closed"),
            WorkspaceBookmark(workspace: api),
        ],
        lastSelected: WorkspaceBookmark(name: "web", folder: "/tmp/web")
    )

    let ordered = state.reconcile([api, worker, renamedWeb])
    try expect(ordered.map(\.id) == ["@1", "@0", "@2"], "continuity did not restore tab order and append a new workspace")
    try expect(state.workspaceOrder.map(\.name) == ["website", "api", "worker"], "continuity did not discard stale bookmarks or refresh a renamed workspace")
    try expect(state.lastSelected == WorkspaceBookmark(workspace: renamedWeb), "continuity did not resolve the last workspace through its stable folder")
    try expect(state.selectedWorkspace(in: ordered)?.id == "@1", "continuity restored the wrong selected workspace")
    try expect(state.favouriteFolders == ["/tmp/api", "/tmp/web"], "favourite folders were not standardized and de-duplicated")

    let moved = state.moveWorkspace(id: "@2", by: -1, in: ordered)
    try expect(moved.map(\.id) == ["@1", "@2", "@0"], "workspace move did not update visual tab order")
    let unchanged = state.moveWorkspace(id: "@1", by: -1, in: moved)
    try expect(unchanged.map(\.id) == moved.map(\.id), "workspace move crossed the first-tab boundary")
    try expect(state.workspaceOrder.map(\.name) == ["website", "worker", "api"], "moved tab order was not retained in continuity state")

    let movedAPI = TmuxWorkspace(id: "@0", name: "backend", defaultFolder: "/tmp/backend", isActive: false)
    state.updateWorkspace(from: api, to: movedAPI)
    try expect(state.workspaceOrder.last == WorkspaceBookmark(workspace: movedAPI), "rename/folder update lost the workspace's tab position")
    let movedWeb = TmuxWorkspace(id: "@1", name: "frontend", defaultFolder: "/tmp/frontend", isActive: true)
    state.updateWorkspace(from: renamedWeb, to: movedWeb)
    try expect(state.lastSelected == WorkspaceBookmark(workspace: movedWeb), "rename/folder update lost the last-selected workspace")

    try expect(!state.toggleFavourite(folder: "/tmp/api/"), "removing an existing favourite reported the wrong state")
    try expect(state.toggleFavourite(folder: "/tmp/consumer"), "adding a favourite reported the wrong state")
    try expect(state.favouriteFolders == ["/tmp/web", "/tmp/consumer"], "favourite toggle did not preserve deterministic order")

    let encoded = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WorkspaceContinuityState.self, from: encoded)
    try expect(decoded == state, "workspace continuity state did not round-trip losslessly")
}

private func checkGitProjectContextParsing() throws {
    let clean = try require(
        GitProjectContextResolver.parseStatus("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head feat/project-context
        # branch.upstream origin/feat/project-context
        # branch.ab +0 -0
        """),
        "clean Git status did not produce project context"
    )
    try expect(clean.branch == "feat/project-context", "Git context lost the current branch")
    try expect(!clean.isDirty, "Git context marked a clean worktree dirty")

    let dirty = try require(
        GitProjectContextResolver.parseStatus("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head main
        1 .M N... 100644 100644 100644 abcdef0 abcdef0 native/App.swift
        ? native/NewFile.swift
        """),
        "dirty Git status did not produce project context"
    )
    try expect(dirty.branch == "main", "dirty Git context lost the current branch")
    try expect(dirty.isDirty, "tracked or untracked changes did not mark the worktree dirty")

    let detached = try require(
        GitProjectContextResolver.parseStatus("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head (detached)
        """),
        "detached Git status did not produce project context"
    )
    try expect(detached.branch == "@01234567", "detached Git context did not show a bounded commit identity")
    try expect(GitProjectContextResolver.parseStatus("") == nil, "empty Git output invented repository state")
}

private func checkCommandPaletteSearch() throws {
    let items = [
        CommandPaletteItem(
            id: "workspace:parley",
            category: .workspace,
            title: "Parley",
            detail: "/tmp/parley"
        ),
        CommandPaletteItem(
            id: "pane:codex",
            category: .pane,
            title: "Codex",
            detail: "connect4-3d · /tmp/connect4-3d",
            keywords: ["OpenAI"]
        ),
        CommandPaletteItem(
            id: "ask:codex",
            category: .ask,
            title: "Ask Codex",
            detail: "connect4-3d"
        ),
        CommandPaletteItem(
            id: "activity:review",
            category: .activity,
            title: "Agy → Codex",
            detail: "Review authentication retry plan",
            keywords: ["waiting", "auth"]
        ),
    ]

    try expect(
        CommandPaletteSearch.results(query: "", items: items).map(\.id) == items.map(\.id),
        "empty palette query did not preserve intentional command order"
    )
    try expect(
        CommandPaletteSearch.results(query: "CoDeX", items: items).first?.id == "pane:codex",
        "exact case-insensitive title match did not outrank partial titles"
    )
    try expect(
        CommandPaletteSearch.results(query: "codex auth", items: items).map(\.id) == ["activity:review"],
        "palette search did not require every query token across item metadata"
    )
    try expect(
        Set(CommandPaletteSearch.results(query: "connect4", items: items).map(\.id)) == ["pane:codex", "ask:codex"],
        "palette search did not match item detail text"
    )
    try expect(
        CommandPaletteSearch.results(query: "codex", items: items, limit: 2).count == 2,
        "palette search ignored its result bound"
    )
}

private func checkAccessibilityDescriptions() throws {
    let command = CommandPaletteItem(
        id: "activity:review",
        category: .activity,
        title: "Review returned",
        detail: "Codex answered Agy"
    )
    try expect(
        WorkbenchAccessibility.command(command)
            == "Activity: Review returned. Codex answered Agy",
        "command palette accessibility description lost its category or detail"
    )

    let handoff = try statusHandoff(
        id: "audit",
        kind: .ask,
        state: .failed,
        sourceWorkspaceID: "app",
        targetWorkspaceID: "library",
        occurredAt: 50,
        attention: .permissionRequired,
        origin: .human
    )
    try expect(
        WorkbenchAccessibility.handoff(handoff)
            == "Source audit to Target audit. Ask, failed, permission required. Task audit. Human initiated",
        "handoff accessibility description lost authoritative state"
    )
    let longHandoff = try statusHandoff(
        id: "long",
        kind: .delegate,
        state: .completed,
        sourceWorkspaceID: "app",
        targetWorkspaceID: "library",
        occurredAt: 51,
        text: String(repeating: "long instruction ", count: 40)
    )
    let longDescription = WorkbenchAccessibility.handoff(longHandoff)
    try expect(
        longDescription.count < 300 && longDescription.hasSuffix("…"),
        "handoff accessibility description read an unbounded prompt body"
    )

    let counts = StatusCenterCounts(
        runningAgents: 2,
        stoppedAgents: 1,
        outstandingQuestions: 3,
        trackedDelegations: 4,
        failures: 1,
        unreadResults: 2
    )
    try expect(
        WorkbenchAccessibility.counts(counts)
            == "2 running agents, 1 stopped agent, 3 questions, 4 delegations, 2 unread results, 1 failure",
        "Status Center count description was incomplete or grammatically ambiguous"
    )

    let exited = TmuxPane(
        id: "%7", kind: .codex, customName: "Audit", terminalTitle: "", cwd: "/tmp/library",
        currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
        bracketedPasteActive: true, isDead: true, exitStatus: 7
    )
    try expect(
        WorkbenchAccessibility.agent(exited)
            == "Audit, Codex agent. Exited with status 7. Workspace library",
        "agent accessibility description hid its exited state or workspace"
    )

    let event = StatusTimelineEvent(
        id: "event",
        handoffID: "audit",
        title: "Source audit to Target audit",
        category: "ASK",
        action: "FAILED",
        occurredAt: Date(timeIntervalSince1970: 50),
        detail: "Permission required",
        origin: .human
    )
    try expect(
        WorkbenchAccessibility.timeline(event)
            == "Source audit to Target audit. Ask, failed. Human initiated. Permission required",
        "timeline accessibility description lost origin or failure detail"
    )
}

private func checkSavedWorkspaceLayoutPersistenceAndFreshSlots() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("workspace-layouts.json")
    let layout = SavedWorkspaceLayout(
        name: "Review Pair",
        defaultFolder: "/tmp/project",
        root: .split(
            direction: .horizontal,
            ratio: 0.6,
            first: .leaf(SavedLayoutLeaf(kind: .shell, name: "Tests", folder: "/tmp/project")),
            second: .split(
                direction: .vertical,
                ratio: 0.45,
                first: .leaf(SavedLayoutLeaf(kind: .codex, name: "Reviewer", folder: "/tmp/project")),
                second: .leaf(SavedLayoutLeaf(kind: .agy, name: "Second opinion", folder: "/tmp/consumer"))
            )
        )
    )

    let firstRestoration = layout.fromSavedLayout()
    let secondRestoration = layout.fromSavedLayout()
    try expect(firstRestoration.slots.count == 3, "saved layout did not restore every leaf as a slot")
    try expect(firstRestoration.slots.allSatisfy { $0.paneID == nil && !$0.isStarted }, "fromSavedLayout started a process or reused a pane id")
    try expect(
        Set(firstRestoration.slots.map(\.id)).isDisjoint(with: Set(secondRestoration.slots.map(\.id))),
        "restoring the same saved layout reused live slot ids"
    )
    try expect(firstRestoration.slots.map(\.folder) == ["/tmp/project", "/tmp/project", "/tmp/consumer"], "saved layout collapsed per-pane folders into the default")

    let encoded = try JSONEncoder().encode(layout)
    let json = try require(String(data: encoded, encoding: .utf8), "saved layout JSON was not UTF-8")
    try expect(!json.contains("paneID") && !json.contains("slot") && !json.contains("%"), "persisted layout leaked live identifiers")
    let decoded = try JSONDecoder().decode(SavedWorkspaceLayout.self, from: encoded)
    try expect(decoded == layout, "saved layout did not round-trip losslessly")

    let store = SavedWorkspaceLayoutStore(file: file)
    try store.save(layout)
    let initiallyStored = try store.layouts()
    try expect(initiallyStored == [layout], "layout store did not persist its first layout")
    var metadata = stat()
    try expect(lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "saved layout file was not owner-only")

    let replacement = SavedWorkspaceLayout(
        name: "review pair",
        defaultFolder: "/tmp/replacement",
        root: .leaf(SavedLayoutLeaf(kind: .shell, name: "Shell", folder: "/tmp/replacement"))
    )
    try store.save(replacement)
    let replaced = try store.layouts()
    try expect(replaced == [replacement], "case-insensitive layout replacement created a duplicate name")
    try store.delete(named: "REVIEW PAIR")
    let afterDeletion = try store.layouts()
    try expect(afterDeletion.isEmpty, "case-insensitive layout deletion left the saved layout behind")
}

private func checkTmuxLayoutBecomesAnIDFreeSavedTree() throws {
    let panes = [
        TmuxPane(id: "%2", kind: .shell, customName: "Tests", terminalTitle: "", cwd: "/tmp/project", currentCommand: "zsh", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .codex, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/project", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%1", kind: .claude, customName: "Lead", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%4", kind: .agy, customName: "Second", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let tmux = "8d64,367x99,0,0{201x99,0,0[201x49,0,0,2,201x49,0,50,3],165x99,202,0[165x49,202,0,1,165x49,202,50,4]}"
    let root = try TmuxLayoutParser.savedNode(layout: tmux, panes: panes)

    guard case let .split(direction, ratio, first, second) = root else {
        throw CheckFailure(description: "tmux root did not become a saved split")
    }
    try expect(direction == .horizontal, "tmux braces did not become a horizontal split")
    try expect(abs(ratio - (201.0 / 366.0)) < 0.001, "tmux root ratio was not preserved")
    guard case let .split(firstDirection, firstRatio, _, _) = first else {
        throw CheckFailure(description: "first tmux branch did not remain split")
    }
    try expect(firstDirection == .vertical && abs(firstRatio - 0.5) < 0.001, "tmux brackets did not become a vertical split")
    guard case let .split(secondDirection, _, _, _) = second else {
        throw CheckFailure(description: "second tmux branch did not remain split")
    }
    try expect(secondDirection == .vertical, "second tmux branch changed direction")
    try expect(root.leaves.map(\.kind) == [.shell, .codex, .claude, .agy], "tmux leaf ordering or kinds changed")
    try expect(root.leaves.map(\.name) == ["Tests", "Reviewer", "Lead", "Second"], "tmux pane names were not captured")
    try expect(root.leaves.map(\.folder) == ["/tmp/project", "/tmp/project", "/tmp/consumer", "/tmp/consumer"], "tmux pane folders were not captured independently")

    let encoded = try require(String(data: JSONEncoder().encode(root), encoding: .utf8), "captured tree was not UTF-8")
    try expect(!encoded.contains("%1") && !encoded.contains("paneID"), "captured tree persisted live tmux identity")
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

private func checkStoppedAgentStartsOnlyThroughExplicitAction() throws {
    let placeholder = paneRow(
        id: "%2",
        kind: .codex,
        active: true,
        relayEnabled: false,
        protocolVersion: "",
        started: false
    )
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output("\(placeholder)\n") : output()
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

    try expect(!runner.calls.contains { command($0.arguments) == "respawn-pane" }, "constructing a stopped placeholder started an agent")
    try controller.startPane("%2")
    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "explicit Start did not launch the stopped agent")
    try expect(respawn.arguments.contains("codex"), "explicit Start launched the wrong vendor")
    try expect(respawn.arguments.contains(where: { $0.hasPrefix("PARLEY_RELAY_TOKEN=") }), "explicit Start omitted the pane credential")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-started") && call.arguments.contains("1")
    }, "explicit Start did not mark the pane running")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-protocol") && call.arguments.contains(AgentProtocol.version)
    }, "explicit Start did not stamp the injected protocol")
}

private func checkShellPaneStartsLoginShell() throws {
    let source = paneRow(id: "%1", kind: .codex, active: true)
    let created = paneRow(id: "%2", kind: .shell, active: true)
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
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "SHELL": "/bin/zsh",
        ],
        runner: runner
    )

    _ = try controller.createPane(kind: .shell, cwd: "/tmp", direction: .horizontal)

    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "shell pane was not respawned")
    try expect(respawn.arguments.suffix(2) == ["/bin/zsh", "-l"], "shell pane did not start the configured login shell")
}

private func checkRealTmuxShellLifecycle() throws {
    let environment = EnvironmentResolver.resolved()
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "real tmux integration check could not find tmux"
    )
    let directory = try temporaryDirectory()
    let controller = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: directory,
        sessionName: "parley-check",
        environment: environment
    )
    defer {
        _ = try? ProcessCommandRunner(timeout: 2).run(
            executable: tmux,
            arguments: ["-S", controller.socketPath.path, "kill-server"],
            environment: controller.environment,
            input: nil
        )
    }

    try controller.bootstrap(cwd: directory.path)
    let workspaces = try controller.listWorkspaces()
    try expect(workspaces.count == 1, "real tmux bootstrap did not create exactly one workspace")
    try expect(workspaces[0].defaultFolder == directory.path, "real tmux bootstrap lost its workspace folder")

    let shell = try controller.createPane(kind: .shell, cwd: directory.path, direction: .horizontal)
    let configuredShell = controller.environment["SHELL"].flatMap { candidate in
        candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    } ?? "/bin/zsh"
    let expectedCommand = URL(fileURLWithPath: configuredShell).lastPathComponent
    try expect(shell.currentCommand == expectedCommand, "real shell pane is running \(shell.currentCommand), expected \(expectedCommand)")
    try expect(shell.currentCommand != "sleep", "real shell pane retained the temporary holding process")

    try controller.restartPane(shell.id)
    try expect(
        eventually(timeout: 2) {
            (try? controller.listPanes().first(where: { $0.id == shell.id })?.currentCommand) == expectedCommand
        },
        "restarted real shell pane did not return to its login shell"
    )

    try controller.closePane(shell.id)
    let remainingPanes = try controller.listPanes()
    try expect(
        !remainingPanes.contains(where: { $0.id == shell.id }),
        "closed real shell pane remained in tmux"
    )
}

private func checkRealTmuxSavedLayoutRestorationPolicy() throws {
    let environment = EnvironmentResolver.resolved()
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "saved-layout integration check could not find tmux"
    )
    let directory = try temporaryDirectory()
    let consumer = try temporaryDirectory()
    let projectPath = canonicalPath(directory.path)
    let consumerPath = canonicalPath(consumer.path)
    let controller = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: directory,
        sessionName: "parley-layout-check",
        environment: environment
    )
    defer {
        _ = try? ProcessCommandRunner(timeout: 2).run(
            executable: tmux,
            arguments: ["-S", controller.socketPath.path, "kill-server"],
            environment: controller.environment,
            input: nil
        )
    }

    try controller.bootstrap(cwd: projectPath)
    let originalWorkspace = try require(try controller.listWorkspaces().first, "layout check created no initial workspace")
    let originalPaneIDs = Set(try controller.listPanes().map(\.id))
    let layout = SavedWorkspaceLayout(
        name: "Restored Review",
        defaultFolder: projectPath,
        root: .split(
            direction: .horizontal,
            ratio: 0.58,
            first: .leaf(SavedLayoutLeaf(kind: .shell, name: "Tests", folder: projectPath)),
            second: .split(
                direction: .vertical,
                ratio: 0.5,
                first: .leaf(SavedLayoutLeaf(kind: .codex, name: "Reviewer", folder: projectPath)),
                second: .leaf(SavedLayoutLeaf(kind: .agy, name: "Second", folder: consumerPath))
            )
        )
    )

    let restored = try controller.restoreWorkspaceLayout(layout, replacing: originalWorkspace.id)
    let workspaces = try controller.listWorkspaces()
    try expect(workspaces.count == 1 && workspaces[0].id == restored.id, "layout restoration did not transactionally replace the old workspace")
    let panes = try controller.listPanes().filter { $0.windowID == restored.id }
    try expect(panes.count == 3, "restored layout created the wrong pane count")
    try expect(Set(panes.map(\.id)).isDisjoint(with: originalPaneIDs), "restored layout reused dead tmux pane ids")
    let shell = try require(panes.first(where: { $0.kind == .shell }), "restored layout lost its shell")
    try expect(shell.isStarted && shell.currentCommand != "sleep", "restored shell was not started automatically")
    let agents = panes.filter { $0.kind.isAgent }
    try expect(agents.count == 2, "restored layout lost an agent placeholder")
    try expect(agents.allSatisfy { !$0.isStarted && $0.currentCommand == "sleep" }, "restored layout spent an agent session")
    try expect(agents.allSatisfy { !$0.relayEnabled && $0.protocolVersion == nil }, "stopped agent placeholder received live relay capability")
    let restoredAgyFolder = agents.first(where: { $0.kind == .agy })?.cwd
    try expect(restoredAgyFolder == consumerPath, "restored agent folder was \(restoredAgyFolder ?? "missing"), expected \(consumerPath)")

    let recaptured = try controller.captureWorkspaceLayout(workspaceID: restored.id)
    try expect(recaptured.name == layout.name && recaptured.defaultFolder == layout.defaultFolder, "recaptured workspace lost its durable identity")
    try expect(recaptured.root.leaves.map(\.kind) == layout.root.leaves.map(\.kind), "recaptured workspace changed pane ordering or kind")
    try expect(recaptured.root.leaves.map(\.name) == layout.root.leaves.map(\.name), "recaptured workspace changed pane names")
    try expect(
        recaptured.root.leaves.map { canonicalPath($0.folder) } == layout.root.leaves.map { canonicalPath($0.folder) },
        "recaptured workspace changed a pane folder"
    )
    guard case let .split(direction, ratio, _, _) = recaptured.root else {
        throw CheckFailure(description: "recaptured workspace lost its root split")
    }
    try expect(direction == .horizontal && abs(ratio - 0.58) < 0.03, "recaptured workspace lost its root direction or ratio")
}

private func checkInheritedParleyCapabilitiesAreScrubbed() throws {
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "PARLEY_PANE": "1",
            "PARLEY_PANE_ID": "%99",
            "PARLEY_RELAY_INFO": "/tmp/foreign-relay",
            "PARLEY_RELAY_TOKEN": "foreign-token",
            "PARLEY_IDEMPOTENCY_KEY": "foreign-request",
            "PARLEY_PROTOCOL_VERSION": "foreign-version",
            "PARLEY_CORE_SERVICE": "/tmp/parley-core-service",
            "PARLEY_TMUX": "/opt/homebrew/bin/tmux",
        ],
        runner: RecordingRunner()
    )

    for key in ["PARLEY_PANE", "PARLEY_PANE_ID", "PARLEY_RELAY_INFO", "PARLEY_RELAY_TOKEN", "PARLEY_IDEMPOTENCY_KEY", "PARLEY_PROTOCOL_VERSION"] {
        try expect(controller.environment[key] == nil, "controller inherited the foreign capability \(key)")
    }
    try expect(controller.environment["PARLEY_CORE_SERVICE"] == "/tmp/parley-core-service", "dev core executable override was scrubbed")
    try expect(controller.environment["PARLEY_TMUX"] == "/opt/homebrew/bin/tmux", "explicit tmux executable override was scrubbed")
}

private func checkSharedProtocolLaunchAdapters() throws {
    let directory = try temporaryDirectory()
    let protocolDirectory = try AgentProtocol.install(in: directory)
    let rules = try String(contentsOf: protocolDirectory.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    try expect(rules == AgentProtocol.text, "Agy's rules file drifted from the canonical protocol text")
    try expect(AgentProtocol.text.contains("protocol v\(AgentProtocol.version)"), "protocol text does not identify its version")
    try expect(AgentProtocol.version == "2", "tracked delegation did not advance the shared protocol version")
    for command in ["parley ask-many", "parley delegate", "parley done", "parley fail", "parley status", "parley wait"] {
        try expect(AgentProtocol.text.contains(command), "shared protocol omitted \(command)")
    }

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
    let stoppedPlaceholder = TmuxPane(
        id: "%6",
        kind: .codex,
        customName: "Stopped reviewer",
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "sleep",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        isStarted: false
    )
    try expect(
        AgentProtocol.stalePaneIDs(in: panes + [stoppedPlaceholder]) == ["%1", "%2", "%5"],
        "protocol migration would auto-start a restored agent placeholder"
    )
}

private func checkTrackedDelegationCompletesAndWaits() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let wrongToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "api"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/web", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web"),
        TmuxPane(id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submitted = LockedDelivery()
    let submissionCount = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in
            submissionCount.increment()
            submitted.set(paneID: paneID, text: prompt, submit: true)
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: "web/agy",
        text: "Implement the reviewed UI changes.\nRun the tests and report the result.",
        idempotencyKey: "delegate-ui-1"
    )
    let handoffID = try require(delegated.body.handoffID, "delegate returned no tracked handoff id")
    try expect(delegated.status == 200 && delegated.body.state == .waiting, "delegate did not return a waiting tracked item")
    try expect(submitted.value?.paneID == "%2" && submitted.value?.submit == true, "delegate was not submitted to the exact target")
    try expect(submitted.value?.text.contains("Planner delegated work:") == true, "delegate omitted source attribution")
    try expect(submitted.value?.text.contains("parley done current") == true, "delegate omitted its completion command")
    try expect(submitted.value?.text.contains("parley fail current") == true, "delegate omitted its failure command")

    let statusesResponse = broker.delegationStatus(token: sourceToken)
    try expect(statusesResponse.status == 200, "the initiating pane could not inspect its delegations")
    let statuses = try JSONDecoder().decode([RelayDelegationStatus].self, from: Data(statusesResponse.text.utf8))
    try expect(statuses.count == 1 && statuses[0].id == handoffID, "status did not return the initiating pane's tracked item")
    try expect(statuses[0].state == .waiting && statuses[0].task.contains("Implement the reviewed UI changes"), "status lost the delegation state or task")
    let foreignStatuses = try JSONDecoder().decode(
        [RelayDelegationStatus].self,
        from: Data(broker.delegationStatus(token: wrongToken).text.utf8)
    )
    try expect(foreignStatuses.isEmpty, "status exposed another pane's delegation")

    let waited = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        waited.set(broker.waitForDelegation(token: sourceToken, handoffID: handoffID))
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(waited.value == nil, "wait returned before delegated work reached a terminal state")
    let refused = broker.handleDelegationResult(
        token: wrongToken,
        handoffID: handoffID,
        text: "A different pane must not finish this.",
        succeeded: true
    )
    try expect(refused.status == 403, "a different pane completed delegated work")

    let completion = "Implemented the UI changes.\n46 checks passed."
    let accepted = broker.handleDelegationResult(
        token: targetToken,
        handoffID: "current",
        text: completion,
        succeeded: true
    )
    try expect(accepted.status == 200, "the exact target could not complete its delegated work")
    try expect(eventually { waited.value != nil }, "done did not release the waiting source command")
    try expect(waited.value == RelayTextResponse(status: 200, text: completion), "wait did not return the exact completion report")
    let completed = try require(broker.handoffs().first(where: { $0.id == handoffID }), "completed delegation disappeared")
    try expect(completed.kind == .delegate && completed.state == .completed, "delegation recorded the wrong terminal state")
    try expect(completed.resultText == completion, "delegation lost its completion report")
    try expect(completed.transitions.map(\.state) == [.created, .delivered, .waiting, .completed], "delegation recorded the wrong lifecycle")

    let duplicate = broker.handleDelegate(
        token: sourceToken,
        target: "web/agy",
        text: "Implement the reviewed UI changes.\nRun the tests and report the result.",
        idempotencyKey: "delegate-ui-1"
    )
    try expect(duplicate.body.handoffID == handoffID && duplicate.body.state == .waiting, "idempotent delegate did not return its original receipt")
    try expect(submissionCount.value == 1, "idempotent delegate submitted work twice")
}

private func checkTrackedDelegationFailureAndLiveness() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let source = TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil)
    let target = TmuxPane(id: "%2", kind: .copilot, customName: "Copilot", terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, windowID: "@0", returnToPaneID: nil)
    let livePanes = LockedPanes([source, target])
    let broker = RelayBroker(
        credentials: credentials,
        panes: { livePanes.value },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: "copilot",
        text: "Audit the patch.",
        idempotencyKey: "delegate-fail-1"
    )
    let handoffID = try require(delegated.body.handoffID, "failed delegation fixture returned no id")
    let busyAsk = broker.handleAsk(token: sourceToken, target: "copilot", text: "Interrupt it?")
    try expect(busyAsk.status == 409 && busyAsk.text.contains("already has tracked work"), "Ask interrupted a target with active delegated work")
    let failed = broker.handleDelegationResult(
        token: targetToken,
        handoffID: "current",
        text: "Tests fail in the existing fixture.",
        succeeded: false
    )
    try expect(failed.status == 200, "target could not report delegated work failure")
    let failedHandoff = try require(broker.handoffs().first(where: { $0.id == handoffID }), "failed delegation disappeared")
    try expect(failedHandoff.state == .failed && failedHandoff.resultText == "Tests fail in the existing fixture.", "failure report was not retained")
    try expect(failedHandoff.retryDisposition == .unsupported && !failedHandoff.canRetrySafely, "delegated work failure exposed unsafe delivery retry")
    let failedWait = broker.waitForDelegation(token: sourceToken, handoffID: handoffID)
    try expect(failedWait.status == 409 && failedWait.text.contains("Tests fail"), "wait disguised a delegated failure as success")

    let second = broker.handleDelegate(
        token: sourceToken,
        target: "copilot",
        text: "Check liveness.",
        idempotencyKey: "delegate-live-1"
    )
    let secondID = try require(second.body.handoffID, "liveness delegation returned no id")
    livePanes.set([source])
    let deadTarget = broker.waitForDelegation(token: sourceToken, handoffID: secondID)
    try expect(deadTarget.status == 410, "closed delegation target returned the wrong status")
    let deadHandoff = try require(broker.handoffs().first(where: { $0.id == secondID }), "dead-target delegation disappeared")
    try expect(deadHandoff.state == .failed && deadHandoff.transitions.last?.detail?.contains("closed") == true, "closed target did not fail delegated work explicitly")
}

private func checkDelegationShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3,
        livenessPollInterval: 0.01
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }
    let runner = ProcessCommandRunner(timeout: 5)
    let sourceEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": sourceToken,
        "PARLEY_IDEMPOTENCY_KEY": "shim-delegate-1",
    ]) { _, supplied in supplied }
    let targetEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": targetToken,
    ]) { _, supplied in supplied }
    let executable = shimDirectory.appendingPathComponent("parley").path

    let delegated = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "Implement the selected change."],
        environment: sourceEnvironment,
        input: nil
    )
    try expect(delegated.status == 0, "parley delegate did not reach the local broker")
    let receipt = try JSONDecoder().decode(RelayResponseBody.self, from: delegated.stdout)
    let handoffID = try require(receipt.handoffID, "delegate shim returned no handoff id")
    try expect(receipt.state == .waiting, "delegate shim returned the wrong state")

    let status = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "status"],
        environment: sourceEnvironment,
        input: nil
    )
    let statuses = try JSONDecoder().decode([RelayDelegationStatus].self, from: status.stdout)
    try expect(statuses.first?.id == handoffID && statuses.first?.state == .waiting, "parley status lost the tracked item")

    let waited = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [executable, "wait", handoffID],
                environment: sourceEnvironment,
                input: nil
            )
            waited.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            waited.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(waited.value == nil, "parley wait returned before done")

    let done = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "done", "current", "Implemented and verified."],
        environment: targetEnvironment,
        input: nil
    )
    try expect(done.status == 0 && done.stdoutText.contains("Completion returned"), "parley done did not reach the local broker")
    try expect(eventually { waited.value != nil }, "parley done did not release parley wait")
    try expect(waited.value == RelayTextResponse(status: 0, text: "Implemented and verified."), "shim wait returned the wrong report")
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
        paneRow(
            id: "%4",
            kind: .copilot,
            active: false,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version
        ),
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
    let panes = paneRow(
        id: "%4",
        kind: .copilot,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    ) + "\n"
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

private func checkPasteRequiresRelayReadyBracketedTarget() throws {
    func attempt(relayEnabled: Bool, protocolVersion: String, bracketedPasteActive: Bool) throws {
        let panes = paneRow(
            id: "%2",
            kind: .codex,
            active: true,
            relayEnabled: relayEnabled,
            protocolVersion: protocolVersion,
            bracketedPasteActive: bracketedPasteActive
        ) + "\n"
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
            try controller.paste("unsafe\nmultiline", into: "%2", submit: false)
            throw CheckFailure(description: "unsafe relay target accepted a multiline paste")
        } catch ParleyTmuxError.unsafeRelayTarget {
            // Expected: no bytes reach a target outside the current protocol.
        }
        try expect(!runner.calls.contains { command($0.arguments) == "load-buffer" }, "refused relay still loaded a tmux buffer")
    }

    try attempt(relayEnabled: true, protocolVersion: AgentProtocol.version, bracketedPasteActive: false)
    try attempt(relayEnabled: false, protocolVersion: AgentProtocol.version, bracketedPasteActive: true)
    try attempt(relayEnabled: true, protocolVersion: "stale", bracketedPasteActive: true)
}

private func checkAsk() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(
            id: "%2",
            kind: .codex,
            active: false,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version
        ),
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
        paneRow(
            id: "%1",
            kind: .claude,
            active: false,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version
        ),
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

private func checkReviewDraftsAreBoundedShellFreeAndExplicit() throws {
    let repository = try temporaryDirectory()
    let runner = RecordingRunner { arguments, _ in
        if arguments.contains("rev-parse") {
            return CommandOutput(stdout: Data("\(repository.path)\n".utf8))
        }
        if arguments.contains("status") {
            return CommandOutput(stdout: Data(" M Sources/App.swift\n?? PLAN.md\n".utf8))
        }
        if arguments.contains("--cached") {
            return CommandOutput(stdout: Data("diff --git a/staged b/staged\n+staged change\n".utf8))
        }
        return CommandOutput(stdout: Data("diff --git a/worktree b/worktree\n+working change\n".utf8))
    }
    let builder = ReviewDraftBuilder(
        gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
        environment: ["PATH": "/usr/bin:/bin"],
        runner: runner,
        maximumBytes: 4_096
    )

    let changes = try builder.changes(in: repository.path)
    try expect(changes.title == "Review repository changes", "changes draft title drifted")
    try expect(changes.text.contains("Repository: \(repository.path)"), "changes draft omitted its repository")
    try expect(changes.text.contains(" M Sources/App.swift") && changes.text.contains("?? PLAN.md"), "changes draft omitted explicit status")
    try expect(changes.text.contains("+staged change") && changes.text.contains("+working change"), "changes draft did not include both diff surfaces")
    try expect(runner.calls.count == 4, "changes draft ran an unexpected number of git commands")
    try expect(runner.calls.allSatisfy { $0.executable.path == "/usr/bin/git" }, "changes draft invoked something other than git directly")
    try expect(runner.calls.allSatisfy { Array($0.arguments.prefix(2)) == ["-C", repository.path] }, "changes draft did not scope every git command with argv")
    try expect(runner.calls.allSatisfy { $0.arguments.contains("core.fsmonitor=false") }, "changes draft allowed a configured filesystem monitor command")
    try expect(runner.calls.allSatisfy { $0.environment["GIT_OPTIONAL_LOCKS"] == "0" }, "changes draft allowed git to take optional write locks")

    let plan = repository.appendingPathComponent("PLAN.md")
    try "# Plan\n\n1. Preserve the review transport.\n".write(to: plan, atomically: true, encoding: .utf8)
    let file = try builder.file(at: plan)
    try expect(file.title == "Review PLAN.md", "file draft title omitted the selected file")
    try expect(file.text.contains("File: \(plan.path)"), "file draft omitted the exact selected path")
    try expect(file.text.contains("1. Preserve the review transport."), "file draft omitted selected file content")

    let tinyBuilder = ReviewDraftBuilder(
        gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
        environment: [:],
        runner: runner,
        maximumBytes: 24
    )
    do {
        _ = try tinyBuilder.file(at: plan)
        throw CheckFailure(description: "oversized review file was accepted")
    } catch ReviewDraftError.contentTooLarge {
        // Expected: prompts are bounded before they reach tmux.
    }

    let binary = repository.appendingPathComponent("binary.dat")
    try Data([0x41, 0, 0x42]).write(to: binary)
    do {
        _ = try builder.file(at: binary)
        throw CheckFailure(description: "binary review file was accepted")
    } catch ReviewDraftError.notText {
        // Expected: the editable relay preview is text only.
    }

    do {
        _ = try tinyBuilder.changes(in: repository.path)
        throw CheckFailure(description: "oversized changes review was accepted")
    } catch ReviewDraftError.contentTooLarge {
        // Expected: generated diffs use the same handoff ceiling as files.
    }

    let cleanRunner = RecordingRunner { arguments, _ in
        arguments.contains("rev-parse")
            ? CommandOutput(stdout: Data("\(repository.path)\n".utf8))
            : CommandOutput()
    }
    do {
        _ = try ReviewDraftBuilder(runner: cleanRunner).changes(in: repository.path)
        throw CheckFailure(description: "clean repository produced an empty review")
    } catch ReviewDraftError.noChanges {
        // Expected: an explicit empty-state error is more useful than a blank Ask.
    }

    let failedRunner = RecordingRunner { _, _ in
        CommandOutput(stdout: Data("stdout cause".utf8), stderr: Data("stderr cause".utf8), status: 128)
    }
    do {
        _ = try ReviewDraftBuilder(
            gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
            environment: [:],
            runner: failedRunner
        ).changes(in: repository.path)
        throw CheckFailure(description: "failed git command produced a review draft")
    } catch let ReviewDraftError.commandFailed(detail) {
        try expect(detail.contains("stdout cause") && detail.contains("stderr cause"), "git failure hid stdout or stderr")
    }
}

private func statusHandoff(
    id: String,
    kind: RelayHandoffKind,
    state: RelayHandoffState,
    sourceWorkspaceID: String,
    targetWorkspaceID: String,
    occurredAt: TimeInterval,
    text: String? = nil,
    resultText: String? = nil,
    readAt: TimeInterval? = nil,
    attention: RelayAttention? = nil,
    origin: RelayTransitionOrigin? = nil
) throws -> RelayHandoff {
    var object: [String: Any] = [
        "id": id,
        "idempotencyKey": "key-\(id)",
        "kind": kind.rawValue,
        "sourcePaneID": "%source-\(id)",
        "sourceName": "Source \(id)",
        "sourceKind": "codex",
        "sourceWorkspaceID": sourceWorkspaceID,
        "sourceWorkspaceName": sourceWorkspaceID,
        "targetPaneID": "%target-\(id)",
        "targetName": "Target \(id)",
        "targetKind": "claude",
        "targetWorkspaceID": targetWorkspaceID,
        "targetWorkspaceName": targetWorkspaceID,
        "text": text ?? "Task \(id)",
        "submitted": true,
        "state": state.rawValue,
        "updatedAt": occurredAt,
        "transitions": [[
            "state": state.rawValue,
            "occurredAt": occurredAt,
            "detail": "Detail \(id)",
        ]],
    ]
    if let resultText { object["resultText"] = resultText }
    if let readAt { object["readAt"] = readAt }
    if let attention { object["attention"] = attention.rawValue }
    if let origin {
        object["transitions"] = [[
            "state": state.rawValue,
            "occurredAt": occurredAt,
            "detail": "Detail \(id)",
            "origin": origin.rawValue,
        ]]
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(RelayHandoff.self, from: data)
}

private func checkStatusCenterProjectionUsesOnlyAuthoritativeState() throws {
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Lead", terminalTitle: "", cwd: "/tmp/a", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "a", isStarted: true),
        TmuxPane(id: "%2", kind: .agy, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/a", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "a", isStarted: true),
        TmuxPane(id: "%3", kind: .claude, customName: "Builder", terminalTitle: "", cwd: "/tmp/b", currentCommand: "claude", isActive: false, windowID: "@1", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "b", isStarted: true),
        TmuxPane(id: "%4", kind: .copilot, customName: "Stopped", terminalTitle: "", cwd: "/tmp/b", currentCommand: "sleep", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "b", isStarted: false),
    ]
    let handoffs = [
        try statusHandoff(id: "ask", kind: .ask, state: .waiting, sourceWorkspaceID: "@0", targetWorkspaceID: "@0", occurredAt: 30),
        try statusHandoff(id: "delegate", kind: .delegate, state: .delivered, sourceWorkspaceID: "@1", targetWorkspaceID: "@1", occurredAt: 40),
        try statusHandoff(id: "failure", kind: .relay, state: .failed, sourceWorkspaceID: "@1", targetWorkspaceID: "@1", occurredAt: 50, attention: .permissionRequired),
        try statusHandoff(id: "complete", kind: .relay, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 20, origin: .human),
        try statusHandoff(id: "result", kind: .ask, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 25, resultText: "Returned answer"),
        try statusHandoff(id: "read-result", kind: .delegate, state: .completed, sourceWorkspaceID: "@1", targetWorkspaceID: "@0", occurredAt: 15, resultText: "Already viewed", readAt: 16),
    ]

    let all = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: true
    )
    try expect(all.condition == .humanInputRequired, "human attention did not outrank ordinary waiting state")
    try expect(all.counts.runningAgents == 3 && all.counts.stoppedAgents == 1, "agent readiness counts were inferred incorrectly")
    try expect(all.counts.outstandingQuestions == 1 && all.counts.trackedDelegations == 1, "active operation counts were wrong")
    try expect(all.counts.failures == 1, "failed handoff count was wrong")
    try expect(all.counts.unreadResults == 1, "unread returned-result count was wrong")
    try expect(all.activeHandoffs.map(\.id) == ["delegate", "ask"], "active handoffs were not newest-first")
    try expect(all.timeline.first?.handoffID == "failure", "timeline was not newest-first")
    try expect(all.timeline.first?.detail == "Detail failure", "timeline discarded the authoritative transition detail")
    try expect(all.timeline.first(where: { $0.handoffID == "complete" })?.origin == .human, "timeline discarded a human intervention marker")

    let workspace = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: "@0",
        coreAvailable: true
    )
    try expect(workspace.condition == .agentsWaiting, "another workspace's failure contaminated the selected workspace")
    try expect(workspace.counts.runningAgents == 2 && workspace.counts.stoppedAgents == 0, "workspace filter returned foreign agents")
    try expect(workspace.counts.outstandingQuestions == 1 && workspace.counts.trackedDelegations == 0 && workspace.counts.failures == 0, "workspace filter returned foreign activity")
    try expect(workspace.activeHandoffs.map(\.id) == ["ask"], "workspace live collaboration included terminal work")
    try expect(workspace.counts.unreadResults == 1, "cross-workspace result was not attributed to its requesting workspace")
    try expect(Set(workspace.timeline.map(\.handoffID)) == Set(["ask", "complete", "result", "read-result"]), "workspace timeline lost or added handoffs")

    let targetWorkspace = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: "@1",
        coreAvailable: true
    )
    try expect(targetWorkspace.counts.unreadResults == 0, "a returned result was counted in the target workspace instead of its requester workspace")

    let returned = StatusCenterProjection.snapshot(
        panes: [],
        handoffs: [handoffs[4]],
        workspaceID: nil,
        coreAvailable: true
    )
    try expect(returned.condition == .resultsAvailable, "an unread returned result was shown as all clear")

    try expect(StatusCenterVisibility.isDismissible(handoffs[3]), "an ordinary completed handoff could not be dismissed locally")
    try expect(!StatusCenterVisibility.isDismissible(handoffs[0]), "active work could be hidden by local dismissal")
    try expect(!StatusCenterVisibility.isDismissible(handoffs[2]), "failed work could be hidden by local dismissal")
    try expect(!StatusCenterVisibility.isDismissible(handoffs[4]), "an unread returned result could be hidden by local dismissal")
    try expect(StatusCenterVisibility.isDismissible(handoffs[5]), "a viewed completed result could not be dismissed locally")

    let dismissed = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: true,
        dismissedHandoffIDs: ["complete", "result", "ask", "failure"],
        includeDismissed: false
    )
    try expect(!dismissed.handoffs.contains(where: { $0.id == "complete" }), "dismissed completed work remained visible")
    try expect(dismissed.handoffs.contains(where: { $0.id == "result" }), "dismissal concealed an unread result")
    try expect(dismissed.handoffs.contains(where: { $0.id == "ask" }), "dismissal concealed active work")
    try expect(dismissed.handoffs.contains(where: { $0.id == "failure" }), "dismissal concealed failed work")
    try expect(!dismissed.timeline.contains(where: { $0.handoffID == "complete" }), "dismissed work remained in the visible timeline")

    let restored = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: true,
        dismissedHandoffIDs: ["complete"],
        includeDismissed: true
    )
    try expect(restored.handoffs.contains(where: { $0.id == "complete" }), "show dismissed did not restore the local record projection")

    try expect(
        StatusCenterVisibility.retainedDismissalIDs(["complete", "missing"], handoffs: handoffs) == ["complete"],
        "stale local dismissal preferences were not pruned against durable history"
    )

    let notifications = StatusNotificationProjection.events(handoffs: handoffs)
    try expect(notifications.map(\.id) == ["failure:attention:permissionRequired", "result:result"], "notification projection emitted old, duplicate, or non-actionable events")
    try expect(notifications[0].workspaceName == "@1", "attention notification was not routed to the target workspace")
    try expect(notifications[1].workspaceName == "@0", "returned-result notification was not routed to the requesting workspace")
    try expect(
        notifications.allSatisfy { !$0.title.contains("Task") && !$0.body.contains("Returned answer") },
        "notification text exposed prompt or result content"
    )

    let unavailable = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: false
    )
    try expect(unavailable.condition == .coreUnavailable, "core failure did not override secondary status")
}

private func checkOperationalActivityIsDurableAndAuthoritative() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("activity-events.jsonl")
    let journal = try RelayActivityJournal(file: file, maximumEvents: 3)
    let created = RelayActivityEvent(
        id: "workspace-created",
        kind: .workspaceCreated,
        occurredAt: Date(timeIntervalSince1970: 20),
        workspaceID: "@0",
        workspaceName: "api",
        detail: "Opened /tmp/api"
    )
    let restarted = RelayActivityEvent(
        id: "pane-restarted",
        kind: .paneRestarted,
        occurredAt: Date(timeIntervalSince1970: 30),
        workspaceID: "@0",
        workspaceName: "api",
        paneID: "%1",
        paneName: "Codex",
        paneKind: .codex,
        detail: "Codex pane restarted."
    )
    let restored = RelayActivityEvent(
        id: "workspace-restored",
        kind: .workspaceRestored,
        occurredAt: Date(timeIntervalSince1970: 40),
        workspaceID: "@1",
        workspaceName: "web",
        detail: "Opened saved layout Web review."
    )
    try journal.record(created)
    try journal.record(restarted)
    try journal.record(restored)

    let replayed = try RelayActivityJournal(file: file, maximumEvents: 3)
    try expect(replayed.events().map(\.id) == ["workspace-restored", "pane-restarted", "workspace-created"], "activity journal did not replay newest-first")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(mode & 0o777 == 0o600, "activity journal was not owner-only")

    let truncated = try FileHandle(forWritingTo: file)
    try truncated.seekToEnd()
    try truncated.write(contentsOf: Data("{\"incomplete\"".utf8))
    try truncated.close()
    let repaired = try RelayActivityJournal(file: file, maximumEvents: 3)
    try expect(repaired.events().count == 3, "a truncated activity write destroyed valid events")
    let repairedData = try Data(contentsOf: file)
    try expect(repairedData.last == 10, "activity journal startup did not repair its truncated tail")

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [] },
        paste: { _, _ in },
        submit: { _, _ in },
        activityJournal: repaired
    )
    let closed = try broker.recordActivity(RelayActivityEventRequest(
        kind: .workspaceClosed,
        workspaceID: "@2",
        workspaceName: "worker",
        detail: "Closed 2 panes."
    ))
    try expect(closed.origin == .human, "native operational activity was not marked as human")
    try expect(broker.activityEvents(limit: 1).map(\.id) == [closed.id], "broker did not expose newest operational activity")
    try expect(broker.activityEvents().count == 3, "broker activity exceeded its journal bound")

    let status = StatusCenterProjection.snapshot(
        panes: [],
        handoffs: [],
        activityEvents: broker.activityEvents(),
        workspaceID: "@2",
        coreAvailable: true
    )
    let operational = try require(status.timeline.first, "operational activity did not enter the Status Center timeline")
    try expect(operational.handoffID == nil, "operational activity was disguised as a relay handoff")
    try expect(operational.title == "worker", "workspace activity lost its authoritative display name")
    try expect(operational.category == "WORKSPACE" && operational.action == "CLOSED", "workspace activity used the wrong timeline labels")
    try expect(operational.origin == .human, "Status Center discarded the activity origin")

    let deleted = broker.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: "api")
    try expect(deleted.status == 200, "workspace history deletion could not compact operational activity")
    try expect(!broker.activityEvents().contains(where: { $0.workspaceID == "@0" }), "workspace history deletion retained matching operational activity")
    let persistedEvents = try RelayActivityJournal(file: file, maximumEvents: 3).events()
    try expect(persistedEvents == broker.activityEvents(), "operational history deletion was not durable")
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

private func checkStableHandoffIdentityAndIdempotentRelay() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() }
    )

    let first = broker.handle(
        token: token,
        target: "codex",
        text: "Review this exact change.",
        idempotencyKey: "relay-check-1"
    )
    let duplicate = broker.handle(
        token: token,
        target: "codex",
        text: "Review this exact change.",
        idempotencyKey: "relay-check-1"
    )

    let handoffID = try require(first.body.handoffID, "successful relay returned no stable handoff id")
    try expect(duplicate.body.handoffID == handoffID, "idempotent retry returned a different handoff id")
    try expect(submissions.value == 1, "idempotent retry submitted the same relay twice")
    try expect(first.body.state == .completed && duplicate.body.state == .completed, "successful relay did not report completion")

    let handoff = try require(broker.handoffs().first(where: { $0.id == handoffID }), "completed relay was not observable")
    try expect(handoff.idempotencyKey == "relay-check-1", "handoff lost its idempotency key")
    try expect(handoff.kind == .relay && handoff.state == .completed, "relay handoff recorded the wrong kind or final state")
    try expect(
        handoff.transitions.map(\.state) == [.created, .delivered, .completed],
        "relay handoff lost its delivery state trail"
    )

    let conflict = broker.handle(
        token: token,
        target: "codex",
        text: "A different request must not reuse the key.",
        idempotencyKey: "relay-check-1"
    )
    try expect(conflict.status == 409, "an idempotency key was reused for different relay content")
    try expect(submissions.value == 1, "conflicting idempotency reuse still submitted text")

    let invalid = broker.handle(
        token: token,
        target: "codex",
        text: "This must not be delivered.",
        idempotencyKey: "contains spaces"
    )
    try expect(invalid.status == 400, "an invalid idempotency key was accepted")
    try expect(submissions.value == 1, "invalid idempotency key still submitted text")
}

private func checkCompletedHandoffRetentionIsBounded() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in }
    )

    for index in 0..<510 {
        let response = broker.handle(
            token: token,
            target: "codex",
            text: "retained handoff \(index)",
            idempotencyKey: "retention-\(index)"
        )
        try expect(response.status == 200, "retention fixture could not complete handoff \(index)")
    }

    let retained = broker.handoffs()
    try expect(retained.count == 500, "persistent core retained \(retained.count) completed handoffs instead of its 500-record bound")
    try expect(retained.contains(where: { $0.idempotencyKey == "retention-509" }), "retention discarded the newest handoff")
    try expect(!retained.contains(where: { $0.idempotencyKey == "retention-0" }), "retention kept the oldest handoff")
}

private func checkDurableHandoffJournal() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp/repo-a", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "repo-a"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/repo-b", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "repo-b"),
    ]
    let historyFile = directory.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: historyFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    let relayed = broker.handle(
        token: sourceToken,
        target: "agy",
        text: "Persist this instruction.",
        idempotencyKey: "durable-relay-1"
    )
    try expect(relayed.status == 200, "durable relay fixture failed")

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Persist this question and answer.",
            idempotencyKey: "durable-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "durable Ask fixture never started")
    let answer = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Persistent answer.")
    try expect(answer.status == 200, "durable Ask fixture could not answer")
    try expect(eventually { askResult.value?.status == 200 }, "durable Ask requester did not receive its answer")

    let pendingResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        pendingResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "This wait is interrupted by core recovery.",
            idempotencyKey: "durable-pending-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "durable pending Ask never started")

    let recoveredJournal = try RelayHandoffJournal(file: historyFile)
    let recoveredBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: recoveredJournal
    )
    let recovered = recoveredBroker.handoffs()
    try expect(recovered.count == 3, "core recovery lost durable handoff history")
    try expect(
        recovered.first(where: { $0.idempotencyKey == "durable-relay-1" })?.state == .completed,
        "completed relay did not survive core recovery"
    )
    let recoveredAsk = try require(
        recovered.first(where: { $0.idempotencyKey == "durable-ask-1" }),
        "completed Ask did not survive core recovery"
    )
    try expect(recoveredAsk.state == .completed && recoveredAsk.resultText == "Persistent answer.", "durable Ask lost its returned answer")
    try expect(recoveredAsk.hasUnreadResult && recoveredAsk.readAt == nil, "core recovery lost the unread returned-result state")
    try expect(recoveredAsk.sourceKind == .codex && recoveredAsk.targetKind == .agy, "durable Ask lost its vendor identities")
    try expect(recoveredAsk.sourceWorkspaceName == "repo-a" && recoveredAsk.targetWorkspaceName == "repo-b", "durable Ask lost its workspace identities")
    try expect(recoveredBroker.markHandoffRead(recoveredAsk.id).status == 200, "recovered core could not acknowledge a returned result")
    let recoveredPending = try require(
        recovered.first(where: { $0.idempotencyKey == "durable-pending-1" }),
        "pending Ask did not survive core recovery"
    )
    try expect(recoveredPending.state == .interrupted, "recovered in-flight Ask did not become interrupted")
    try expect(recoveredPending.transitions.last?.detail?.contains("core restarted") == true, "recovered Ask lost its interruption reason")

    let attributes = try FileManager.default.attributesOfItem(atPath: historyFile.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(mode & 0o777 == 0o600, "handoff journal was not owner-only")

    broker.cancelAll()
    try expect(eventually { pendingResult.value != nil }, "durable fixture left its original requester blocked")
    let finalJournal = try RelayHandoffJournal(file: historyFile)
    try expect(finalJournal.handoffs().count == 3, "journal replay created duplicate handoffs")
    let finalAsk = try require(
        finalJournal.handoffs().first(where: { $0.id == recoveredAsk.id }),
        "acknowledged Ask disappeared from the durable journal"
    )
    try expect(!finalAsk.hasUnreadResult && finalAsk.readAt != nil, "read acknowledgement did not survive journal replay")

    let truncated = try FileHandle(forWritingTo: historyFile)
    try truncated.seekToEnd()
    try truncated.write(contentsOf: Data("{\"incomplete\"".utf8))
    try truncated.close()
    let repairedJournal = try RelayHandoffJournal(file: historyFile)
    try expect(repairedJournal.handoffs().count == 3, "a truncated final write destroyed valid history")
    let repairedData = try Data(contentsOf: historyFile)
    try expect(repairedData.last == 10, "journal startup did not repair its truncated tail")
    let replayedJournal = try RelayHandoffJournal(file: historyFile)
    try expect(replayedJournal.handoffs().count == 3, "repaired journal did not survive a second replay")

    let boundedFile = directory.appendingPathComponent("bounded-handoffs.jsonl")
    let boundedJournal = try RelayHandoffJournal(file: boundedFile, maximumHandoffs: 2)
    let boundedBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: boundedJournal
    )
    for index in 0..<3 {
        let result = boundedBroker.handle(
            token: sourceToken,
            target: "agy",
            text: "bounded durable handoff \(index)",
            idempotencyKey: "bounded-durable-\(index)"
        )
        try expect(result.status == 200, "bounded journal fixture could not deliver handoff \(index)")
    }
    try expect(boundedJournal.handoffs().count == 2, "live journal projection exceeded its handoff bound")
    let replayedBounded = try RelayHandoffJournal(file: boundedFile, maximumHandoffs: 2).handoffs()
    try expect(replayedBounded.count == 2, "replayed journal exceeded its handoff bound")
    try expect(!replayedBounded.contains(where: { $0.idempotencyKey == "bounded-durable-0" }), "bounded journal retained its oldest terminal handoff")
}

private func checkWorkspaceHandoffHistoryDeletion() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let repoAToken = try credentials.token(for: "%1")
    let repoBToken = try credentials.token(for: "%2")
    let repoCToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex A", terminalTitle: "", cwd: "/tmp/repo-a", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "repo-a"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy B", terminalTitle: "", cwd: "/tmp/repo-b", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "repo-b"),
        TmuxPane(id: "%3", kind: .claude, customName: "Claude C", terminalTitle: "", cwd: "/tmp/repo-c", currentCommand: "claude", isActive: false, windowID: "@2", returnToPaneID: nil, workspaceName: "repo-c"),
        TmuxPane(id: "%4", kind: .codex, customName: "Codex C", terminalTitle: "", cwd: "/tmp/repo-c", currentCommand: "codex", isActive: false, windowID: "@2", returnToPaneID: nil, workspaceName: "repo-c"),
    ]
    let historyFile = directory.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: historyFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    let crossWorkspace = broker.handle(
        token: repoAToken,
        target: "agy",
        text: "Delete this completed cross-workspace relay.",
        idempotencyKey: "delete-workspace-cross"
    )
    try expect(crossWorkspace.status == 200, "workspace deletion fixture could not create its cross-workspace history")
    let unaffected = broker.handle(
        token: repoCToken,
        target: "Codex C",
        text: "Keep this repo-c relay.",
        idempotencyKey: "delete-workspace-keep"
    )
    try expect(unaffected.status == 200, "workspace deletion fixture could not create unrelated history")

    let pendingResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        pendingResult.set(broker.handleAsk(
            token: repoAToken,
            target: "agy",
            text: "Keep this active Ask even while history is deleted.",
            idempotencyKey: "delete-workspace-active"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "workspace deletion fixture never started its active Ask")

    let invalid = broker.deleteWorkspaceHistory(workspaceID: "", workspaceName: "")
    try expect(invalid.status == 400, "workspace deletion accepted an empty scope")
    let deleted = broker.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: "repo-a")
    try expect(deleted.status == 200, "workspace history deletion failed: \(deleted.text)")

    let remaining = broker.handoffs()
    try expect(!remaining.contains(where: { $0.idempotencyKey == "delete-workspace-cross" }), "workspace deletion retained matching completed history")
    try expect(remaining.contains(where: { $0.idempotencyKey == "delete-workspace-keep" }), "workspace deletion removed another workspace's history")
    try expect(remaining.contains(where: { $0.idempotencyKey == "delete-workspace-active" }), "workspace deletion removed active work")
    let persisted = try RelayHandoffJournal(file: historyFile).handoffs()
    try expect(!persisted.contains(where: { $0.idempotencyKey == "delete-workspace-cross" }), "workspace deletion did not compact the durable journal")
    try expect(persisted.contains(where: { $0.idempotencyKey == "delete-workspace-keep" }), "durable deletion removed unrelated history")
    try expect(persisted.contains(where: { $0.idempotencyKey == "delete-workspace-active" }), "durable deletion removed an active handoff")

    try expect(broker.handleAnswer(token: repoBToken, consultationID: "current", text: "Still alive.").status == 200, "the preserved Ask could not be answered")
    try expect(eventually { pendingResult.value?.status == 200 }, "the preserved Ask requester remained blocked")
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

private func checkRelayCredentialReloadsExternalChanges() throws {
    let file = try temporaryDirectory().appendingPathComponent("relay-tokens.json")
    let core = try RelayCredentials(file: file)
    let reattachedUI = try RelayCredentials(file: file)

    let token = try reattachedUI.token(for: "%12")

    try expect(
        core.paneID(for: token) == "%12",
        "a running coordination core did not observe a pane credential created after it started"
    )
}

private func checkRestartRotatesRelayCredential() throws {
    let pane = paneRow(
        id: "%12",
        kind: .codex,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    ) + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(pane) : output()
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let oldToken = try credentials.token(for: "%12")
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

    try controller.restartPane("%12")

    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "restart did not respawn the pane")
    let field = try require(
        respawn.arguments.first(where: { $0.hasPrefix("PARLEY_RELAY_TOKEN=") }),
        "restarted pane received no relay credential"
    )
    let newToken = String(field.dropFirst("PARLEY_RELAY_TOKEN=".count))
    try expect(newToken != oldToken, "pane restart reused its old relay credential")
    try expect(credentials.paneID(for: oldToken) == nil, "old relay credential survived pane restart")
    try expect(credentials.paneID(for: newToken) == "%12", "new relay credential does not identify the restarted pane")
}

private func checkRelayFilesystemRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let pasted = LockedDelivery()
    let submitted = LockedDelivery()
    let submissionCount = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { paneID, text in pasted.set(paneID: paneID, text: text, submit: false) },
        submit: { paneID, text in
            submissionCount.increment()
            submitted.set(paneID: paneID, text: text, submit: true)
        }
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { transport.stop() }
    let relayEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": token,
        "PARLEY_IDEMPOTENCY_KEY": "shim-relay-1",
    ]) { _, supplied in supplied }
    let result = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "relay", "codex", "exact body"],
        environment: relayEnvironment,
        input: nil
    )

    try expect(result.status == 0, "relay shim request failed: \(result.stderrText)")
    let response = try JSONDecoder().decode(RelayResponseBody.self, from: result.stdout)
    try expect(response.ok && response.submitted == true, "relay filesystem response did not report submission")
    let relayHandoffID = try require(response.handoffID, "relay filesystem response lost its handoff id")
    try expect(submitted.value?.text == "Agy said:\n\nexact body", "relay filesystem transport changed the explicit body")

    let duplicateResult = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "relay", "codex", "exact body"],
        environment: relayEnvironment,
        input: nil
    )
    try expect(duplicateResult.status == 0, "idempotent relay shim retry failed: \(duplicateResult.stderrText)")
    let duplicateResponse = try JSONDecoder().decode(RelayResponseBody.self, from: duplicateResult.stdout)
    try expect(duplicateResponse.handoffID == relayHandoffID, "shim retry returned a different handoff id")
    try expect(submissionCount.value == 1, "shim retry submitted the relay twice")

    let pasteResult = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "paste", "codex", "draft body"],
        environment: ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_TOKEN": token,
            "PARLEY_IDEMPOTENCY_KEY": "shim-paste-1",
        ]) { _, supplied in supplied },
        input: nil
    )
    try expect(pasteResult.status == 0, "paste shim request failed: \(pasteResult.stderrText)")
    let pasteResponse = try JSONDecoder().decode(RelayResponseBody.self, from: pasteResult.stdout)
    try expect(pasteResponse.ok && pasteResponse.submitted == false, "paste filesystem response claimed submission")
    try expect(pasted.value?.text == "Agy said:\n\ndraft body", "paste filesystem transport changed the explicit body")
    try expect(eventually {
        let names = ["inbox", "processing", "outbox"]
        return names.allSatisfy { name in
            let path = transportDirectory.appendingPathComponent(name)
            return (try? FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty) == true
        }
    }, "completed filesystem exchanges retained request, credential, or response files")
}

private func checkRelayShimUsesPinnedFilesystemTransport() throws {
    let directory = try temporaryDirectory()
    let executable = try RelayShim.installCommand(in: directory)
    let script = try String(contentsOf: executable, encoding: .utf8)
    try expect(!script.contains("/usr/bin/curl"), "relay shim still depends on a sandbox-blocked socket client")
    try expect(script.contains("Parley Native managed filesystem relay"), "relay shim does not use the managed filesystem transport")
    try expect(script.contains("request_id="), "relay shim does not correlate filesystem responses")
    try expect(script.contains("PARLEY_IDEMPOTENCY_KEY"), "relay shim sends no idempotency key")
}

private func checkRelayFilesystemRuntimeIsProtectedAndStopsCleanly() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
    let transport = RelayFileTransport(broker: broker, runtimeDirectory: runtime)
    try transport.start()

    for name in ["", "inbox", "processing", "outbox"] {
        let path = name.isEmpty ? runtime : runtime.appendingPathComponent(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        try expect(attributes[.type] as? FileAttributeType == .typeDirectory, "filesystem relay path is not a directory")
        try expect(attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()), "filesystem relay directory has the wrong owner")
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "filesystem relay directory is not owner-only")
    }
    let heartbeat = runtime.appendingPathComponent("heartbeat")
    let heartbeatAttributes = try FileManager.default.attributesOfItem(atPath: heartbeat.path)
    try expect((heartbeatAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "filesystem relay heartbeat is not owner-only")
    transport.stop()
    try expect(!FileManager.default.fileExists(atPath: heartbeat.path), "stopped filesystem relay left a live heartbeat")

    let symlinkParent = try temporaryDirectory()
    let symlinkRuntime = symlinkParent.appendingPathComponent("runtime", isDirectory: true)
    let redirected = try temporaryDirectory()
    try FileManager.default.createSymbolicLink(at: symlinkRuntime, withDestinationURL: redirected)
    let redirectedTransport = RelayFileTransport(broker: broker, runtimeDirectory: symlinkRuntime)
    do {
        try redirectedTransport.start()
        redirectedTransport.stop()
        throw CheckFailure(description: "filesystem relay accepted a symlinked runtime directory")
    } catch RelayFileTransportError.invalidRuntimeDirectory {
        // Expected: an agent cannot redirect the core through a symlink.
    }
}

private func checkLargeCoreActivityResponseIsComplete() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in })
    for index in 0..<40 {
        let body = "handoff-\(index)-" + String(repeating: "x", count: 4_096)
        let response = broker.handle(token: token, target: "codex", text: body, idempotencyKey: "large-response-\(index)")
        try expect(response.status == 200, "large-response fixture could not create a handoff")
    }

    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "large-response-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let handoffs = try client.handoffs(limit: 40)
    try expect(handoffs.count == 40, "large activity response was truncated")
    try expect(handoffs.allSatisfy { $0.text.count > 4_000 }, "large activity response lost handoff bodies")
}

private func checkCoreControlSurvivesClientReattachment() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let retryAttempts = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, text in
            guard text.contains("retry this delivery") else { return }
            retryAttempts.increment()
            if retryAttempts.value == 1 {
                throw ParleyTmuxError.unsafeRelayTarget("Agy")
            }
        },
        consultationTimeout: 3
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "fixture-control-token"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    _ = try server.start()
    defer { server.stop() }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleAsk(token: sourceToken, target: "agy", text: "Can a new UI finish this wait?"))
    }
    try expect(eventually { broker.consultations().count == 1 }, "coordination core did not retain the consultation")

    var attachedClient: RelayCoreClient? = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let attachedCount = try attachedClient?.consultations().count
    try expect(attachedCount == 1, "the first UI client could not inspect core state")
    let attachedHandoffs = try attachedClient?.handoffs()
    try expect(attachedHandoffs?.count == 1 && attachedHandoffs?.first?.state == .waiting, "the first UI client could not inspect handoff state")
    attachedClient = nil

    let reattachedClient = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let pending = try require(try reattachedClient.consultations().first, "a reattached UI lost the active consultation")
    let reattachedHandoff = try require(try reattachedClient.handoffs().first, "a reattached UI lost the active handoff")
    try expect(reattachedHandoff.id == pending.id, "consultation and handoff identities diverged after UI reattachment")
    let activity = try reattachedClient.recordActivity(RelayActivityEventRequest(
        kind: .paneRestarted,
        workspaceID: "@0",
        workspaceName: "fixture",
        paneID: "%2",
        paneName: "Agy",
        paneKind: .agy,
        detail: "Agy pane restarted."
    ))
    try expect(activity.origin == .human, "core activity route did not stamp human origin")
    let recentActivityIDs = try reattachedClient.activityEvents(limit: 1).map(\.id)
    try expect(recentActivityIDs == [activity.id], "reattached UI could not read operational activity")
    var unauthorizedActivityWasRejected = false
    do {
        _ = try RelayCoreClient(infoFile: infoFile, controlToken: "not-the-control-token").recordActivity(
            RelayActivityEventRequest(
                kind: .workspaceCreated,
                workspaceID: "@9",
                workspaceName: "forged"
            )
        )
    } catch RelayCoreError.response(401, _) {
        unauthorizedActivityWasRejected = true
    }
    try expect(unauthorizedActivityWasRejected, "an unauthenticated client recorded native operational activity")
    let returned = try reattachedClient.answerFromUI(
        consultationID: pending.id,
        text: "Yes; the wait belongs to the core."
    )
    try expect(returned.status == 200, "the reattached UI could not complete the consultation")
    try expect(eventually { askResult.value != nil }, "the waiting Ask stayed blocked after UI reattachment")
    try expect(askResult.value?.text == "Yes; the wait belongs to the core.", "the core returned the wrong answer")
    let unread = try require(
        try reattachedClient.handoffs().first(where: { $0.id == pending.id }),
        "the completed Ask disappeared before its result could be viewed"
    )
    try expect(unread.hasUnreadResult && unread.readAt == nil, "a newly returned Ask result was not unread")
    try expect(unread.transitions.suffix(2).allSatisfy { $0.origin == .human }, "manual UI return was not recorded as human intervention")
    let unreadHandoffs = try reattachedClient.unreadHandoffs()
    try expect(unreadHandoffs.map(\.id) == [pending.id], "the unread endpoint omitted the returned Ask")
    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "not-the-control-token")
    let unauthorizedRead = try unauthorized.markHandoffRead(pending.id)
    try expect(unauthorizedRead.status == 401, "an unauthenticated UI marked a result read")
    let stillUnread = try reattachedClient.handoffs().first(where: { $0.id == pending.id })?.hasUnreadResult
    try expect(
        stillUnread == true,
        "the rejected acknowledgement changed the read receipt"
    )
    let firstRead = try reattachedClient.markHandoffRead(pending.id)
    try expect(firstRead.status == 200, "the authenticated UI could not acknowledge a result")
    let repeatedRead = try reattachedClient.markHandoffRead(pending.id)
    try expect(repeatedRead.status == 200, "read acknowledgement was not idempotent")
    let acknowledged = try require(
        try reattachedClient.handoffs().first(where: { $0.id == pending.id }),
        "the acknowledged Ask disappeared"
    )
    try expect(!acknowledged.hasUnreadResult && acknowledged.readAt != nil, "the durable handoff did not record that its result was viewed")
    let remainingUnread = try reattachedClient.unreadHandoffs()
    try expect(remainingUnread.isEmpty, "the unread endpoint retained an acknowledged result")

    let cancelledAskResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        cancelledAskResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Can the reattached UI cancel this wait?",
            idempotencyKey: "ui-cancel-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "the cancellable UI Ask never started")
    let cancellable = try require(try reattachedClient.consultations().first, "the UI could not inspect the cancellable Ask")
    let cancelled = try reattachedClient.cancelHandoff(cancellable.id)
    try expect(cancelled.status == 200, "the authenticated UI could not cancel the Ask")
    try expect(eventually { cancelledAskResult.value != nil }, "UI cancellation left the requester blocked")
    try expect(cancelledAskResult.value?.status == 409, "UI cancellation returned the wrong result to the requester")
    let cancelledHandoff = try require(
        try reattachedClient.handoffs().first(where: { $0.id == cancellable.id }),
        "the cancelled UI handoff disappeared"
    )
    try expect(cancelledHandoff.state == .cancelled, "the UI cancellation did not record a cancelled handoff")
    let recent = try reattachedClient.handoffs(limit: 1)
    try expect(recent.count == 1 && recent.first?.id == cancellable.id, "the activity client did not receive only the newest handoff")

    let failedRelay = broker.handle(
        token: sourceToken,
        target: "agy",
        text: "retry this delivery",
        idempotencyKey: "ui-retry-relay-1"
    )
    let failedRelayID = try require(failedRelay.body.handoffID, "UI retry fixture returned no handoff id")
    let retriedRelay = try reattachedClient.retryHandoff(failedRelayID)
    try expect(retriedRelay.status == 200, "the authenticated UI could not retry a safe failed delivery")
    let retriedHandoff = try require(
        try reattachedClient.handoffs().first(where: { $0.id == failedRelayID }),
        "UI-retried handoff disappeared"
    )
    try expect(retriedHandoff.state == .completed, "UI retry did not complete the original handoff")
    try expect(retryAttempts.value == 2, "UI retry did not run exactly one additional delivery attempt")

    let unauthorizedDeletion = try unauthorized.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: nil)
    try expect(unauthorizedDeletion.status == 401, "an unauthenticated UI deleted workspace history")
    let historyAfterRejectedDeletion = try reattachedClient.handoffs()
    try expect(!historyAfterRejectedDeletion.isEmpty, "rejected workspace deletion changed history")
    let deletion = try reattachedClient.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: nil)
    try expect(deletion.status == 200, "the authenticated UI could not delete workspace history")
    let historyAfterDeletion = try reattachedClient.handoffs()
    try expect(historyAfterDeletion.isEmpty, "workspace deletion route retained terminal history")
    let activityAfterDeletion = try reattachedClient.activityEvents()
    try expect(activityAfterDeletion.isEmpty, "workspace deletion route retained operational activity")
}

private func checkPersistentCoreProcessSurvivesClientExit() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let shimDirectory = try RelayShim.install(in: directory)
    let infoFile = directory.appendingPathComponent("relay-url")
    let uiEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_UI_FIXTURE": "1",
    ]) { _, supplied in supplied }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

    let ui = try ProcessCommandRunner(timeout: 5).run(
        executable: executable,
        arguments: ["--application-directory", directory.path, "--cwd", "/tmp"],
        environment: uiEnvironment,
        input: nil
    )
    try expect(ui.status == 0, "the fixture UI could not launch the core: \(ui.stderrText)")
    let logAttributes = try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("core.log").path
    )
    let logMode = (logAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(logMode & 0o777 == 0o600, "core log was not owner-only")
    let pidFile = directory.appendingPathComponent("core.pid")
    defer {
        if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1 {
            _ = Darwin.kill(pid, SIGTERM)
        }
    }

    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let reattachedClient = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    try expect(reattachedClient.isHealthy(), "the core exited when its launching UI process exited")

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "Will this wait survive UI exit?"],
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

    try expect(
        eventually(timeout: 3) { (try? reattachedClient.consultations().count) == 1 },
        "the separate core process did not retain the blocking Ask"
    )
    let pending = try require(try reattachedClient.consultations().first, "the new UI client lost the wait")
    let answer = try reattachedClient.answerFromUI(
        consultationID: pending.id,
        text: "Yes. The service owns the wait."
    )
    try expect(answer.status == 200, "the reattached UI could not answer through the core")
    try expect(eventually(timeout: 3) { askResult.value != nil }, "the separate core left Ask blocked")
    try expect(askResult.value?.status == 0, "the Ask command failed after UI reattachment")
    try expect(askResult.value?.text == "Yes. The service owns the wait.", "the reattached answer was changed")
}

private func checkCoreRestartInterruptsWaitAndRecoversDiscovery() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let shimDirectory = try RelayShim.install(in: directory)
    let infoFile = directory.appendingPathComponent("relay-url")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let uiEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_UI_FIXTURE": "1",
    ]) { _, supplied in supplied }

    func launchUI() throws {
        let output = try ProcessCommandRunner(timeout: 5).run(
            executable: executable,
            arguments: ["--application-directory", directory.path, "--cwd", "/tmp"],
            environment: uiEnvironment,
            input: nil
        )
        try expect(output.status == 0, "fixture UI could not start the core: \(output.stderrText)")
    }

    func servicePID() throws -> Int32 {
        let raw = try String(contentsOf: directory.appendingPathComponent("core.pid"), encoding: .utf8)
        guard let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw CheckFailure(description: "fixture core wrote an invalid pid")
        }
        return pid
    }

    try launchUI()
    var activePID = try servicePID()
    defer { _ = Darwin.kill(activePID, SIGTERM) }
    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    var client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    try expect(
        eventually(timeout: 3) { client.isHealthy() },
        "fixture core did not remain healthy after its launching UI exited"
    )

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 6).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "Will restart strand this wait?"],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_INFO": infoFile.path,
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            let detail = [output.stdoutText, output.stderrText].filter { !$0.isEmpty }.joined(separator: "\n")
            askResult.set(RelayTextResponse(status: Int(output.status), text: detail))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }
    try expect(
        eventually(timeout: 3) { (try? client.consultations().count) == 1 },
        "restart check never established its blocking Ask"
    )

    try expect(Darwin.kill(activePID, SIGTERM) == 0, "could not stop the fixture core")
    try expect(eventually(timeout: 3) { askResult.value != nil }, "core restart left the Ask command hanging")
    try expect(askResult.value?.status != 0, "core restart pretended the interrupted Ask succeeded")
    try expect(
        askResult.value?.text.localizedCaseInsensitiveContains("stopped before the consultation completed") == true,
        "core restart did not return an explicit interruption reason: \(askResult.value?.text ?? "no response")"
    )
    try expect(eventually(timeout: 3) { !client.isHealthy() }, "stopped core still reported healthy")

    try launchUI()
    activePID = try servicePID()
    client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    try expect(
        eventually(timeout: 3) { client.isHealthy() },
        "a new UI could not restart the core"
    )
    let restartedConsultations = try client.consultations()
    try expect(restartedConsultations.isEmpty, "the restarted core revived an impossible stale wait")
}

private func runUIFixture() throws {
    guard let rawDirectory = argument(named: "--application-directory") else {
        throw CheckFailure(description: "fixture UI needs an application directory")
    }
    var coreEnvironment = ProcessInfo.processInfo.environment
    coreEnvironment.removeValue(forKey: "PARLEY_UI_FIXTURE")
    coreEnvironment["PARLEY_CORE_FIXTURE"] = "1"
    _ = try RelayCoreLauncher.ensureRunning(
        applicationDirectory: URL(fileURLWithPath: rawDirectory, isDirectory: true),
        cwd: argument(named: "--cwd") ?? "/tmp",
        environment: coreEnvironment,
        executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        timeout: 3
    )
}

@MainActor
private func runCoreServiceFixture() throws {
    // The launcher returns as soon as the health endpoint responds, after
    // which its short-lived fixture UI exits. Ignore its parent-exit signal
    // before opening that endpoint so readiness cannot be observed inside a
    // small SIGHUP race.
    signal(SIGHUP, SIG_IGN)
    guard let rawDirectory = argument(named: "--application-directory") else {
        throw CheckFailure(description: "fixture core needs an application directory")
    }
    let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 10
    )
    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let server = RelayHTTPServer(
        broker: broker,
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken
    )
    try server.start()
    let agentTransport = RelayFileTransport(
        broker: broker,
        runtimeDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: directory)
    )
    try agentTransport.start()
    let pidFile = directory.appendingPathComponent("core.pid")
    try String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

    RelayServiceProcess.waitForTermination { _ in
        server.stop()
        agentTransport.stop()
        try? FileManager.default.removeItem(at: pidFile)
    }
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
    let submissionCount = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in
            submissionCount.increment()
            submitted.set(paneID: paneID, text: prompt, submit: true)
        },
        consultationTimeout: 2
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Which board representation should the plan use?",
            idempotencyKey: "ask-board-1"
        ))
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
    let waitingHandoff = try require(broker.handoffs().first(where: { $0.id == pending.id }), "Ask created no observable handoff")
    try expect(waitingHandoff.idempotencyKey == "ask-board-1", "Ask handoff lost its idempotency key")
    try expect(waitingHandoff.kind == .ask && waitingHandoff.state == .waiting, "Ask handoff did not enter waiting state")
    try expect(
        waitingHandoff.transitions.map(\.state) == [.created, .delivered, .waiting],
        "Ask handoff recorded the wrong pre-answer state trail"
    )

    let concurrentRetry = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        concurrentRetry.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Which board representation should the plan use?",
            idempotencyKey: "ask-board-1"
        ))
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(concurrentRetry.value == nil, "concurrent idempotent Ask retry returned before the answer")
    try expect(submissionCount.value == 1, "concurrent idempotent Ask retry submitted the question twice")

    let refused = broker.handleAnswer(token: wrongToken, consultationID: "current", text: "I should not be accepted")
    try expect(refused.status == 404, "a different pane resolved somebody else's current consultation")
    try expect(result.value == nil, "a refused answer unblocked the requester")

    let accepted = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Use a flat seven-column array.")
    try expect(accepted.status == 200, "the target pane's answer was refused")
    try expect(eventually { result.value != nil }, "the correlated answer did not unblock agent Ask")
    try expect(eventually { concurrentRetry.value != nil }, "the correlated answer did not unblock the idempotent Ask retry")
    try expect(result.value?.status == 200, "completed agent Ask returned an error")
    try expect(result.value?.text == "Use a flat seven-column array.", "agent Ask did not return the exact answer as command output")
    try expect(concurrentRetry.value == result.value, "concurrent idempotent Ask retry received a different result")
    try expect(broker.consultations().isEmpty, "completed consultation remained in the UI queue")
    let completedHandoff = try require(broker.handoffs().first(where: { $0.id == pending.id }), "completed Ask handoff disappeared")
    try expect(completedHandoff.state == .completed, "answered Ask did not reach completed state")
    try expect(
        completedHandoff.transitions.map(\.state) == [.created, .delivered, .waiting, .answered, .completed],
        "answered Ask lost its lifecycle trail"
    )

    let duplicate = broker.handleAsk(
        token: sourceToken,
        target: "agy",
        text: "Which board representation should the plan use?",
        idempotencyKey: "ask-board-1"
    )
    try expect(duplicate.status == 200 && duplicate.text == result.value?.text, "idempotent Ask retry did not return the original answer")
    try expect(submissionCount.value == 1, "idempotent Ask retry submitted the question twice")

    let conflict = broker.handleAsk(
        token: sourceToken,
        target: "agy",
        text: "A different question cannot reuse this key.",
        idempotencyKey: "ask-board-1"
    )
    try expect(conflict.status == 409, "Ask accepted conflicting reuse of an idempotency key")
    try expect(submissionCount.value == 1, "conflicting Ask reuse submitted another question")
}

private func checkAskManyFansOutIndependentlyAndReturnsAnOrderedBundle() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedSubmissions()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in submissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAskMany(
            token: sourceToken,
            targets: "codex,agy",
            text: "Name the first risk you would investigate.",
            idempotencyKey: "ask-many-audit-1"
        ))
    }

    try expect(eventually { broker.consultations().count == 2 }, "ask-many did not establish both consultations concurrently")
    try expect(result.value == nil, "ask-many returned before every target answered")
    try expect(Set(submissions.values.map(\.paneID)) == Set(["%2", "%3"]), "ask-many did not submit exactly once to every explicit target")
    for submission in submissions.values {
        try expect(submission.text.contains("Name the first risk you would investigate."), "ask-many changed the shared question")
        try expect(!submission.text.contains("Codex answer") && !submission.text.contains("Agy answer"), "ask-many leaked one target's answer into another target's prompt")
    }

    let codexAnswer = broker.handleAnswer(token: codexToken, consultationID: "current", text: "Codex answer")
    try expect(codexAnswer.status == 200, "Codex could not answer its ask-many consultation")
    Thread.sleep(forTimeInterval: 0.03)
    try expect(result.value == nil, "ask-many returned before the second target answered")
    let agyAnswer = broker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy answer")
    try expect(agyAnswer.status == 200, "Agy could not answer its ask-many consultation")
    try expect(eventually { result.value != nil }, "ask-many stayed blocked after every target answered")

    let completed = try require(result.value, "ask-many produced no response")
    try expect(completed.status == 200, "successful ask-many returned a failure status")
    let data = try require(completed.text.data(using: .utf8), "ask-many response was not UTF-8")
    let json = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "ask-many response was not a JSON object")
    try expect(json["ok"] as? Bool == true, "ask-many bundle did not report success")
    let answers = try require(json["answers"] as? [[String: Any]], "ask-many bundle omitted its answers")
    try expect(answers.count == 2, "ask-many bundle returned the wrong answer count")
    try expect(answers[0]["requestedTarget"] as? String == "codex", "ask-many lost requested target ordering")
    try expect(answers[0]["targetPaneID"] as? String == "%2", "ask-many resolved Codex to the wrong pane")
    try expect(answers[0]["answer"] as? String == "Codex answer", "ask-many lost Codex's exact answer")
    try expect(answers[1]["requestedTarget"] as? String == "agy", "ask-many lost the second requested target")
    try expect(answers[1]["targetPaneID"] as? String == "%3", "ask-many resolved Agy to the wrong pane")
    try expect(answers[1]["answer"] as? String == "Agy answer", "ask-many lost Agy's exact answer")

    let retry = broker.handleAskMany(
        token: sourceToken,
        targets: "codex,agy",
        text: "Name the first risk you would investigate.",
        idempotencyKey: "ask-many-audit-1"
    )
    try expect(retry == completed, "idempotent ask-many retry changed the ordered bundle")
    try expect(submissions.values.count == 2, "idempotent ask-many retry resubmitted a question")

    let invalid = broker.handleAskMany(
        token: sourceToken,
        targets: "codex,missing",
        text: "This must not partially dispatch.",
        idempotencyKey: "ask-many-invalid-1"
    )
    try expect(invalid.status == 400 && invalid.text.contains("missing"), "ask-many did not reject an unresolved target")
    try expect(submissions.values.count == 2, "ask-many partially dispatched before validating every target")

    let duplicate = broker.handleAskMany(
        token: sourceToken,
        targets: "codex,%2",
        text: "This target appears twice.",
        idempotencyKey: "ask-many-duplicate-1"
    )
    try expect(duplicate.status == 400 && duplicate.text.contains("more than once"), "ask-many accepted two names for the same pane")
    try expect(submissions.values.count == 2, "duplicate ask-many target caused a dispatch")

    let failingBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, _ in
            if paneID == "%2" { throw CheckFailure(description: "Codex input unavailable") }
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let partialResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        partialResult.set(failingBroker.handleAskMany(
            token: sourceToken,
            targets: "codex,agy",
            text: "Preserve successful peer answers.",
            idempotencyKey: "ask-many-partial-1"
        ))
    }
    try expect(eventually { failingBroker.consultations().count == 1 }, "ask-many did not preserve the successful consultation after a peer dispatch failed")
    try expect(failingBroker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy survived").status == 200, "surviving ask-many target could not answer")
    try expect(eventually { partialResult.value != nil }, "partially failed ask-many stayed blocked")
    let partial = try require(partialResult.value, "partially failed ask-many produced no bundle")
    try expect(partial.status == 409, "partially failed ask-many did not exit non-zero")
    let partialData = try require(partial.text.data(using: .utf8), "partial ask-many response was not UTF-8")
    let partialJSON = try require(try JSONSerialization.jsonObject(with: partialData) as? [String: Any], "partial ask-many response was not JSON")
    try expect(partialJSON["ok"] as? Bool == false, "partial ask-many bundle claimed success")
    let partialAnswers = try require(partialJSON["answers"] as? [[String: Any]], "partial ask-many bundle omitted its results")
    try expect(partialAnswers[0]["status"] as? Int == 409 && partialAnswers[0]["error"] as? String != nil, "partial ask-many bundle hid the failed first target")
    try expect(partialAnswers[1]["answer"] as? String == "Agy survived", "partial ask-many bundle lost the successful second answer")
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
        result.set(broker.handleAsk(
            token: token,
            target: "agy",
            text: "Should this plan use minimax?",
            idempotencyKey: "busy-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "busy-target check never started its consultation")
    let interruptedID = try require(broker.consultations().first?.id, "busy-target consultation had no id")
    let busy = broker.handleAsk(token: token, target: "agy", text: "Can I interrupt the first question?")
    try expect(busy.status == 409 && busy.text.contains("already has a consultation"), "a second Ask interrupted a target already answering")
    broker.cancelAll(reason: "Busy-target check complete.")
    try expect(eventually { result.value != nil }, "cancelling the check left the source agent blocked")
    let interrupted = try require(broker.handoffs().first(where: { $0.id == interruptedID }), "interrupted Ask handoff disappeared")
    try expect(interrupted.state == .interrupted, "broker shutdown did not mark the Ask interrupted")
    try expect(interrupted.transitions.last?.detail == "Busy-target check complete.", "interrupted Ask lost its reason")

    let timeoutBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 0.05
    )
    let timedOut = timeoutBroker.handleAsk(
        token: token,
        target: "agy",
        text: "This should expire.",
        idempotencyKey: "timeout-ask-1"
    )
    try expect(timedOut.status == 408, "unanswered agent Ask did not time out")
    try expect(timeoutBroker.consultations().isEmpty, "expired consultation remained in the UI queue")
    let expired = try require(timeoutBroker.handoffs().first, "expired Ask produced no handoff record")
    try expect(expired.state == .failed, "expired Ask did not enter failed state")
    try expect(expired.transitions.last?.detail?.contains("timed out") == true, "expired Ask lost its timeout reason")
}

private func checkHumanCancellationUnblocksAsk() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "This question will be cancelled.",
            idempotencyKey: "cancel-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "cancellation check never established its Ask")
    let handoffID = try require(broker.consultations().first?.id, "cancellable Ask had no handoff id")

    let cancelled = broker.cancelHandoff(
        handoffID,
        reason: "Cancelled by the person using Parley."
    )

    try expect(cancelled.status == 200, "human cancellation was refused")
    try expect(eventually { result.value != nil }, "human cancellation left the requesting agent blocked")
    try expect(result.value?.status == 409 && result.value?.text.contains("Cancelled by the person") == true, "requester received no explicit cancellation reason")
    try expect(broker.consultations().isEmpty, "cancelled consultation remained active")
    let handoff = try require(broker.handoffs().first(where: { $0.id == handoffID }), "cancelled handoff disappeared")
    try expect(handoff.state == .cancelled, "human cancellation recorded the wrong terminal state")
    try expect(handoff.transitions.last?.detail == "Cancelled by the person using Parley.", "cancelled handoff lost its reason")
    try expect(handoff.transitions.last?.origin == .human, "human cancellation was indistinguishable from an automatic transition")

    let retry = broker.handleAsk(
        token: sourceToken,
        target: "agy",
        text: "This question will be cancelled.",
        idempotencyKey: "cancel-ask-1"
    )
    try expect(retry == result.value, "idempotent retry did not preserve the cancellation result")
    try expect(submissions.value == 1, "retry resubmitted a cancelled Ask")
}

private func checkSafeFailedDeliveryRetryIsStableAndDeduplicated() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let attempts = LockedCounter()
    let retryStarted = DispatchSemaphore(value: 0)
    let finishRetry = DispatchSemaphore(value: 0)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            attempts.increment()
            if attempts.value == 1 {
                throw ParleyTmuxError.unsafeRelayTarget("Codex")
            }
            retryStarted.signal()
            _ = finishRetry.wait(timeout: .now() + 2)
        }
    )

    let failed = broker.handle(
        token: sourceToken,
        target: "codex",
        text: "Review this exact patch.",
        idempotencyKey: "safe-retry-1"
    )
    let handoffID = try require(failed.body.handoffID, "failed relay returned no handoff id")
    let before = try require(broker.handoffs().first(where: { $0.id == handoffID }), "failed relay disappeared")
    try expect(before.state == .failed, "failed relay did not reach failed state")
    try expect(before.retryDisposition == .safe, "pre-input failure was not marked safe to retry")
    try expect(before.attention == .targetNotReady, "unready target did not produce explicit attention state")
    try expect(before.canRetrySafely, "safe failed relay did not expose retry capability")

    let retried = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        retried.set(broker.retryHandoff(handoffID))
    }
    try expect(retryStarted.wait(timeout: .now() + 1) == .success, "retry did not start its second delivery attempt")
    let concurrent = broker.retryHandoff(handoffID)
    try expect(concurrent.status == 409, "concurrent retry was allowed to submit a duplicate")
    finishRetry.signal()
    try expect(eventually { retried.value != nil }, "safe retry did not finish")
    try expect(retried.value?.status == 200, "safe retry returned an error")
    try expect(attempts.value == 2, "safe retry ran more than one additional delivery attempt")

    let after = try require(broker.handoffs().first(where: { $0.id == handoffID }), "retried handoff disappeared")
    try expect(broker.handoffs().count == 1, "retry created a duplicate handoff record")
    try expect(after.state == .completed, "successful retry did not complete the original handoff")
    try expect(after.retryDisposition == nil && after.attention == nil, "successful retry retained stale failure metadata")
    try expect(
        after.transitions.map(\.state) == [.created, .failed, .created, .delivered, .completed],
        "retry did not preserve one observable transition trail"
    )
    try expect(after.transitions.suffix(3).allSatisfy { $0.origin == .human }, "safe UI retry transitions were not marked as human intervention")

    let commandRetry = broker.handle(
        token: sourceToken,
        target: "codex",
        text: "Review this exact patch.",
        idempotencyKey: "safe-retry-1"
    )
    try expect(commandRetry.status == 200 && commandRetry.body.handoffID == handoffID, "later idempotent command did not reuse the retried handoff")
    try expect(attempts.value == 2, "later idempotent command submitted after a successful UI retry")
}

private func checkUncertainAndAskFailuresCannotBeRetried() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let attempts = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            attempts.increment()
            throw ParleyTmuxError.commandFailed("submit failed after paste")
        },
        consultationTimeout: 0.05
    )

    let uncertain = broker.handle(
        token: sourceToken,
        target: "codex",
        text: "Do not duplicate this.",
        idempotencyKey: "uncertain-retry-1"
    )
    let uncertainID = try require(uncertain.body.handoffID, "uncertain failure returned no handoff id")
    let uncertainHandoff = try require(broker.handoffs().first(where: { $0.id == uncertainID }), "uncertain handoff disappeared")
    try expect(uncertainHandoff.retryDisposition == .uncertain, "post-paste failure was not marked uncertain")
    try expect(!uncertainHandoff.canRetrySafely, "uncertain delivery exposed a retry capability")
    let refused = broker.retryHandoff(uncertainID)
    try expect(refused.status == 409 && refused.text.contains("cannot safely retry"), "uncertain delivery retry was not clearly refused")
    try expect(attempts.value == 1, "refused uncertain retry invoked delivery again")

    let ask = broker.handleAsk(
        token: sourceToken,
        target: "codex",
        text: "This Ask fails before submission.",
        idempotencyKey: "ask-retry-unsupported-1"
    )
    try expect(ask.status == 409, "failing Ask fixture unexpectedly succeeded")
    let askHandoff = try require(broker.handoffs().first(where: { $0.idempotencyKey == "ask-retry-unsupported-1" }), "failed Ask disappeared")
    try expect(askHandoff.retryDisposition == .unsupported, "failed Ask did not explicitly refuse UI retry")
    try expect(broker.retryHandoff(askHandoff.id).status == 409, "failed Ask was retried without a waiting requester")
}

private func checkAskDetectsDeadAndRestartedPanes() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let source = TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil)
    let target = TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil)
    let livePanes = LockedPanes([source, target])
    let broker = RelayBroker(
        credentials: credentials,
        panes: { livePanes.value },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let closedTargetResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        closedTargetResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Will the target stay open?",
            idempotencyKey: "closed-target-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "dead-target check never established its Ask")
    let closedTargetID = try require(broker.consultations().first?.id, "dead-target Ask had no handoff id")
    livePanes.set([source])
    try expect(eventually(timeout: 1) { closedTargetResult.value != nil }, "closed target left Ask blocked")
    try expect(closedTargetResult.value?.status == 410, "closed target returned the wrong failure status")
    let closedTarget = try require(broker.handoffs().first(where: { $0.id == closedTargetID }), "dead-target handoff disappeared")
    try expect(closedTarget.state == .failed && closedTarget.transitions.last?.detail?.contains("closed") == true, "dead target did not produce an explicit failed state")

    livePanes.set([source, target])
    let restartedTargetResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        restartedTargetResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Will the target restart?",
            idempotencyKey: "restart-target-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "target-restart check never established its Ask")
    let restartedTargetID = try require(broker.consultations().first?.id, "target-restart Ask had no handoff id")
    _ = try credentials.rotate("%2")
    try expect(eventually(timeout: 1) { restartedTargetResult.value != nil }, "restarted target left Ask blocked")
    try expect(restartedTargetResult.value?.status == 409, "restarted target returned the wrong failure status")
    let restartedTarget = try require(broker.handoffs().first(where: { $0.id == restartedTargetID }), "target-restart handoff disappeared")
    try expect(restartedTarget.state == .failed && restartedTarget.transitions.last?.detail?.contains("restarted") == true, "target restart did not produce an explicit failed state")

    _ = try credentials.token(for: "%2")
    livePanes.set([source, target])
    let restartedSourceResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        restartedSourceResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Will the requester restart?",
            idempotencyKey: "restart-source-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "source-restart check never established its Ask")
    let restartedSourceID = try require(broker.consultations().first?.id, "source-restart Ask had no handoff id")
    let liveSourceToken = try credentials.rotate("%1")
    try expect(eventually(timeout: 1) { restartedSourceResult.value != nil }, "restarted requester left Ask blocked")
    try expect(restartedSourceResult.value?.status == 409, "restarted requester returned the wrong interruption status")
    let restartedSource = try require(broker.handoffs().first(where: { $0.id == restartedSourceID }), "source-restart handoff disappeared")
    try expect(restartedSource.state == .interrupted && restartedSource.transitions.last?.detail?.contains("requesting pane restarted") == true, "source restart did not interrupt its Ask explicitly")

    let closedSourceResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        closedSourceResult.set(broker.handleAsk(
            token: liveSourceToken,
            target: "agy",
            text: "Will the requester stay open?",
            idempotencyKey: "closed-source-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "dead-source check never established its Ask")
    let closedSourceID = try require(broker.consultations().first?.id, "dead-source Ask had no handoff id")
    livePanes.set([target])
    try expect(eventually(timeout: 1) { closedSourceResult.value != nil }, "closed requester left Ask blocked")
    let closedSource = try require(broker.handoffs().first(where: { $0.id == closedSourceID }), "dead-source handoff disappeared")
    try expect(closedSource.state == .interrupted && closedSource.transitions.last?.detail?.contains("requesting pane closed") == true, "dead requester did not interrupt its Ask explicitly")
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
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "What should move first?"],
                environment: ProcessInfo.processInfo.environment.merging([
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
            "PARLEY_RELAY_TOKEN": targetToken,
        ]) { _, supplied in supplied },
        input: nil
    )
    try expect(answerOutput.status == 0, "parley answer failed: \(answerOutput.stderrText)")
    try expect(eventually { askResult.value != nil }, "parley ask stayed blocked after parley answer")
    try expect(askResult.value?.status == 0, "parley ask command exited unsuccessfully")
    try expect(askResult.value?.text == "Move the rules engine first.", "parley ask stdout did not become the target's exact answer")
}

private func checkAskManyShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3,
        livenessPollInterval: 0.01
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask-many", "codex,agy", "Name one concern."],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            askResult.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }

    try expect(eventually { broker.consultations().count == 2 }, "parley ask-many did not reach both targets through the filesystem transport")
    try expect(broker.handleAnswer(token: codexToken, consultationID: "current", text: "Codex concern").status == 200, "Codex shim answer failed")
    try expect(broker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy concern").status == 200, "Agy shim answer failed")
    try expect(eventually { askResult.value != nil }, "parley ask-many stayed blocked after both shim answers")
    let output = try require(askResult.value, "parley ask-many produced no shell output")
    try expect(output.status == 0, "parley ask-many command exited unsuccessfully: \(output.text)")
    try expect(output.text.contains("Codex concern") && output.text.contains("Agy concern"), "parley ask-many stdout omitted an answer")
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

private func checkCoreStartupTimeoutReportsLastPhase() throws {
    let directory = try temporaryDirectory()
    var environment = ProcessInfo.processInfo.environment
    environment["PARLEY_CORE_HANG_FIXTURE"] = "1"

    do {
        _ = try RelayCoreLauncher.ensureRunning(
            applicationDirectory: directory,
            cwd: "/tmp",
            environment: environment,
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            timeout: 0.1
        )
        throw CheckFailure(description: "hanging fixture unexpectedly became healthy")
    } catch let error as RelayCoreError {
        let detail = error.localizedDescription
        try expect(detail.contains("startup timed out"), "core timeout lost its failure reason: \(detail)")
        try expect(detail.contains("fixture reached startup"), "core timeout lost its last startup phase: \(detail)")
    }
}

private func checkCoreServiceStopsCleanly() throws {
    let directory = try temporaryDirectory()
    let stateFile = directory.appendingPathComponent("service-state")
    let process = Process()
    let finished = DispatchSemaphore(value: 0)
    var environment = ProcessInfo.processInfo.environment
    environment["PARLEY_CORE_LIFECYCLE_FIXTURE"] = stateFile.path
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    guard eventually(timeout: 2, { FileManager.default.fileExists(atPath: stateFile.path) }) else {
        process.terminate()
        throw CheckFailure(description: "lifecycle fixture never became ready")
    }
    let ready = try String(contentsOf: stateFile, encoding: .utf8)
    try expect(ready == "ready", "lifecycle fixture wrote malformed process state")

    try expect(Darwin.kill(process.processIdentifier, SIGTERM) == 0, "could not terminate lifecycle fixture")
    if finished.wait(timeout: .now() + 2) == .timedOut {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 1)
        throw CheckFailure(description: "core service did not handle SIGTERM")
    }
    process.waitUntilExit()
    try expect(process.terminationStatus == 0, "core service shutdown trapped with status \(process.terminationStatus)")
    let stopped = try String(contentsOf: stateFile, encoding: .utf8)
    try expect(stopped == "stopped \(SIGTERM)", "core service did not finish its shutdown handler")
}

private func checkVendorConformancePlanning() throws {
    let panes = [
        TmuxPane(
            id: "%1", kind: .codex, customName: "Codex active", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Codex inactive", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%4", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp",
            currentCommand: "agy", isActive: false, windowID: "@2", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "docs",
            bracketedPasteActive: true
        ),
    ]

    let plan = VendorConformancePlanner.plan(panes: panes, vendors: [.codex])
    try expect(plan.count == 1, "conformance planner did not return one result per requested vendor")
    guard case let .probe(probe) = plan[0] else {
        throw CheckFailure(description: "ready Codex panes were unexpectedly skipped")
    }
    try expect(probe.target.id == "%2", "conformance planner did not prefer an inactive target")
    try expect(probe.source.id == "%3", "conformance planner did not select the first stable cross-workspace source")
    try expect(probe.testsInactiveTarget, "conformance probe lost inactive-pane coverage")
    try expect(probe.testsCrossWorkspace, "conformance probe lost cross-workspace coverage")
    try expect(probe.source.kind != probe.target.kind, "conformance planner selected a same-vendor source")
}

private func checkVendorConformancePlanningFailsClosed() throws {
    let panes = [
        TmuxPane(
            id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Stale Codex", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: "0", workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%3", kind: .agy, customName: "Unready Agy", terminalTitle: "", cwd: "/tmp",
            currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: false
        ),
    ]

    let plan = VendorConformancePlanner.plan(panes: panes, vendors: [.codex, .agy, .copilot])
    try expect(plan.count == 3, "conformance planner omitted requested vendors")
    guard case let .skipped(_, codexReason) = plan[0] else {
        throw CheckFailure(description: "stale Codex pane was accepted for a live probe")
    }
    guard case let .skipped(_, agyReason) = plan[1] else {
        throw CheckFailure(description: "non-bracketed Agy pane was accepted for a live probe")
    }
    guard case let .skipped(_, copilotReason) = plan[2] else {
        throw CheckFailure(description: "missing Copilot pane was accepted for a live probe")
    }
    try expect(codexReason.contains("protocol"), "stale pane skip did not explain its protocol failure")
    try expect(agyReason.contains("bracketed paste"), "unready pane skip did not explain its input failure")
    try expect(copilotReason.contains("No open"), "missing vendor skip did not explain what to open")
}

private func checkVendorConformanceRejectsExitedPanes() throws {
    let panes = [
        TmuxPane(
            id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Exited Codex", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
            bracketedPasteActive: true, isDead: true, exitStatus: 7
        ),
    ]

    let plan = VendorConformancePlanner.plan(panes: panes, vendors: [.codex])
    guard case let .skipped(_, reason) = plan[0] else {
        throw CheckFailure(description: "exited Codex pane was accepted for a live probe")
    }
    try expect(reason.contains("exited"), "exited pane skip did not explain its process state")
}

private func checkVendorConformanceReport() throws {
    let results = [
        VendorConformanceResult(vendor: .claude, check: "round trip", outcome: .passed, detail: "exact response"),
        VendorConformanceResult(vendor: .codex, check: "cross-workspace", outcome: .notExercised, detail: "one workspace"),
        VendorConformanceResult(vendor: .copilot, check: "trust gate", outcome: .blocked, detail: "folder trust is waiting"),
        VendorConformanceResult(vendor: .agy, check: "round trip", outcome: .failed, detail: "wrong response"),
    ]
    let report = VendorConformanceReport(results: results)
    let rendered = report.rendered()

    try expect(report.hasFailures, "failed conformance result did not fail the report")
    try expect(report.hasBlockedChecks, "blocked conformance result was hidden")
    try expect(rendered.contains("PASS Claude — round trip: exact response"), "report omitted passing evidence")
    try expect(rendered.contains("SKIP Codex — cross-workspace: one workspace"), "report disguised an unexercised check")
    try expect(rendered.contains("BLOCKED Copilot — trust gate: folder trust is waiting"), "report disguised a blocked check")
    try expect(rendered.contains("FAIL Agy — round trip: wrong response"), "report omitted failure detail")
    try expect(rendered.contains("1 passed, 1 failed, 1 blocked, 1 not exercised"), "report summary counts are wrong")
}

private func checkVendorConformanceAttentionGate() throws {
    let trust = VendorConformanceAttention.blockedReason(
        kind: .copilot,
        visibleText: "Confirm folder trust\nDo you trust the files in this folder?"
    )
    let permission = VendorConformanceAttention.blockedReason(
        kind: .claude,
        visibleText: "Would you like to run the following command?\nAllow once"
    )
    let ready = VendorConformanceAttention.blockedReason(
        kind: .codex,
        visibleText: "Ask Codex to do anything"
    )

    try expect(trust?.kind == .trust, "folder trust prompt was not recognized")
    try expect(permission?.kind == .permission, "tool permission prompt was not recognized")
    try expect(ready == nil, "normal agent prompt was incorrectly blocked")
}

let checks: [(String, () throws -> Void)] = [
    ("bootstrap", checkBootstrap),
    ("existing session workspace adoption", checkExistingSessionAdoptsWorkspaceWithoutRestart),
    ("workspace lifecycle", checkWorkspaceLifecycle),
    ("workspace continuity state", checkWorkspaceContinuityState),
    ("Git project context parsing", checkGitProjectContextParsing),
    ("command palette search", checkCommandPaletteSearch),
    ("workbench accessibility descriptions", checkAccessibilityDescriptions),
    ("adjacent navigation order", checkAdjacentNavigationOrder),
    ("workbench state projection", checkWorkbenchStateProjection),
    ("exited pane retention", checkExitedPaneRetention),
    ("saved workspace layout persistence and fresh slots", checkSavedWorkspaceLayoutPersistenceAndFreshSlots),
    ("tmux layout to ID-free saved tree", checkTmuxLayoutBecomesAnIDFreeSavedTree),
    ("active pane workspace scope", checkActivePaneIsScopedToSelectedWorkspace),
    ("direct agent argv", checkDirectAgentSpawn),
    ("stopped agent explicit start", checkStoppedAgentStartsOnlyThroughExplicitAction),
    ("shell pane login shell", checkShellPaneStartsLoginShell),
    ("real tmux shell lifecycle", checkRealTmuxShellLifecycle),
    ("real tmux saved-layout restoration policy", checkRealTmuxSavedLayoutRestorationPolicy),
    ("inherited Parley capability scrub", checkInheritedParleyCapabilitiesAreScrubbed),
    ("shared protocol launch adapters", checkSharedProtocolLaunchAdapters),
    ("tracked delegation completion and wait", checkTrackedDelegationCompletesAndWaits),
    ("tracked delegation failure and liveness", checkTrackedDelegationFailureAndLiveness),
    ("tracked delegation shim round trip", checkDelegationShimRoundTrip),
    ("Copilot agent argv", checkCopilotAgentSpawn),
    ("Copilot trusted submission", checkCopilotSubmitUsesEnterAfterTrust),
    ("Copilot folder trust gate", checkCopilotTrustPromptRefusesSubmission),
    ("safe relay target gate", checkPasteRequiresRelayReadyBracketedTarget),
    ("Ask and route", checkAsk),
    ("Return and consume route", checkReturn),
    ("cross-vendor guard", checkCrossVendorGuard),
    ("relay cleaning", checkRelayCleaning),
    ("selection-or-empty relay draft", checkRelayDraftStartsWithSelectionOrNothing),
    ("bounded shell-free review drafts", checkReviewDraftsAreBoundedShellFreeAndExplicit),
    ("authoritative Status Center projection", checkStatusCenterProjectionUsesOnlyAuthoritativeState),
    ("durable authoritative operational activity", checkOperationalActivityIsDurableAndAuthoritative),
    ("agent relay submits; paste does not", checkAgentRelaySubmitsAndExplicitPasteDoesNot),
    ("stable handoff identity and idempotent relay", checkStableHandoffIdentityAndIdempotentRelay),
    ("completed handoff retention bound", checkCompletedHandoffRetentionIsBounded),
    ("durable handoff journal", checkDurableHandoffJournal),
    ("workspace handoff history deletion", checkWorkspaceHandoffHistoryDeletion),
    ("cross-workspace relay addressing", checkCrossWorkspaceRelayAddressing),
    ("persistent relay identity", checkRelayCredentialPersistsAndIdentifiesSender),
    ("cross-process relay identity refresh", checkRelayCredentialReloadsExternalChanges),
    ("restart rotates relay credential", checkRestartRotatesRelayCredential),
    ("relay filesystem round trip", checkRelayFilesystemRoundTrip),
    ("relay shim filesystem transport", checkRelayShimUsesPinnedFilesystemTransport),
    ("protected filesystem relay runtime", checkRelayFilesystemRuntimeIsProtectedAndStopsCleanly),
    ("complete large core activity response", checkLargeCoreActivityResponseIsComplete),
    ("core control survives UI reattachment", checkCoreControlSurvivesClientReattachment),
    ("persistent core process survives UI exit", checkPersistentCoreProcessSurvivesClientExit),
    ("core restart interrupts wait and recovers", checkCoreRestartInterruptsWaitAndRecoversDiscovery),
    ("safe stable relay shim", checkStableShimInstallationDoesNotOverwriteForeignCommands),
    ("agent Ask auto-submits and returns", checkAgentAskSubmitsAndBlocksUntilTheTargetAnswers),
    ("ask-many independent ordered fanout", checkAskManyFansOutIndependentlyAndReturnsAnOrderedBundle),
    ("agent Ask busy target and timeout", checkAgentAskRejectsBusyTargetAndTimesOut),
    ("human Ask cancellation", checkHumanCancellationUnblocksAsk),
    ("safe failed-delivery retry", checkSafeFailedDeliveryRetryIsStableAndDeduplicated),
    ("uncertain and Ask retry refusal", checkUncertainAndAskFailuresCannotBeRetried),
    ("Ask dead-pane and target-restart recovery", checkAskDetectsDeadAndRestartedPanes),
    ("consultation shim round trip", checkConsultationShimRoundTrip),
    ("ask-many shim round trip", checkAskManyShimRoundTrip),
    ("child-process timeout", checkCommandTimeout),
    ("core startup timeout diagnostics", checkCoreStartupTimeoutReportsLastPhase),
    ("core service lifecycle", checkCoreServiceStopsCleanly),
    ("vendor conformance planning", checkVendorConformancePlanning),
    ("vendor conformance planning fails closed", checkVendorConformancePlanningFailsClosed),
    ("vendor conformance rejects exited panes", checkVendorConformanceRejectsExitedPanes),
    ("vendor conformance reporting", checkVendorConformanceReport),
    ("vendor conformance attention gate", checkVendorConformanceAttentionGate),
]

if let statePath = ProcessInfo.processInfo.environment["PARLEY_CORE_LIFECYCLE_FIXTURE"] {
    do {
        try "ready".write(toFile: statePath, atomically: true, encoding: .utf8)
        RelayServiceProcess.waitForTermination { signalNumber in
            try? "stopped \(signalNumber)".write(toFile: statePath, atomically: true, encoding: .utf8)
            exit(0)
        }
    } catch {
        FileHandle.standardError.write(Data("Lifecycle fixture failed: \(error)\n".utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["PARLEY_CORE_HANG_FIXTURE"] == "1" {
    FileHandle.standardError.write(Data("fixture reached startup\n".utf8))
    Thread.sleep(forTimeInterval: 5)
    exit(0)
}

if ProcessInfo.processInfo.environment["PARLEY_UI_FIXTURE"] == "1" {
    do {
        try runUIFixture()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Fixture UI failed: \(error)\n".utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["PARLEY_CORE_FIXTURE"] == "1" {
    do {
        try runCoreServiceFixture()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Fixture core failed: \(error)\n".utf8))
        exit(1)
    }
}

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
