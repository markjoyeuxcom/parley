import Foundation
import ParleyCore

// Operations over several panes that could stop part-way (Agy's review of
// MR 106, Prax d8758cc9): each either completes or changes nothing.

private func atomicExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "MultiPaneAtomicity", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class AtomicFixture {
    let root = URL(fileURLWithPath: "/private/tmp/parley-atomic-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    var project: URL { root.appendingPathComponent("project") }
    var runtime: URL { root.appendingPathComponent("runtime") }
    var secrets: URL { root.appendingPathComponent("secrets") }
    let controller: WorkbenchController
    let credentials: RelayCredentials
    final class Ended: @unchecked Sendable { var ids: [String] = []; var all = 0 }
    let ended = Ended()

    init() throws {
        let root = root
        // A failure here would otherwise leave the folder behind: the caller's
        // cleanup is deferred only once the fixture exists.
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("secrets"), withIntermediateDirectories: true)
            controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
            try controller.bootstrap(cwd: root.appendingPathComponent("project").path)
            // The credentials live apart from the workbench state, so each can
            // be made unwritable on its own.
            credentials = try RelayCredentials(file: root.appendingPathComponent("secrets/relay-tokens.json"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        controller.configureRelay(RelayRuntime(infoFile: root.appendingPathComponent("runtime/relay-url"), shimDirectory: root.appendingPathComponent("runtime/bin"),
            transportDirectory: root.appendingPathComponent("runtime/relay"), credentials: credentials, runtimeMarker: "DEV"))
        let ended = ended
        controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, interrupt: { _ in }, captureSelectedText: { _ in "" },
            terminate: { ended.ids.append($0) }, terminateAll: { ended.all += 1 }))
    }

    func writable(_ folder: URL, _ allowed: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: allowed ? 0o755 : 0o555], ofItemAtPath: folder.path)
    }

    /// A workspace holding its seeded shell and two more, each pane with a
    /// stored credential.
    func workspaceWithPanes() throws -> (workspaceID: String, paneIDs: [String]) {
        let workspace = try controller.createWorkspace(folder: project.path)
        _ = try controller.createPane(kind: .shell, cwd: project.path)
        _ = try controller.createPane(kind: .shell, cwd: project.path)
        let ids = try controller.listPanes().filter { $0.workspaceID == workspace.workspaceID }.map(\.id)
        guard ids.count == 3 else {
            throw NSError(domain: "MultiPaneAtomicity", code: 3, userInfo: [NSLocalizedDescriptionKey: "the fixture workspace holds \(ids.count) panes"])
        }
        for id in ids { _ = try credentials.token(for: id) }
        return (workspace.workspaceID, ids)
    }

    func cleanup() {
        try? writable(runtime, true)
        try? writable(secrets, true)
        try? FileManager.default.removeItem(at: root)
    }
}

/// closeWorkspace ended each pane's surface and then forgot its credential,
/// so a credential store that could not be written stopped it with earlier
/// panes ended and the workspace still listed; a state file that could not
/// be written did the same after every pane had ended.
func checkClosingAWorkspaceIsAllOrNothing() throws {
    let f = try AtomicFixture(); defer { f.cleanup() }
    let unsaved = try f.workspaceWithPanes()
    try f.writable(f.runtime, false)
    var refused = false
    do { try f.controller.closeWorkspace(unsaved.workspaceID) } catch { refused = true }
    try f.writable(f.runtime, true)
    try atomicExpect(refused, "a close whose state could not be saved reported success")
    try atomicExpect(f.ended.ids.isEmpty, "a close that could not be saved ended \(f.ended.ids)")
    try atomicExpect(try f.controller.listWorkspaces().contains { $0.workspaceID == unsaved.workspaceID }
                     && (try f.controller.listPanes()).filter { $0.workspaceID == unsaved.workspaceID }.map(\.id) == unsaved.paneIDs,
                     "a close that could not be saved changed the workspace")

    try f.writable(f.secrets, false)
    try f.controller.closeWorkspace(unsaved.workspaceID)
    try f.writable(f.secrets, true)
    try atomicExpect(!(try f.controller.listWorkspaces()).contains { $0.workspaceID == unsaved.workspaceID }, "the closed workspace is still listed")
    try atomicExpect(Set(f.ended.ids) == Set(unsaved.paneIDs), "the closed workspace's panes were not all ended: \(f.ended.ids)")
}

