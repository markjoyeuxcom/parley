import Foundation
import ParleyCore
import ParleyUI

// Low findings in SwiftUI views, from the review of 22 September 2026 (dd9d9ab6).

private func viewExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ViewLow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func viewFailure(_ message: String) -> NSError {
    NSError(domain: "ViewLow", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

private func viewSource(_ file: String) throws -> SwiftSourceReader {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ParleyNative").appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
}

/// The block that follows `marker` (its first `{` after the marker).
private func block(_ reader: SwiftSourceReader, after marker: String, in text: Substring? = nil) throws -> Substring {
    let haystack = text ?? reader.text[...]
    guard let found = haystack.range(of: marker),
          let open = haystack[found.upperBound...].firstIndex(of: "{"),
          let body = reader.balanced(at: open) else { throw viewFailure("\(marker) was not found") }
    return body
}

/// "Show this handoff" from outside Status Center widened the workspace
/// scope and selected the handoff, and the scope's own onChange then cleared
/// that selection. A scope change keeps a selection the new scope still shows.
func checkStatusCenterScopeChangeKeepsAVisibleSelection() throws {
    try viewExpect(StatusCenterSelection.afterScopeChange(selected: "h1", visible: ["h0", "h1"]) == "h1",
                   "a scope change cleared a selection the new scope still shows")
    try viewExpect(StatusCenterSelection.afterScopeChange(selected: "h1", visible: ["h0"]) == nil,
                   "a scope change kept a selection the new scope hides")
    try viewExpect(StatusCenterSelection.afterScopeChange(selected: nil, visible: ["h0"]) == nil, "a scope change invented a selection")

    let reader = try viewSource("StatusCenterView.swift")
    // The handler that resets per-scope state (the scroll handler above it only scrolls).
    let text = reader.text
    var search = text.startIndex..<text.endIndex
    var handlers: [Substring] = []
    while let found = text.range(of: ".onChange(of: workspaceID)", range: search) {
        search = found.upperBound..<text.endIndex
        if let open = text[found.upperBound...].firstIndex(of: "{"), let body = reader.balanced(at: open) { handlers.append(body) }
    }
    let resetting = handlers.filter { $0.contains("selectedBusyDraftID") }
    try viewExpect(resetting.count == 1, "the scope-reset handler was not found (\(handlers.count) workspaceID handlers)")
    try viewExpect(resetting[0].contains("StatusCenterSelection.afterScopeChange(") && !resetting[0].contains("selectedHandoffID = nil"),
                   "a workspace scope change still clears the handoff it was asked to show")
}

/// The workspace row menus and the activity history menu were live SwiftUI
/// menus: a model change while one was open rebuilt its items under the
/// pointer, which is what disrupted Move to Workspace before the pane menus
/// became AppKit snapshots.
func checkSidebarMenusAreSnapshots() throws {
    let reader = try viewSource("ContentView.swift")
    let contextMenus = reader.text.components(separatedBy: ".contextMenu").count - 1
    try viewExpect(contextMenus == 0, "ContentView still attaches \(contextMenus) live SwiftUI context menu(s)")
    try viewExpect(reader.text.contains("private var activityHistoryMenu: ToolbarActionMenu"),
                   "the activity history menu is still a live SwiftUI menu")
    for builder in ["workspaceMenuItems(workspace)", "attachedFolderMenuItems(folder, workspace: workspace)", "favouriteFolderMenuItems(folder)"] {
        try viewExpect(reader.text.contains(".snapshotContextMenu(\(builder))"),
                       "the \(builder) menu is not an AppKit snapshot with VoiceOver actions")
    }
    // The overlay is not in the accessibility tree; its actions are named instead.
    var ran: [String] = []
    let actions = ToolbarMenuAccessibility.actions([
        .action("Rename…") { ran.append("rename") },
        .separator,
        .heading("Heading"),
        .message("Message"),
        .submenu("Automation", items: [.action("Off") { ran.append("off") }, .action("Ask", isEnabled: false) {}]),
        .submenu("Hidden", isEnabled: false, items: [.action("Inside") {}]),
        .action("Close Workspace…", isEnabled: false, isDestructive: true) {},
    ])
    try viewExpect(actions.map(\.name) == ["Rename…", "Automation: Off"], "VoiceOver actions were \(actions.map(\.name))")
    actions.forEach { $0.perform() }
    try viewExpect(ran == ["rename", "off"], "a VoiceOver action did not run its menu item")
}

/// The divider pushed the resize cursor on hover but popped it only while no
/// pane was zoomed, and never when it disappeared under the pointer, so the
/// cursor stayed a resize arrow over the terminals.
func checkDividerResizeCursorStaysBalanced() throws {
    let hold = ResizeCursorHold()
    var pushes = 0, pops = 0
    func apply(_ change: ResizeCursorHold.Change) {
        switch change {
        case .push: pushes += 1
        case .pop: pops += 1
        case .none: break
        }
    }
    apply(hold.hover(true, allowed: true))
    apply(hold.hover(true, allowed: true))
    try viewExpect(pushes == 1, "a repeated hover pushed the cursor twice")
    // The pane is zoomed while the pointer rests on the divider, then it leaves.
    apply(hold.hover(false, allowed: false))
    try viewExpect(pops == 1 && !hold.held, "leaving a divider while zoomed kept the resize cursor")
    apply(hold.hover(false, allowed: true))
    try viewExpect(pops == 1, "leaving twice popped a cursor that was not pushed")
    apply(hold.hover(true, allowed: false))
    try viewExpect(pushes == 1, "a zoomed layout pushed the resize cursor")
    apply(hold.hover(true, allowed: true))
    apply(hold.release())
    apply(hold.release())
    try viewExpect(pushes == 2 && pops == 2, "a divider removed under the pointer left the cursor unbalanced (\(pushes) pushes, \(pops) pops)")

    let reader = try viewSource("ContentView.swift")
    let divider = try block(reader, after: "private func divider(")
    try viewExpect(divider.contains("resizeCursor.hover(") && divider.contains(".onDisappear") && divider.contains("resizeCursor.release()"),
                   "the divider does not balance its cursor through ResizeCursorHold, including when it disappears")
    let zoom = try block(reader, after: ".onChange(of: focusPaneID)", in: divider)
    try viewExpect(zoom.contains("resizeCursor.release()"), "zooming with the keyboard does not give the cursor back")
    // Every push and pop goes through the hold's answer.
    let sourcePushes = reader.text.components(separatedBy: ".push()").count - 1
    let sourcePops = reader.text.components(separatedBy: "NSCursor.pop()").count - 1
    let apply = try block(reader, after: "private func applyResizeCursor(")
    try viewExpect(sourcePushes == 1 && sourcePops == 1 && apply.contains(".push()") && apply.contains("NSCursor.pop()"),
                   "ContentView pushes or pops a cursor outside applyResizeCursor (\(sourcePushes) pushes, \(sourcePops) pops)")
}

/// A requested Help topic was never consumed: asking for the same topic again
/// did nothing, and every later Help opening jumped back to it.
func checkHelpConsumesItsRequestedTopic() throws {
    let help = try viewSource("HelpView.swift")
    let select = try block(help, after: "private func selectRequestedTopic()")
    try viewExpect(select.contains("model.consumeRequestedHelpTopicID()"), "Help selects a requested topic without consuming the request")
    let model = try viewSource("AppModel.swift")
    let consume = try block(model, after: "func consumeRequestedHelpTopicID()")
    try viewExpect(consume.contains("requestedHelpTopicID = nil"), "consuming the Help request does not clear it")
}

/// Compatibility & Releases is a sheet with no way to close it but the
/// window's own controls, which a sheet does not have.
func checkReleaseSheetCanBeClosed() throws {
    let reader = try viewSource("ReleaseLifecycleView.swift")
    let view = try block(reader, after: "struct ReleaseLifecycleView: View")
    let body = try block(reader, after: "var body: some View", in: view)
    try viewExpect(body.contains("Button(\"Done\")") && body.contains(".keyboardShortcut(.cancelAction)"),
                   "the Compatibility & Releases sheet has no Done button bound to Escape")
}

/// The sidebar compared folders by canonical path (a realpath each side) and
/// asked the filesystem whether each favourite and recent folder exists, per
/// favourite, workspace and attachment, on every render.
func checkFolderIdentityIsRememberedBetweenRenders() throws {
    var now = 100.0
    var resolved = 0, statted = 0
    let memo = FolderIdentityMemo(lifetime: 5, clock: { now },
        resolve: { resolved += 1; return $0.hasSuffix("/link") ? "/real" : $0 },
        exists: { statted += 1; return $0 != "/gone" })
    for _ in 0..<50 {
        _ = memo.matches("/a/link", "/real")
        _ = memo.exists("/gone")
    }
    try viewExpect(memo.matches("/a/link", "/real") && !memo.exists("/gone"), "the memo changed what it answers")
    try viewExpect(resolved == 2 && statted == 1, "fifty renders resolved \(resolved) paths and checked \(statted) folders")
    now += 6
    _ = memo.matches("/a/link", "/real")
    _ = memo.exists("/gone")
    try viewExpect(resolved == 4 && statted == 2, "an answer older than its lifetime was not read again")
    let workspaces = [
        WorkbenchWorkspace(id: "w1", name: "One", attachedFolders: ["/a/link"], isActive: false, workspaceID: "w1"),
        WorkbenchWorkspace(id: "w2", name: "Two", attachedFolders: ["/b"], isActive: false, workspaceID: "w2"),
    ]
    try viewExpect(memo.workspaces(matching: "/real", in: workspaces).map(\.workspaceID) == ["w1"], "workspace matching differs from the routing rule")

    try viewExpect(memo.contains("/real", in: ["/b", "/a/link"]) && !memo.contains("/c", in: ["/b"]), "favourite membership differs")
    let before = resolved
    memo.invalidate()
    _ = memo.matches("/a/link", "/real")
    try viewExpect(resolved == before + 2, "an invalidated memo answered from memory")

    let reader = try viewSource("ContentView.swift")
    for direct in ["WorkspaceFolderIdentity.matches(", "WorkspaceFolderRouting.matches(", "FolderListMaintenance.directoryExists(",
                   "model.isFavouriteFolder("] {
        try viewExpect(!reader.text.contains(direct), "ContentView still calls \(direct) while it renders")
    }
    let model = try viewSource("AppModel.swift")
    let refresh = try block(model, after: "func refresh(includingRelay: Bool = true) throws")
    let explicit = try block(model, after: "if includingRelay", in: refresh)
    try viewExpect(explicit.contains("folderIdentity.invalidate()"), "an explicit refresh keeps folder answers from before the change")
}

@MainActor let viewLowChecks: [(String, () throws -> Void)] = [
    ("a status center scope change keeps a visible selection", checkStatusCenterScopeChangeKeepsAVisibleSelection),
    ("sidebar menus are appkit snapshots", checkSidebarMenusAreSnapshots),
    ("the divider resize cursor stays balanced", checkDividerResizeCursorStaysBalanced),
    ("help consumes its requested topic", checkHelpConsumesItsRequestedTopic),
    ("the release sheet can be closed", checkReleaseSheetCanBeClosed),
    ("folder identity is remembered between renders", checkFolderIdentityIsRememberedBetweenRenders),
]
