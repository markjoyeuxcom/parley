import Foundation
import ParleyCore

// MR 3 of Prax 9dd56387: reaching any of many workspaces without scrolling —
// a switcher, the tabs shown when the sidebar is hidden, and the pane's Move
// to Workspace menu.

private func switcherExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorkspaceSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func switcherWorkspaces(_ count: Int) -> [WorkbenchWorkspace] {
    (0..<count).map { WorkbenchWorkspace(id: String(format: "w%02d", $0), name: String(format: "W%02d", $0), isActive: false, workspaceID: String(format: "w%02d", $0)) }
}

func checkWorkspaceTabsAtManyWorkspaces() throws {
    var few = switcherWorkspaces(6)
    few[2].isActive = true
    let compact = WorkspaceSidebarSections.derive(workspaces: few, needsPerson: { _ in 0 })
    try switcherExpect(compact.tabs == few.map(\.workspaceID) && !compact.tabsOverflow, "a short list does not show every workspace as a tab")

    // Many: the pinned, the current and those needing the person, kept in
    // the person's own workspace order, so a tab appears or disappears but
    // never changes place (pinned-then-current-then-attention moved a tab
    // needing the person when it was selected and became the current one).
    var many = switcherWorkspaces(50)
    many[30].isActive = true
    for index in [7, 3] { many[index].pinned = true }
    many[40].lastSelectedAt = Date()
    let needs = ["w12": 1, "w03": 2, "w30": 4]
    let sections = WorkspaceSidebarSections.derive(workspaces: many, needsPerson: { needs[$0, default: 0] })
    try switcherExpect(sections.tabs == ["w03", "w07", "w12", "w30"], "tabs at fifty workspaces: \(sections.tabs)")
    try switcherExpect(sections.tabsOverflow, "fifty workspaces do not offer More")
    // Selecting the tab needing the person leaves every tab where it was.
    many[30].isActive = false
    many[12].isActive = true
    let after = WorkspaceSidebarSections.derive(workspaces: many, needsPerson: { needs[$0, default: 0] })
    try switcherExpect(after.tabs.filter(sections.tabs.contains) == sections.tabs.filter(after.tabs.contains),
                       "switching moved a tab: \(sections.tabs) became \(after.tabs)")
}

func checkWorkspaceSwitcherOrder() throws {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var workspaces = [
        WorkbenchWorkspace(id: "a", name: "alpha", isActive: false, workspaceID: "a"),
        WorkbenchWorkspace(id: "b", name: "Bravo", isActive: false, workspaceID: "b"),
        WorkbenchWorkspace(id: "c", name: "charlie", isActive: true, workspaceID: "c"),
        WorkbenchWorkspace(id: "d", name: "Delta", isActive: false, workspaceID: "d"),
        WorkbenchWorkspace(id: "e", name: "echo", isActive: false, workspaceID: "e"),
        WorkbenchWorkspace(id: "f", name: "Foxtrot", isActive: false, workspaceID: "f"),
    ]
    workspaces[3].lastSelectedAt = now.addingTimeInterval(-60)    // Delta, just left
    workspaces[4].lastSelectedAt = now.addingTimeInterval(-3600)  // echo, earlier
    workspaces[2].lastSelectedAt = now                            // the current one
    let needs = ["f": 1, "b": 3, "c": 9]
    let order = WorkspaceSwitcherOrder.ordered(workspaces: workspaces, needsPerson: { needs[$0, default: 0] })
    // Needing the person first (most first), then most recently used, then
    // never used by name ignoring case, and the current workspace last.
    try switcherExpect(order == ["b", "f", "d", "e", "a", "c"], "switcher order: \(order)")
    // Ties (the same moment, the same name) keep the person's order.
    var ties = (0..<4).map { WorkbenchWorkspace(id: "t\($0)", name: $0 < 2 ? "Scratch" : "Same", isActive: false, workspaceID: "t\($0)") }
    ties[2].lastSelectedAt = now
    ties[3].lastSelectedAt = now
    for _ in 0..<5 {
        let tied = WorkspaceSwitcherOrder.ordered(workspaces: ties, needsPerson: { _ in 0 })
        try switcherExpect(tied == ["t2", "t3", "t0", "t1"], "ties did not keep the workspace order: \(tied)")
        ties.swapAt(0, 1)
        ties.swapAt(2, 3)
        let swapped = WorkspaceSwitcherOrder.ordered(workspaces: ties, needsPerson: { _ in 0 })
        try switcherExpect(swapped == ["t3", "t2", "t1", "t0"], "ties did not follow a reordered workspace list: \(swapped)")
        ties.swapAt(0, 1)
        ties.swapAt(2, 3)
    }
}