/// shutdown ended every surface before it forgot the credentials or saved
/// the state, so either failure kept Parley open with every pane gone and
/// no way to start another.
func checkShuttingDownIsAllOrNothing() throws {
    let f = try AtomicFixture(); defer { f.cleanup() }
    _ = try f.workspaceWithPanes()
    try f.writable(f.runtime, false)
    var refused = false
    do { try f.controller.shutdown() } catch { refused = true }
    try f.writable(f.runtime, true)
    try atomicExpect(refused, "a shutdown whose state could not be saved reported success")
    try atomicExpect(f.ended.all == 0, "a shutdown that could not be saved ended every surface")
    _ = try f.controller.createPane(kind: .shell, cwd: f.project.path)

    try f.writable(f.secrets, false)
    try f.controller.shutdown()
    try f.writable(f.secrets, true)
    try atomicExpect(f.ended.all == 1, "the shutdown did not end the surfaces")
    try atomicExpect(try f.controller.listPanes().allSatisfy { !$0.isStarted }, "a pane still reads started after shutdown")
}

/// Each operation checks every pane before it changes anything and then ends
/// the surfaces. Re-checking at that point read the changed state: a
/// container placeholder's confirmed stop names the generation shutdown has
/// just advanced, so the re-check refused and nothing was ended.
func checkShuttingDownWithAStoppedContainerEndsTheSurfaces() throws {
    let f = try AtomicFixture(); defer { f.cleanup() }
    let configuration = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "c", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let placeholder = try f.controller.createPane(kind: .codex, cwd: f.project.path, containerConfiguration: configuration)
    try atomicExpect(!placeholder.isStarted, "the fixture's container pane started")
    try f.controller.shutdown()
    try atomicExpect(f.ended.all == 1, "a shutdown with a stopped container pane ended no surface")
}

/// movePane changed the document and then saved it, with no rollback: a save
/// that failed left the pane moved in memory though not on disk.
func checkAMoveThatCannotBeSavedChangesNothing() throws {
    let f = try AtomicFixture(); defer { f.cleanup() }
    let source = try f.workspaceWithPanes()
    let target = try f.controller.createWorkspace(folder: f.project.path)
    let before = try f.controller.listPanes()
    try f.writable(f.runtime, false)
    var refused = false
    do { _ = try f.controller.movePane(source.paneIDs[0], toWorkspaceID: target.workspaceID, activeHandoffCount: 0) } catch { refused = true }
    try f.writable(f.runtime, true)
    try atomicExpect(refused, "a move whose state could not be saved reported success")
    let after = try f.controller.listPanes()
    try atomicExpect(after.first { $0.id == source.paneIDs[0] }?.workspaceID == source.workspaceID,
                     "a move that could not be saved left the pane in the other workspace")
    try atomicExpect(after.map(\.isActive) == before.map(\.isActive), "a move that could not be saved changed which pane is active")
}

