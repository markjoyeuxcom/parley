import Foundation
import ParleyCore

// The sidebar at 50 workspaces (Mark's decision, 30 September 2026): the
// current workspace's panes first, then workspaces that need the person, the
// pinned ones, the recent ones, and every workspace last.

private func sidebarExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorkspaceSidebar", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func sidebarWorkspace(_ id: String, active: Bool = false, pinned: Bool = false, selected: Date? = nil) -> WorkbenchWorkspace {
    var workspace = WorkbenchWorkspace(id: id, name: id.uppercased(), isActive: active, workspaceID: id)
    workspace.pinned = pinned
    workspace.lastSelectedAt = selected
    return workspace
}

/// Times are seconds since the reference date, as JSONDecoder reads them.
private func sidebarHandoff(_ id: String, state: RelayHandoffState, source: String, target: String,
                            attention: RelayAttention? = nil, result: Bool = false,
                            updatedAt: TimeInterval = 10, readAt: TimeInterval? = nil) throws -> RelayHandoff {
    var object: [String: Any] = [
        "id": id, "idempotencyKey": "key-\(id)", "kind": RelayHandoffKind.ask.rawValue,
        "sourcePaneID": "%s-\(id)", "sourceName": "Source", "sourceKind": "codex",
        "sourceWorkspaceID": source, "sourceWorkspaceName": source,
        "targetPaneID": "%t-\(id)", "targetName": "Target", "targetKind": "claude",
        "targetWorkspaceID": target, "targetWorkspaceName": target,
        "text": "Task \(id)", "submitted": true, "state": state.rawValue, "updatedAt": updatedAt,
        "transitions": [["state": state.rawValue, "occurredAt": updatedAt, "detail": "Detail"]],
    ]
    if result { object["resultText"] = "Answer \(id)" }
    if let readAt { object["readAt"] = readAt }
    if let attention { object["attention"] = attention.rawValue }
    return try JSONDecoder().decode(RelayHandoff.self, from: JSONSerialization.data(withJSONObject: object))
}

func checkWorkspaceSidebarSectionsAtFiftyWorkspaces() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hour: TimeInterval = 3600
    var workspaces = (0..<50).map { sidebarWorkspace(String(format: "w%02d", $0)) }
    workspaces[10].isActive = true
    for pinned in [3, 10, 20] { workspaces[pinned].pinned = true }
    for (index, hours) in [(5, 1.0), (6, 2.0), (7, 3.0), (8, 4.0), (9, 5.0), (11, 6.0), (20, 0.5), (12, 0.2), (10, 0.1)] {
        workspaces[index].lastSelectedAt = now.addingTimeInterval(-hours * hour)
    }
    let needs = ["w12": 2, "w30": 1, "w10": 3, "w31": 1]
    let sections = WorkspaceSidebarSections.derive(workspaces: workspaces, needsPerson: { needs[$0, default: 0] })
    try sidebarExpect(sections.current == "w10", "the current workspace is \(String(describing: sections.current))")
    // Most first, ties in the person's order; the current workspace shows its own.
    try sidebarExpect(sections.needsAttention == ["w12", "w30", "w31"], "needs attention: \(sections.needsAttention)")
    try sidebarExpect(sections.pinned == ["w03", "w10", "w20"], "pinned: \(sections.pinned)")
    // Newest first, at most five, never the current, a pinned or an attention workspace.
    try sidebarExpect(sections.recent == ["w05", "w06", "w07", "w08", "w09"], "recent: \(sections.recent)")
    try sidebarExpect(sections.all == workspaces.map(\.workspaceID), "all workspaces are not listed in order")
    try sidebarExpect(!sections.allExpandedByDefault, "fifty workspaces are expanded by default")

    // A few workspaces: the whole list is short, so it opens and recent adds nothing.
    let few = Array(workspaces.prefix(6))
    let compact = WorkspaceSidebarSections.derive(workspaces: few, needsPerson: { _ in 0 })
    try sidebarExpect(compact.recent.isEmpty && compact.allExpandedByDefault && compact.needsAttention.isEmpty,
                      "a short list is not shown whole: \(compact)")
    try sidebarExpect(compact.current == nil || compact.current == few.first(where: \.isActive)?.workspaceID, "compact current")

    // Pinned reordering is carried out on the whole workspace order (SwiftUI onMove offsets).
    let all = ["a", "b", "c", "d", "e"], pinned = ["b", "d", "e"]
    try sidebarExpect(WorkspaceSidebarSections.pinnedMove(source: 2, destination: 0, pinned: pinned, all: all)! == (4, 1), "e to the top of pinned")
    try sidebarExpect(WorkspaceSidebarSections.pinnedMove(source: 0, destination: 3, pinned: pinned, all: all)! == (1, 5), "b to the end of pinned")
    try sidebarExpect(WorkspaceSidebarSections.pinnedMove(source: 0, destination: 2, pinned: pinned, all: all)! == (1, 4), "b before e")
    try sidebarExpect(WorkspaceSidebarSections.pinnedMove(source: 1, destination: 1, pinned: pinned, all: all) == nil, "a move onto itself")
    try sidebarExpect(WorkspaceSidebarSections.pinnedMove(source: 5, destination: 0, pinned: pinned, all: all) == nil, "an out-of-range move")

    // When a recent workspace was last used, as its row shows it: a time
    // today, a weekday this week, a date before that. Unlike "2h" it cannot go
    // stale while an idle sidebar is not redrawn.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let locale = Locale(identifier: "en_GB")
    let noon = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 86_400) + 12 * hour)
    let labels: [(TimeInterval, String)] = [(-2 * hour, "10:00"), (-30 * 60, "11:30"), (-24 * hour, "Sun"), (-3 * 24 * hour, "Fri"), (hour, "13:00")]
    for (offset, expected) in labels {
        let label = WorkspaceRecency.label(for: noon.addingTimeInterval(offset), now: noon, calendar: calendar, locale: locale)
        try sidebarExpect(label == expected, "last used \(offset)s from noon read \(label), expected \(expected)")
    }
    // Month abbreviations differ between macOS releases ("Sep", "Sept").
    let older = WorkspaceRecency.label(for: noon.addingTimeInterval(-10 * 24 * hour), now: noon, calendar: calendar, locale: locale)
    try sidebarExpect(older.hasPrefix("11 Sep") && !older.contains(":"), "ten days ago read \(older), expected the date")
}

