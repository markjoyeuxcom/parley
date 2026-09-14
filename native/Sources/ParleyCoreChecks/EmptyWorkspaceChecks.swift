import Foundation
import ParleyCore

private func emptyExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "EmptyWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A workspace may hold no panes: New Workspace creates none, closing the
/// last pane leaves the workspace, moving the last pane out empties its
/// source, and a saved document with empty workspaces reloads as it was.
/// The gestures that ask for a place to work, a fresh install and Open
/// Folder, still seed one shell; the last workspace still cannot close.
func checkEmptyWorkspaces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-empty-workspace-\(UUID().uuidString)")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    let runtime = root.appendingPathComponent("runtime")
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try controller.bootstrap(cwd: root.path)

    try emptyExpect(try controller.listWorkspaces().count == 1 && (try controller.listPanes()).count == 1, "a fresh workbench did not seed one shell")
    let seededWorkspace = try controller.listWorkspaces()[0].workspaceID

    let empty = try controller.createFolderlessWorkspace(launchFolder: root.path)
    try emptyExpect((try controller.listPanes()).allSatisfy { $0.workspaceID != empty.workspaceID }, "New Workspace created a pane")
    try emptyExpect((try controller.listWorkspaces()).first(where: \.isActive)?.workspaceID == empty.workspaceID, "the new empty workspace is not active")
    try emptyExpect(try controller.activePane() == nil, "an empty workspace reports an active pane")

    let first = try controller.createPane(kind: .shell, cwd: root.path)
    try emptyExpect(first.workspaceID == empty.workspaceID && (try controller.activePane())?.id == first.id, "the first pane did not land in the empty workspace as its active pane")
    try controller.closePane(first.id)
    try emptyExpect((try controller.listWorkspaces()).contains { $0.workspaceID == empty.workspaceID }, "closing the last pane removed its workspace")
    try emptyExpect((try controller.listPanes()).allSatisfy { $0.workspaceID != empty.workspaceID }, "a closed pane lingered")
    try emptyExpect(try controller.activePane() == nil, "an emptied workspace kept an active pane")

    let opened = try controller.createWorkspace(folder: project.path)
    let openedPanes = try controller.listPanes().filter { $0.workspaceID == opened.workspaceID }
    try emptyExpect(openedPanes.count == 1 && openedPanes[0].kind == .shell, "Open Folder did not seed one shell")

    // Moving the last pane out is allowed by the policy and by the controller.
    let assessment = PaneMobilityPolicy.assess(action: .move, pane: openedPanes[0], targetWorkspaceID: empty.workspaceID,
        panes: try controller.listPanes(), activeHandoffCount: 0)
    try emptyExpect(assessment.isAllowed, "moving the last pane is refused: \(assessment.refusalText)")
    let moved = try controller.movePane(openedPanes[0].id, toWorkspaceID: empty.workspaceID, activeHandoffCount: 0)
    try emptyExpect(moved.workspaceID == empty.workspaceID, "the pane did not move")
    try emptyExpect((try controller.listWorkspaces()).contains { $0.workspaceID == opened.workspaceID }
        && (try controller.listPanes()).allSatisfy { $0.workspaceID != opened.workspaceID }, "moving the last pane out did not leave an empty source workspace")
    let busy = PaneMobilityPolicy.assess(action: .move, pane: moved, targetWorkspaceID: opened.workspaceID, panes: try controller.listPanes(), activeHandoffCount: 1)
    try emptyExpect(!busy.isAllowed, "an active handoff no longer blocks a move")

    // Every pane in the app may close; the last workspace may not.
    for pane in try controller.listPanes() { try controller.closePane(pane.id) }
    try emptyExpect((try controller.listPanes()).isEmpty && (try controller.listWorkspaces()).count == 3, "closing every pane changed the workspaces")
    try controller.closeWorkspace(seededWorkspace)
    try controller.closeWorkspace(opened.workspaceID)
    do { try controller.closeWorkspace(empty.workspaceID); throw NSError(domain: "the last workspace closed", code: 1) }
    catch let error as ParleyWorkbenchError { try emptyExpect("\(error)".contains("cannotCloseLastWorkspace"), "the last workspace was refused for another reason: \(error)") }

    // A document with a workspace and no panes is not a fresh workbench.
    try controller.shutdown()
    let reopened = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try reopened.bootstrap(cwd: root.path)
    let workspaces = try reopened.listWorkspaces()
    try emptyExpect(workspaces.count == 1 && workspaces[0].workspaceID == empty.workspaceID && (try reopened.listPanes()).isEmpty,
        "an empty workspace did not survive a relaunch: \(workspaces.map(\.name)) with \((try reopened.listPanes()).count) panes")
    try reopened.shutdown()
}

@MainActor
let emptyWorkspaceChecks: [(String, () throws -> Void)] = [
    ("a workspace may hold no panes: creation, close, move and relaunch", checkEmptyWorkspaces),
]