/// The single-pane routes have the same shape (Agy's review of MR 106 named
/// the multi-pane ones; the fresh-context review of this change found these):
/// closePane and stopPaneProcess ended the surface and then saved, so a state
/// file or credential store that could not be written left the pane gone or
/// stopped in memory while the error said it was not; startPane and the
/// creation routes left a pane listed as started or present that the saved
/// state never held, and a surface would mount for it.
func checkSinglePaneLifecycleIsAllOrNothing() throws {
    let f = try AtomicFixture(); defer { f.cleanup() }
    let workspace = try f.workspaceWithPanes()
    let shell = workspace.paneIDs[1]

    // Close: a save that fails changes nothing and ends nothing.
    try f.writable(f.runtime, false)
    var refused = false
    do { try f.controller.closePane(shell) } catch { refused = true }
    try f.writable(f.runtime, true)
    try atomicExpect(refused, "a close whose state could not be saved reported success")
    try atomicExpect(f.ended.ids.isEmpty, "a close that could not be saved ended \(f.ended.ids)")
    try atomicExpect(try f.controller.listPanes().contains { $0.id == shell }, "a close that could not be saved removed the pane")
    // A credential that cannot be forgotten no longer stops a saved close.
    try f.writable(f.secrets, false)
    try f.controller.closePane(shell)
    try f.writable(f.secrets, true)
    try atomicExpect(f.ended.ids == [shell], "the closed pane's surface was not ended: \(f.ended.ids)")
    try atomicExpect(!(try f.controller.listPanes()).contains { $0.id == shell }, "the closed pane is still listed")
    f.ended.ids.removeAll()

    // Stop: the same for a started agent pane.
    let agent = try f.controller.createPane(kind: .codex, cwd: f.project.path)
    _ = try f.credentials.token(for: agent.id)
    try atomicExpect(agent.isStarted, "the fixture's agent pane did not start")
    try f.writable(f.runtime, false)
    refused = false
    do { try f.controller.stopPaneProcess(agent.id, expectedGeneration: agent.launchGeneration) } catch { refused = true }
    try f.writable(f.runtime, true)
    try atomicExpect(refused, "a stop whose state could not be saved reported success")
    try atomicExpect(f.ended.ids.isEmpty, "a stop that could not be saved ended \(f.ended.ids)")
    let unstopped = try f.controller.listPanes().first { $0.id == agent.id }
    try atomicExpect(unstopped?.isStarted == true && unstopped?.launchGeneration == agent.launchGeneration,
                     "a stop that could not be saved changed the pane: \(String(describing: unstopped))")
    try f.writable(f.secrets, false)
    try f.controller.stopPaneProcess(agent.id, expectedGeneration: agent.launchGeneration)
    try f.writable(f.secrets, true)
    try atomicExpect(f.ended.ids == [agent.id], "the stopped pane's surface was not ended: \(f.ended.ids)")
    let stopped = try f.controller.listPanes().first { $0.id == agent.id }
    try atomicExpect(stopped?.isStarted == false, "the stopped pane still reads started")

    // Start: a save that fails leaves the pane stopped at its generation.
    try f.writable(f.runtime, false)
    refused = false
    do { try f.controller.startPane(agent.id) } catch { refused = true }
    try f.writable(f.runtime, true)
    try atomicExpect(refused, "a start whose state could not be saved reported success")
    let unstarted = try f.controller.listPanes().first { $0.id == agent.id }
    try atomicExpect(unstarted?.isStarted == false && unstarted?.launchGeneration == stopped?.launchGeneration,
                     "a start that could not be saved left the pane started: \(String(describing: unstarted))")
    try f.controller.startPane(agent.id)
    try atomicExpect(try f.controller.listPanes().first { $0.id == agent.id }?.isStarted == true, "the pane did not start once the state could be saved")

    // Creation: nothing a failed save did not hold is listed.
    let panesBefore = try f.controller.listPanes().map(\.id)
    let workspacesBefore = try f.controller.listWorkspaces().map(\.workspaceID)
    try f.writable(f.runtime, false)
    var created: [String] = []
    if (try? f.controller.createPane(kind: .shell, cwd: f.project.path)) != nil { created.append("pane") }
    if (try? f.controller.createWorkspace(folder: f.project.path)) != nil { created.append("workspace") }
    if (try? f.controller.createFolderlessWorkspace(launchFolder: f.project.path)) != nil { created.append("folderless workspace") }
    try f.writable(f.runtime, true)
    try atomicExpect(created.isEmpty, "creation whose state could not be saved reported success: \(created)")
    try atomicExpect(try f.controller.listPanes().map(\.id) == panesBefore, "a creation that could not be saved left a pane listed")
    try atomicExpect(try f.controller.listWorkspaces().map(\.workspaceID) == workspacesBefore, "a creation that could not be saved left a workspace listed")
}