/// The badges used to scan every handoff once per workspace per row per
/// render. One pass must give exactly what those scans gave.
func checkWorkspaceActivityMatchesPerWorkspaceScans() throws {
    let workspaces = [
        WorkbenchWorkspace(id: "@0", name: "Library", isActive: true, workspaceID: "library"),
        WorkbenchWorkspace(id: "@1", name: "Consumer", isActive: false, workspaceID: "consumer"),
        WorkbenchWorkspace(id: "idle", name: "Idle", isActive: false, workspaceID: "idle"),
    ]
    let panes = [
        WorkbenchPane(id: "%1", kind: .codex, customName: "A", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "library", relayEnabled: true),
        WorkbenchPane(id: "%2", kind: .claude, customName: "B", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, workspaceID: "consumer", relayEnabled: true),
    ]
    let handoffs = [
        try sidebarHandoff("1", state: .waiting, source: "library", target: "consumer"),
        try sidebarHandoff("2", state: .delivered, source: "library", target: "library"),
        try sidebarHandoff("3", state: .failed, source: "consumer", target: "library", attention: .permissionRequired),
        try sidebarHandoff("4", state: .interrupted, source: "library", target: "consumer"),
        try sidebarHandoff("5", state: .completed, source: "consumer", target: "library", result: true),
        try sidebarHandoff("6", state: .answered, source: "elsewhere", target: "consumer"),
    ]
    let unread = handoffs.filter(\.hasUnreadResult)
    // The per-workspace scans AppModel used, restated.
    func aliases(_ reference: String) -> Set<String> {
        guard let durable = workspaces.first(where: { $0.id == reference || $0.workspaceID == reference })?.workspaceID else { return [reference] }
        return [reference, durable]
    }
    func touches(_ h: RelayHandoff, _ a: Set<String>) -> Bool { a.contains(h.sourceWorkspaceID) || a.contains(h.targetWorkspaceID) }
    let index = WorkspaceActivityProjection.index(workspaces: workspaces, panes: panes, handoffs: handoffs,
                                                  unreadHandoffs: unread, attentionHandoffs: handoffs)
    let needs = Dictionary(uniqueKeysWithValues: ExternalAttentionProjection.snapshot(workspaces: workspaces, panes: panes, handoffs: handoffs)
        .workspaces.map { ($0.id, $0.attentionCount) })
    for reference in ["@0", "library", "@1", "consumer", "idle", "elsewhere"] {
        let a = aliases(reference)
        let expected = (
            waiting: handoffs.count { [.created, .delivered, .waiting, .answered].contains($0.state) && touches($0, a) },
            failures: handoffs.count { ($0.state == .failed || $0.state == .interrupted) && touches($0, a) },
            human: handoffs.contains { $0.state == .failed && $0.attention != nil && touches($0, a) },
            unread: unread.count { a.contains($0.sourceWorkspaceID) })
        let got = index.activity(for: reference)
        try sidebarExpect(got.waiting == expected.waiting && got.failures == expected.failures
                          && got.requiresHumanAttention == expected.human && got.unreadResults == expected.unread,
                          "\(reference): \(got) against the scans' \(expected)")
        let durable = workspaces.first { $0.id == reference || $0.workspaceID == reference }?.workspaceID
        if let durable {
            try sidebarExpect(got.needsPerson == needs[durable, default: 0], "\(reference) needs the person \(got.needsPerson), menu bar says \(needs[durable, default: 0])")
        }
    }
    // Computed once per input generation, however many rows ask.
    var cache = WorkspaceActivityCache()
    for _ in 0..<50 {
        _ = cache.index(generation: 7) { index }
    }
    _ = cache.index(generation: 8) { index }
    try sidebarExpect(cache.computeCount == 2, "the activity index was computed \(cache.computeCount) times for two generations")
}

