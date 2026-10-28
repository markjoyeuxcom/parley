import Foundation
import ParleyCore

private func presentationExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorkspacePresentation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func presentationRegistryFixture() throws -> (root: URL, registry: WorkspaceRegistry) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-presentation-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, WorkspaceRegistry(file: root.appendingPathComponent("workspace-registry.json")))
}

/// Grid or Tabs per workspace: presentation only, stored beside the split
/// tree, never changing the tree, a process or what an agent can reach.
@MainActor let workspacePresentationChecks: [(String, () throws -> Void)] = [
    ("workspace presentation decodes unknown values as Grid and names its toggle", {
        let decoder = JSONDecoder()
        for (raw, expected) in [("grid", WorkspacePresentation.grid), ("tabs", .tabs), ("stack", .grid)] {
            let decoded = try decoder.decode(WorkspacePresentation.self, from: Data("\"\(raw)\"".utf8))
            try presentationExpect(decoded == expected, "\"\(raw)\" decoded as \(decoded), not \(expected)")
        }
        try presentationExpect(WorkspacePresentation.grid.toggled == .tabs && WorkspacePresentation.tabs.toggled == .grid,
                               "toggling did not alternate between Grid and Tabs")
        try presentationExpect(WorkspacePresentation.grid.toggleTitle == "Show Panes as Tabs"
                               && WorkspacePresentation.tabs.toggleTitle == "Show Panes as Grid",
                               "the toggle titles do not name the presentation a click gives")
    }),
    ("a tabs workspace shows the selected pane, or the first in layout order", {
        try presentationExpect(WorkspaceTabsProjection.shownPaneID(activePaneID: "b", orderedPaneIDs: ["a", "b", "c"]) == "b",
                               "the selected pane was not the shown tab")
        try presentationExpect(WorkspaceTabsProjection.shownPaneID(activePaneID: "elsewhere", orderedPaneIDs: ["a", "b"]) == "a",
                               "a selection outside the workspace did not fall back to its first pane")
        try presentationExpect(WorkspaceTabsProjection.shownPaneID(activePaneID: nil, orderedPaneIDs: ["c", "a"]) == "c",
                               "no selection did not show the first pane in layout order")
        try presentationExpect(WorkspaceTabsProjection.shownPaneID(activePaneID: "a", orderedPaneIDs: []) == nil,
                               "an empty workspace claimed to show a pane")
    }),
    ("the workspace registry keeps a presentation beside the split tree", {
        let fixture = try presentationRegistryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = fixture.registry
        let workspace = WorkbenchWorkspace(id: "w", name: "Work", isActive: true)
        _ = try registry.synchronize(workspaces: [workspace])
        try presentationExpect(try registry.record(workspaceID: "w")?.presentation == .grid, "a new workspace record was not Grid")
        let gridData = try Data(contentsOf: registry.file)
        try presentationExpect(String(decoding: gridData, as: UTF8.self).contains("presentation") == false,
                               "a Grid record wrote a presentation key an older Parley would carry needlessly")

        let layout = NativeLayoutNode.split(direction: .horizontal, first: .leaf("p1"), second: .leaf("p2"))
        try registry.updateLayout(workspaceID: "w", layout: layout)
        try registry.updateSplitFractions(workspaceID: "w", fractions: ["root": 0.3])
        let revision = try registry.record(workspaceID: "w")?.layoutRevision
        try presentationExpect(try registry.updatePresentation(workspaceID: "w", presentation: .tabs), "switching to Tabs reported no change")
        try presentationExpect(try registry.updatePresentation(workspaceID: "w", presentation: .tabs) == false,
                               "repeating Tabs rewrote the registry")
        let record = try registry.record(workspaceID: "w")
        try presentationExpect(record?.presentation == .tabs, "Tabs was not recorded")
        try presentationExpect(record?.layout == layout && record?.splitFractions == ["root": 0.3] && record?.layoutRevision == revision,
                               "switching to Tabs changed the split tree, its fractions or its revision")

        // A rename through synchronize, a layout change and a fresh reader all keep it.
        _ = try registry.synchronize(workspaces: [WorkbenchWorkspace(id: "w", name: "Renamed", isActive: true)])
        try registry.updateLayout(workspaceID: "w", layout: .leaf("p1"))
        try presentationExpect(try WorkspaceRegistry(file: registry.file).record(workspaceID: "w")?.presentation == .tabs,
                               "Tabs did not survive a rename, a layout change and a reread")

        try presentationExpect(try registry.updatePresentation(workspaceID: "absent", presentation: .tabs) == false,
                               "a workspace without a record claimed a stored presentation")
        try presentationExpect(try registry.updatePresentation(workspaceID: "w", presentation: .grid), "switching back to Grid reported no change")
        try presentationExpect(try registry.record(workspaceID: "w")?.presentation == .grid, "Grid was not recorded")
    }),
    ("a registry record from before Tabs, or with an unknown presentation, reads as Grid", {
        let decoder = JSONDecoder()
        let legacy = #"{"workspaceID":"w","name":"W","attachedFolders":[],"automationPolicy":"askAnswer","layoutRevision":0,"splitFractions":{}}"#
        try presentationExpect(try decoder.decode(WorkspaceRegistryRecord.self, from: Data(legacy.utf8)).presentation == .grid,
                               "a record without a presentation did not read as Grid")
        let future = #"{"workspaceID":"w","name":"W","attachedFolders":[],"automationPolicy":"askAnswer","presentation":"stack"}"#
        try presentationExpect(try decoder.decode(WorkspaceRegistryRecord.self, from: Data(future.utf8)).presentation == .grid,
                               "an unknown presentation made the record unreadable or not Grid")
    }),
    ("a configuration archive carries Tabs and reads its absence as Grid", {
        let workspace = ArchivedWorkspace(
            name: "Work", attachedFolders: [], newPaneFolder: nil, automationPolicy: .askAnswer, pinned: false,
            groupName: nil, panes: [], layout: nil, splitFractions: [:], presentation: .tabs
        )
        let data = try JSONEncoder().encode(workspace)
        try presentationExpect(try JSONDecoder().decode(ArchivedWorkspace.self, from: data).presentation == .tabs,
                               "Tabs did not round-trip through an archived workspace")
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        object.removeValue(forKey: "presentation")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        try presentationExpect(try JSONDecoder().decode(ArchivedWorkspace.self, from: legacy).presentation == nil,
                               "an archive from before Tabs did not read as Grid")
    }),
    ("tabs never zoom, and Command-Shift-T switches the presentation", {
        try presentationExpect(WorkbenchZoomPolicy.next(current: nil, requested: nil, active: "A", visible: ["A", "B"], presentation: .tabs) == nil,
                               "the global zoom action zoomed in Tabs")
        try presentationExpect(WorkbenchZoomPolicy.next(current: nil, requested: "B", active: "A", visible: ["A", "B"], presentation: .tabs) == nil,
                               "a pane-targeted zoom zoomed in Tabs")
        try presentationExpect(WorkbenchZoomPolicy.next(current: nil, requested: nil, active: "A", visible: ["A", "B"]) == "A",
                               "the grid stopped zooming")
        try presentationExpect(WorkbenchKeyboardShortcut.resolve(key: "t", command: true, shift: true, option: false, control: false) == .togglePanePresentation,
                               "Command-Shift-T did not switch the presentation")
        try presentationExpect(WorkbenchKeyboardShortcut.resolve(key: "T", command: true, shift: true, option: false, control: false) == .togglePanePresentation,
                               "Command-Shift-T reported as an upper-case T did not switch the presentation")
        try presentationExpect(WorkbenchKeyboardShortcut.resolve(key: "t", command: true, shift: false, option: false, control: false) == nil,
                               "Command-T was claimed from the terminal")
        try presentationExpect(WorkbenchKeyboardShortcut.resolve(key: "t", command: true, shift: false, option: true, control: false) == .focusActiveTerminal,
                               "Command-Option-T no longer focuses the active terminal")
    }),
    ("the in-app guide explains Tabs", {
        let searchable = ParleyHelpGuide.topics.map(\.searchableText).joined(separator: "\n").lowercased()
        for phrase in [
            "show panes as tabs", "command-shift-t — show the current workspace's panes as tabs",
            "hidden panes keep running", "still receive handoffs", "switching back to grid",
        ] {
            try presentationExpect(searchable.contains(phrase), "the in-app guide omitted \(phrase)")
        }
    }),
]