func checkWorkspaceDestinationMenu() throws {
    // Few workspaces and no groups: the plain list, as before.
    var few = switcherWorkspaces(5)
    few[0].isActive = true
    let fewSections = WorkspaceSidebarSections.derive(workspaces: few, needsPerson: { _ in 0 })
    let plain = WorkspaceDestinationMenu.layout(destinations: ["w01", "w02", "w03", "w04"], sections: fewSections)
    try switcherExpect(plain == WorkspaceDestinationMenu.Layout(shortcuts: [], groups: [], remaining: ["w01", "w02", "w03", "w04"], remainingIsUngrouped: false),
                       "a short list is not the plain list: \(plain)")

    // Many, no groups: pinned and recent first, then the rest without repeating them.
    var ungrouped = switcherWorkspaces(12)
    ungrouped[0].isActive = true
    ungrouped[4].pinned = true
    ungrouped[8].lastSelectedAt = Date()
    let flat = WorkspaceDestinationMenu.layout(destinations: ungrouped.map(\.workspaceID).filter { $0 != "w00" },
                                               sections: WorkspaceSidebarSections.derive(workspaces: ungrouped, needsPerson: { _ in 0 }))
    try switcherExpect(flat.shortcuts == ["w04", "w08"] && !flat.remainingIsUngrouped
                       && flat.remaining == ungrouped.map(\.workspaceID).filter { !["w00", "w04", "w08"].contains($0) },
                       "with no groups the shortcuts are repeated in the list below: \(flat)")

    // Many, grouped: pinned and recent first, then a submenu per group with a
    // destination in it, then Ungrouped. The pane's own workspace is no destination.
    var many = switcherWorkspaces(20)
    many[0].isActive = true
    many[5].pinned = true
    many[9].lastSelectedAt = Date()
    for index in [1, 2, 5] { many[index].groupID = "g1" }
    many[0].groupID = "g2"
    let groups = [WorkspaceGroup(id: "g1", name: "Clients"), WorkspaceGroup(id: "g2", name: "Home"), WorkspaceGroup(id: "g3", name: "Empty")]
    let sections = WorkspaceSidebarSections.derive(workspaces: many, groups: groups, needsPerson: { _ in 0 })
    let destinations = many.map(\.workspaceID).filter { $0 != "w00" }
    let layout = WorkspaceDestinationMenu.layout(destinations: destinations, sections: sections)
    try switcherExpect(layout.shortcuts == ["w05", "w09"], "shortcuts: \(layout.shortcuts)")
    try switcherExpect(layout.groups == [WorkspaceDestinationMenu.Group(id: "g1", name: "Clients", workspaces: ["w01", "w02", "w05"])],
                       "groups: \(layout.groups); Home holds only the pane's own workspace and Empty holds none")
    try switcherExpect(layout.remainingIsUngrouped && layout.remaining == destinations.filter { !["w01", "w02", "w05"].contains($0) },
                       "ungrouped: \(layout.remaining)")
}

func checkWorkspaceSwitcherShortcut() throws {
    try switcherExpect(WorkbenchKeyboardShortcut.resolve(key: "o", command: true, shift: true, option: false, control: false) == .workspaceSwitcher,
                       "Shift-Command-O does not open the workspace switcher from a terminal")
    try switcherExpect(!SystemReservedShortcut.macOSDefaults.contains(.init(key: "o", command: true, shift: true, option: false, control: false)),
                       "the switcher's chord is one macOS takes first")
    try switcherExpect(WorkbenchKeyboardShortcut.resolve(key: "o", command: true, shift: false, option: false, control: false) == nil,
                       "Command-O alone was taken from the terminal")
}

/// The app wires each of these up.
func checkWorkspaceSwitcherWiring() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let app = try String(contentsOf: sources.appendingPathComponent("ParleyNative/ParleyNativeApp.swift"), encoding: .utf8)
    try switcherExpect(app.contains("Button(\"Go to Workspace…\") { model.showWorkspaceSwitcher() }")
                       && app.contains(".keyboardShortcut(\"o\", modifiers: [.command, .shift])"), "Navigate has no Go to Workspace…")
    let view = try String(contentsOf: sources.appendingPathComponent("ParleyNative/ContentView.swift"), encoding: .utf8)
    try switcherExpect(view.contains("sections.tabs") && view.contains("model.showWorkspaceSwitcher()"), "the hidden-sidebar tabs do not use sections.tabs or offer More")
    try switcherExpect(view.contains("WorkspaceDestinationMenu.layout("), "Move to Workspace is still one flat list")
    let model = try String(contentsOf: sources.appendingPathComponent("ParleyNative/AppModel.swift"), encoding: .utf8)
    try switcherExpect(model.contains("WorkspaceSwitcherOrder.ordered("), "the switcher is not ordered")
    try switcherExpect(app.contains("case .workspaceSwitcher: model.showWorkspaceSwitcher()"), "the switcher's chord does not reach it from a terminal")
}

@MainActor let workspaceSwitcherChecks: [(String, () throws -> Void)] = [
    ("workspace tabs at many workspaces", checkWorkspaceTabsAtManyWorkspaces),
    ("workspace switcher order", checkWorkspaceSwitcherOrder),
    ("workspace destination menu", checkWorkspaceDestinationMenu),
    ("workspace switcher shortcut", checkWorkspaceSwitcherShortcut),
    ("workspace switcher wiring", checkWorkspaceSwitcherWiring),
]