/// A failure or request needs the person until they open it in Status
/// Center, and for at most a day (Mark's decision, 30 September 2026). It
/// used to count until retention dropped it: failures could not be marked
/// read, so Needs Attention and the menu bar filled with old ones.
func checkNeedsAttentionClearsWhenSeenOrOld() throws {
    let now: TimeInterval = 800_000_000, hour: TimeInterval = 3600
    let workspaces = (0..<6).map { WorkbenchWorkspace(id: "w\($0)", name: "W\($0)", isActive: $0 == 0, workspaceID: "w\($0)") }
    let handoffs = [
        try sidebarHandoff("fresh", state: .failed, source: "w1", target: "w0", updatedAt: now - hour),
        try sidebarHandoff("seen", state: .failed, source: "w2", target: "w0", updatedAt: now - hour, readAt: now - 60),
        try sidebarHandoff("old", state: .interrupted, source: "w3", target: "w0", updatedAt: now - 25 * hour),
        try sidebarHandoff("result", state: .completed, source: "w4", target: "w0", result: true, updatedAt: now - 72 * hour),
        try sidebarHandoff("request", state: .failed, source: "w0", target: "w5", attention: .permissionRequired, updatedAt: now - 2 * hour),
    ]
    let snapshot = ExternalAttentionProjection.snapshot(workspaces: workspaces, panes: [], handoffs: handoffs,
                                                        generatedAt: Date(timeIntervalSinceReferenceDate: now))
    let counts = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0.attentionCount) })
    try sidebarExpect(counts["w1"] == 1, "a failure an hour old and unseen does not need the person")
    try sidebarExpect(counts["w2"] == 0, "a failure the person has seen still needs them")
    try sidebarExpect(counts["w3"] == 0, "an interruption more than a day old still needs the person")
    try sidebarExpect(counts["w4"] == 1, "an unread result stopped counting with age")
    try sidebarExpect(counts["w5"] == 1, "an unseen permission request does not need the person")
    try sidebarExpect(snapshot.nextChangeAt == Date(timeIntervalSinceReferenceDate: now + 22 * hour),
                      "the counts next change at \(String(describing: snapshot.nextChangeAt)), not when the request turns a day old")

    // What Status Center may mark seen.
    try sidebarExpect(handoffs.allSatisfy(\.canBeAcknowledged), "a failure, interruption, result or request cannot be acknowledged")
    let plain = try sidebarHandoff("plain", state: .delivered, source: "w1", target: "w0")
    try sidebarExpect(!plain.canBeAcknowledged && !plain.awaitsAcknowledgement, "a delivered relay can be acknowledged")
    try sidebarExpect(!handoffs[1].awaitsAcknowledgement && handoffs[0].awaitsAcknowledgement, "seen and unseen are confused")

    // The index goes stale when the request ages out, with no new input.
    var cache = WorkspaceActivityCache()
    func build(_ at: TimeInterval) -> WorkspaceActivityIndex {
        WorkspaceActivityProjection.index(workspaces: workspaces, panes: [], handoffs: handoffs, unreadHandoffs: [],
                                          attentionHandoffs: handoffs, now: Date(timeIntervalSinceReferenceDate: at))
    }
    let first = cache.index(generation: 1, now: Date(timeIntervalSinceReferenceDate: now)) { build(now) }
    _ = cache.index(generation: 1, now: Date(timeIntervalSinceReferenceDate: now + 21 * hour)) { build(now + 21 * hour) }
    let later = cache.index(generation: 1, now: Date(timeIntervalSinceReferenceDate: now + 23 * hour)) { build(now + 23 * hour) }
    try sidebarExpect(cache.computeCount == 2, "the index was computed \(cache.computeCount) times, not again once an item aged out")
    try sidebarExpect(first.activity(for: "w5").needsPerson == 1 && later.activity(for: "w5").needsPerson == 0,
                      "the request did not stop counting a day after it happened")

    // The broker accepts the acknowledgement, and Status Center gives it on selection.
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let relay = try String(contentsOf: sources.appendingPathComponent("ParleyCore/Relay.swift"), encoding: .utf8)
    try sidebarExpect(relay.contains("guard handoff.canBeAcknowledged else"), "the broker still refuses to mark a failure seen")
    let status = try String(contentsOf: sources.appendingPathComponent("ParleyNative/StatusCenterView.swift"), encoding: .utf8)
    try sidebarExpect(status.components(separatedBy: "awaitsAcknowledgement { model.markRead(").count == 3
                      && !status.contains("hasUnreadResult { model.markRead("), "selecting a failure in Status Center does not mark it seen")
}