/// Close stopped team panes stopped at the first pane that failed to close
/// and skipped the refresh; the rest stayed open and nothing said why.
func checkClosingStoppedTeamPanesContinuesPastAFailure() throws {
    var placeholders: [WorkbenchPane] = []
    for id in ["one", "two", "three"] {
        placeholders.append(WorkbenchPane(id: id, kind: .codex, customName: id, terminalTitle: "", cwd: "/tmp", currentCommand: "stopped",
            isActive: false, workspaceID: "w", relayEnabled: false, workspaceName: "W", launchGeneration: 2))
    }
    var closed: [String] = []
    let outcome = TeamPlaceholderClosing.close(placeholders,
        stillStopped: { id in id != "gone" },
        close: { id in
            if id == "two" { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture close failure"]) }
            closed.append(id)
        })
    try atomicExpect(closed == ["one", "three"], "closing stopped at the failure: closed \(closed)")
    try atomicExpect(outcome.closed == ["one", "three"] && outcome.failed.map(\.paneID) == ["two"]
                     && outcome.failed.first?.reason.contains("fixture close failure") == true, "the outcome misreports: \(outcome)")
    let skipped = TeamPlaceholderClosing.close(placeholders, stillStopped: { $0 != "one" }, close: { _ in })
    try atomicExpect(skipped.skipped == ["one"] && skipped.closed == ["two", "three"], "a pane restarted meanwhile was not skipped: \(skipped)")
    // A state that cannot be read is a failure with its reason, never a skip
    // that says the pane was restarted.
    let unreadable = TeamPlaceholderClosing.close(placeholders, stillStopped: { id in
        if id == "one" { throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture unreadable state"]) }
        return true
    }, close: { _ in })
    try atomicExpect(unreadable.skipped.isEmpty && unreadable.failed.map(\.paneID) == ["one"] && unreadable.closed == ["two", "three"]
                     && unreadable.failed.first?.reason.contains("fixture unreadable state") == true, "an unreadable state misreported: \(unreadable)")

    // The app runs its closing through this and refreshes whatever happened.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ParleyNative/AppModel.swift")
    let reader = SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
    guard let found = reader.text.range(of: "func closeStoppedTeamPanes("),
          let open = reader.text[found.upperBound...].firstIndex(of: "{"), let body = reader.balanced(at: open) else {
        throw NSError(domain: "MultiPaneAtomicity", code: 2, userInfo: [NSLocalizedDescriptionKey: "closeStoppedTeamPanes was not found"])
    }
    try atomicExpect(body.contains("TeamPlaceholderClosing.close(") && !body.contains("for pane in candidates"),
                     "Close stopped team panes still stops at its first failure")
    try atomicExpect(body.contains("do { try refresh() } catch") && !body.contains("try? refresh()"),
                     "Close stopped team panes does not refresh after a failure, or hides a refresh that failed")
}

@MainActor let multiPaneAtomicityChecks: [(String, () throws -> Void)] = [
    ("closing a workspace is all or nothing", checkClosingAWorkspaceIsAllOrNothing),
    ("shutting down is all or nothing", checkShuttingDownIsAllOrNothing),
    ("shutting down with a stopped container pane ends the surfaces", checkShuttingDownWithAStoppedContainerEndsTheSurfaces),
    ("a move that cannot be saved changes nothing", checkAMoveThatCannotBeSavedChangesNothing),
    ("single-pane close, stop, start and creation are all or nothing", checkSinglePaneLifecycleIsAllOrNothing),
    ("closing stopped team panes continues past a failure", checkClosingStoppedTeamPanesContinuesPastAFailure),
]
