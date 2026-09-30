import Foundation
import ParleyCore

// Workspace groups (Mark's decision, 30 September 2026, MR 2 of Prax
// 9dd56387): All Workspaces lists his own named groups, each workspace in
// exactly one group or Ungrouped.

private func groupExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorkspaceGroups", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func checkWorkspaceGroupSections() throws {
    let groups = [
        WorkspaceGroup(id: "g1", name: "Clients"),
        WorkspaceGroup(id: "g2", name: "Personal", isCollapsed: true),
        WorkspaceGroup(id: "g3", name: "Empty"),
    ]
    var workspaces = (0..<10).map { WorkbenchWorkspace(id: "w\($0)", name: "W\($0)", isActive: $0 == 0, workspaceID: "w\($0)") }
    workspaces[4].groupID = "g1"
    workspaces[1].groupID = "g1"
    workspaces[2].groupID = "g2"
    workspaces[7].groupID = "gone" // a group that no longer exists
    let sections = WorkspaceSidebarSections.derive(workspaces: workspaces, groups: groups, needsPerson: { _ in 0 })
    try groupExpect(sections.groups.map(\.id) == ["g1", "g2", "g3"], "groups are not in their order: \(sections.groups.map(\.id))")
    try groupExpect(sections.groups[0].workspaces == ["w1", "w4"], "a group's workspaces are not in the workspace order")
    try groupExpect(sections.groups[1].isCollapsed && sections.groups[1].workspaces == ["w2"] && sections.groups[1].name == "Personal",
                    "a collapsed group lost its state or members")
    try groupExpect(sections.groups[2].workspaces.isEmpty, "an empty group is not listed, so it could not be deleted")
    try groupExpect(sections.ungrouped == ["w0", "w3", "w5", "w6", "w7", "w8", "w9"],
                    "ungrouped: \(sections.ungrouped); a workspace naming a missing group belongs there")
    try groupExpect(sections.all == workspaces.map(\.workspaceID), "All no longer lists every workspace in order")

    let plain = WorkspaceSidebarSections.derive(workspaces: workspaces, groups: [], needsPerson: { _ in 0 })
    try groupExpect(plain.groups.isEmpty && plain.ungrouped == plain.all, "with no groups every workspace is not simply listed")

    // Dragging within a group reorders the whole workspace order.
    let all = workspaces.map(\.workspaceID)
    try groupExpect(WorkspaceSidebarSections.subsetMove(source: 1, destination: 0, subset: ["w1", "w4"], all: all)! == (4, 1),
                    "moving w4 above w1 within the group")
    try groupExpect(WorkspaceSidebarSections.subsetMove(source: 0, destination: 2, subset: ["w1", "w4"], all: all)! == (1, 5),
                    "moving w1 below w4 within the group")

    // Names: "Ungrouped" is the sidebar's own; format characters (emoji
    // joiners, direction marks) are text, while a real control character is not.
    for reserved in ["Ungrouped", " ungrouped "] {
        if case .success = WorkspaceGroup.validatedName(reserved, among: []) { throw NSError(domain: "WorkspaceGroups", code: 3, userInfo: [NSLocalizedDescriptionKey: "a group could be named \(reserved)"]) }
    }
    for accepted in ["Team \u{1F469}\u{200D}\u{1F4BB}", "Client \u{200E}A", "Café"] {
        guard case .success = WorkspaceGroup.validatedName(accepted, among: []) else {
            throw NSError(domain: "WorkspaceGroups", code: 3, userInfo: [NSLocalizedDescriptionKey: "a name with format characters was refused: \(accepted.unicodeScalars.map { String($0.value, radix: 16) })"])
        }
    }
    if case .success = WorkspaceGroup.validatedName("Bell\u{7}", among: []) {
        throw NSError(domain: "WorkspaceGroups", code: 3, userInfo: [NSLocalizedDescriptionKey: "a name with a control character was accepted"])
    }
    // One group record missing its collapsed state must not stop the whole file loading.
    let partial = try JSONDecoder().decode(WorkspaceGroup.self, from: Data(#"{"id":"g","name":"Work"}"#.utf8))
    try groupExpect(partial.name == "Work" && !partial.isCollapsed, "a group record without isCollapsed did not decode as expanded")
}

func checkWorkspaceGroupsPersistAndRollBack() throws {
    let root = URL(fileURLWithPath: "/private/tmp/parley-groups-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    let runtime = root.appendingPathComponent("runtime")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        try? FileManager.default.removeItem(at: root)
    }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try controller.bootstrap(cwd: project.path)
    let a = try controller.createWorkspace(folder: project.path, name: "A")
    let b = try controller.createWorkspace(folder: project.path, name: "B")
    func workspace(_ id: String) throws -> WorkbenchWorkspace? { try controller.listWorkspaces().first { $0.workspaceID == id } }
    func refuses(_ what: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "WorkspaceGroups", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(what) was accepted"])
    }

    let clients = try controller.createWorkspaceGroup(name: " Clients ", moving: a.workspaceID)
    try groupExpect(clients.name == "Clients" && (try workspace(a.workspaceID))?.groupID == clients.id,
                    "creating a group from a workspace did not trim its name or move the workspace into it")
    try refuses("a second group named clients") { _ = try controller.createWorkspaceGroup(name: "clients", moving: nil) }
    try refuses("an empty group name") { _ = try controller.createWorkspaceGroup(name: "   ", moving: nil) }
    try refuses("a group name with a line break") { _ = try controller.createWorkspaceGroup(name: "Two\nLines", moving: nil) }
    try refuses("a 65-character group name") { _ = try controller.createWorkspaceGroup(name: String(repeating: "x", count: 65), moving: nil) }
    let personal = try controller.createWorkspaceGroup(name: "Personal", moving: nil)
    try groupExpect(try controller.listWorkspaceGroups().map(\.id) == [clients.id, personal.id], "a new group is not added last")
    try controller.moveWorkspaceGroup(personal.id, by: -1)
    try groupExpect(try controller.listWorkspaceGroups().map(\.id) == [personal.id, clients.id], "a group did not move up")
    try refuses("moving the first group up") { try controller.moveWorkspaceGroup(personal.id, by: -1) }

    try controller.setWorkspaceGroup(b.workspaceID, groupID: personal.id)
    try groupExpect((try workspace(b.workspaceID))?.groupID == personal.id, "a workspace did not move into a group")
    try refuses("a workspace moved into a group that does not exist") { try controller.setWorkspaceGroup(b.workspaceID, groupID: "group-missing") }
    try controller.setWorkspaceGroup(b.workspaceID, groupID: nil)
    try groupExpect((try workspace(b.workspaceID))?.groupID == nil, "a workspace did not move to Ungrouped")
    try controller.setWorkspaceGroup(b.workspaceID, groupID: personal.id)

    try controller.renameWorkspaceGroup(clients.id, name: "Work")
    try refuses("renaming a group to another group's name") { try controller.renameWorkspaceGroup(clients.id, name: "PERSONAL") }
    try controller.setWorkspaceGroupCollapsed(personal.id, collapsed: true)

    // Durable: a new controller reads the groups and memberships back.
    let reloaded = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    let readGroups = try reloaded.listWorkspaceGroups()
    try groupExpect(readGroups.map(\.name) == ["Personal", "Work"] && readGroups.first?.isCollapsed == true,
                    "groups did not survive a reload: \(readGroups)")
    try groupExpect(try reloaded.listWorkspaces().first { $0.workspaceID == b.workspaceID }?.groupID == personal.id,
                    "a membership did not survive a reload")

    // Any change whose save fails changes nothing.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: runtime.path)
    let groupsBefore = try controller.listWorkspaceGroups(), workspacesBefore = try controller.listWorkspaces()
    var refused = 0
    for change in [
        { _ = try controller.createWorkspaceGroup(name: "Later", moving: a.workspaceID) },
        { try controller.renameWorkspaceGroup(personal.id, name: "Home") },
        { try controller.deleteWorkspaceGroup(personal.id) },
        { try controller.setWorkspaceGroup(a.workspaceID, groupID: nil) },
        { try controller.moveWorkspaceGroup(clients.id, by: -1) },
        { try controller.setWorkspaceGroupCollapsed(clients.id, collapsed: true) },
    ] as [() throws -> Void] {
        do { try change() } catch { refused += 1 }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    try groupExpect(refused == 6, "\(6 - refused) group change(s) whose save failed reported success")
    try groupExpect(try controller.listWorkspaceGroups() == groupsBefore && controller.listWorkspaces() == workspacesBefore,
                    "a group change whose save failed stayed in memory")

    // Deleting a group moves its workspaces to Ungrouped; it closes nothing.
    let panesBefore = try controller.listPanes().map(\.id)
    try controller.deleteWorkspaceGroup(personal.id)
    try groupExpect(try controller.listWorkspaceGroups().map(\.id) == [clients.id], "the deleted group is still listed")
    try groupExpect((try workspace(b.workspaceID))?.groupID == nil, "a deleted group's workspace was not moved to Ungrouped")
    try groupExpect(try controller.listPanes().map(\.id) == panesBefore && (try workspace(b.workspaceID)) != nil,
                    "deleting a group closed a workspace or a pane")

    // State written before groups existed loads with none.
    let stateFile = runtime.appendingPathComponent("workbench-state.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as! [String: Any]
    object.removeValue(forKey: "workspaceGroups")
    object["workspaces"] = (object["workspaces"] as! [[String: Any]]).map { var w = $0; w.removeValue(forKey: "groupID"); return w }
    try JSONSerialization.data(withJSONObject: object).write(to: stateFile)
    let legacy = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try groupExpect(try legacy.listWorkspaceGroups().isEmpty && legacy.listWorkspaces().allSatisfy { $0.groupID == nil },
                    "state written before groups did not load with none")
}

/// The app draws the groups and offers every group action.
func checkWorkspaceGroupWiring() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let view = try String(contentsOf: sources.appendingPathComponent("ParleyNative/ContentView.swift"), encoding: .utf8)
    for needle in ["sections.groups", "sections.ungrouped", "\"Move to Group\"", "\"New Group…\"", "\"Rename Group…\"", "\"Delete Group…\"",
                   "\"Ungrouped\"", "moveWorkspaces(inSubset:"] {
        try groupExpect(view.contains(needle), "the sidebar is missing \(needle)")
    }
    let model = try String(contentsOf: sources.appendingPathComponent("ParleyNative/AppModel.swift"), encoding: .utf8)
    try groupExpect(model.contains("workspaceGroups = try controller.listWorkspaceGroups()")
                    && model.contains("WorkspaceSidebarSections.derive(workspaces: workspaces, groups: workspaceGroups"),
                    "the model does not load the groups or derive the sections from them")
}

@MainActor let workspaceGroupChecks: [(String, () throws -> Void)] = [
    ("workspace groups: sections", checkWorkspaceGroupSections),
    ("workspace groups: persist and roll back", checkWorkspaceGroupsPersistAndRollBack),
    ("workspace groups: the sidebar draws and edits them", checkWorkspaceGroupWiring),
]