/// Pins and the last time each workspace was used are durable, stamped on
/// both sides of a switch, and rolled back with a save that fails.
func checkWorkspacePinsAndRecencyPersist() throws {
    let root = URL(fileURLWithPath: "/private/tmp/parley-sidebar-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("runtime").path)
        try? FileManager.default.removeItem(at: root)
    }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try controller.bootstrap(cwd: project.path)
    let beforeA = Date()
    let a = try controller.createWorkspace(folder: project.path, name: "A")
    let b = try controller.createWorkspace(folder: project.path, name: "B")
    func workspace(_ id: String) throws -> WorkbenchWorkspace {
        guard let found = try controller.listWorkspaces().first(where: { $0.workspaceID == id }) else {
            throw NSError(domain: "WorkspaceSidebar", code: 2, userInfo: [NSLocalizedDescriptionKey: "workspace \(id) is gone"])
        }
        return found
    }
    let stampedA = try workspace(a.workspaceID).lastSelectedAt
    let stampedB = try workspace(b.workspaceID).lastSelectedAt
    try sidebarExpect(stampedA.map { $0 >= beforeA } == true && stampedB.map { $0 >= stampedA! } == true,
                      "creating B did not stamp A as left and B as entered: \(String(describing: stampedA)) \(String(describing: stampedB))")

    try controller.setWorkspacePinned(a.workspaceID, pinned: true)
    try controller.selectWorkspace(a.workspaceID)
    let reselectedA = try workspace(a.workspaceID).lastSelectedAt
    let leftB = try workspace(b.workspaceID).lastSelectedAt
    try sidebarExpect(reselectedA.map { $0 >= stampedB! } == true && leftB.map { $0 >= stampedB! } == true,
                      "switching back to A did not stamp both sides")
    // Selecting the workspace already active changes nothing.
    try controller.selectWorkspace(a.workspaceID)
    try sidebarExpect(try workspace(a.workspaceID).lastSelectedAt == reselectedA, "reselecting the active workspace restamped it")

    // Durable: a new controller reads the pin and the stamps back.
    let reloaded = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    let readBack = try reloaded.listWorkspaces().first { $0.workspaceID == a.workspaceID }
    try sidebarExpect(readBack?.pinned == true && readBack?.lastSelectedAt != nil, "the pin or the stamp did not survive a reload")

    // A switch or a pin whose save fails changes nothing, stamps included.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: runtime.path)
    let before = try controller.listWorkspaces()
    var refused = 0
    do { try controller.selectWorkspace(b.workspaceID) } catch { refused += 1 }
    do { try controller.setWorkspacePinned(b.workspaceID, pinned: true) } catch { refused += 1 }
    do { try controller.selectPane(try controller.listPanes().first { $0.workspaceID == b.workspaceID }!.id) } catch { refused += 1 }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    try sidebarExpect(refused == 3, "\(3 - refused) change(s) whose save failed reported success")
    try sidebarExpect(try controller.listWorkspaces() == before, "a change whose save failed stayed in memory")

    // Older state files carry neither field.
    let legacy = #"{"id":"old","name":"Old","attachedFolders":[],"isActive":false,"automationPolicy":"askAndDelegate","workspaceID":"old"}"#
    let decoded = try JSONDecoder().decode(WorkbenchWorkspace.self, from: Data(legacy.utf8))
    try sidebarExpect(!decoded.pinned && decoded.lastSelectedAt == nil, "an older workspace record did not decode as unpinned and never selected")
}

/// The app reads the rules above rather than restating them: the badges come
/// from the cached index, and the sidebar draws the sections in the agreed order.
func checkWorkspaceSidebarWiring() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let model = SwiftSourceReader(try String(contentsOf: sources.appendingPathComponent("ParleyNative/AppModel.swift"), encoding: .utf8))
    func body(_ reader: SwiftSourceReader, _ signature: String) throws -> String {
        guard let found = reader.text.range(of: signature),
              let open = reader.text[found.upperBound...].firstIndex(of: "{"), let body = reader.balanced(at: open) else {
            throw NSError(domain: "WorkspaceSidebar", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(signature) was not found"])
        }
        return String(body)
    }
    try sidebarExpect(try body(model, "var workspaces: [WorkbenchWorkspace] = []").contains("attentionInputGeneration &+= 1"),
                      "a workspace change does not invalidate the workspace activity index")
    for helper in ["func unreadResultCount(forWorkspace", "func waitingCount(for", "func failureCount(for", "func requiresHumanAttention("] {
        let text = try body(model, helper)
        try sidebarExpect(text.contains("workspaceActivity(for:") && !text.contains("handoffs"), "\(helper) scans handoffs again")
    }
    let view = SwiftSourceReader(try String(contentsOf: sources.appendingPathComponent("ParleyNative/ContentView.swift"), encoding: .utf8))
    let sectioned = try body(view, "private var sectionedSidebar: some View")
    let headers = ["\"THIS WORKSPACE\"", "\"NEEDS ATTENTION\"", "\"PINNED\"", "\"RECENT\"", "ALL WORKSPACES ("]
    let positions = headers.map { sectioned.range(of: $0)?.lowerBound }
    try sidebarExpect(!positions.contains(nil) && zip(positions, positions.dropFirst()).allSatisfy { $0! < $1! },
                      "the sidebar sections are missing or out of order")
    try sidebarExpect(sectioned.contains("model.workspaceSidebarSections") && sectioned.contains("movePinnedWorkspaces"),
                      "the sidebar does not draw the derived sections")
    try sidebarExpect(try body(view, "private func workspaceMenuItems(").contains("Pin to Sidebar"), "workspaces cannot be pinned")
    // Mark Seen must be reachable for a failure, which has no result text.
    let history = try body(view, "private func activityHistoryItem(")
    guard let resultBlock = history.range(of: "if let result = item.resultText"),
          let open = history[resultBlock.upperBound...].firstIndex(of: "{"),
          let resultBody = SwiftSourceReader(String(history[open...])).balanced(at: String(history[open...]).startIndex) else {
        throw NSError(domain: "WorkspaceSidebar", code: 4, userInfo: [NSLocalizedDescriptionKey: "the history menu's result block was not found"])
    }
    try sidebarExpect(history.contains("Mark Seen") && !resultBody.contains("Mark Seen"),
                      "Mark Seen is offered only inside the result block, which a failure never reaches")
}

@MainActor let workspaceSidebarChecks: [(String, () throws -> Void)] = [
    ("workspace sidebar sections at fifty workspaces", checkWorkspaceSidebarSectionsAtFiftyWorkspaces),
    ("workspace activity matches the per-workspace scans", checkWorkspaceActivityMatchesPerWorkspaceScans),
    ("workspace pins and recency persist and roll back", checkWorkspacePinsAndRecencyPersist),
    ("workspace sidebar draws the derived sections", checkWorkspaceSidebarWiring),
    ("needs attention clears when a failure is seen or a day old", checkNeedsAttentionClearsWhenSeenOrOld),
]
