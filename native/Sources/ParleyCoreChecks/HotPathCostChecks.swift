import Darwin
import Foundation
import ParleyCore

// Informational measurements for the callback and rendering hot paths. They
// print numbers and assert only that the paths ran; the same checks run
// before and after a change so the report can quote both.

private func hotExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "HotPath", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func hotMilliseconds(_ iterations: Int, _ work: () throws -> Void) throws -> Double {
    try work()
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { try work() }
    return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 / Double(iterations)
}

private func hotPane(_ id: String, _ kind: PaneKind, _ name: String, workspace: String = "workspace") -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/tmp", currentCommand: kind.rawValue,
        isActive: false, workspaceID: workspace, relayEnabled: true, workspaceName: "Perf", automationPolicy: .askAndDelegate,
        launchGeneration: 1)
}

private func hotTemporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp/parley-hot-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func inode(of path: String) -> UInt64 {
    var metadata = stat()
    return Darwin.lstat(path, &metadata) == 0 ? UInt64(metadata.st_ino) : 0
}

/// 500 relayed handoffs through a real broker, the same shape the tick check uses.
private func hotHandoffFixture(directory: URL, count: Int = 500) throws -> (handoffs: [RelayHandoff], panes: [WorkbenchPane]) {
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"), maximumHandoffs: count + 100)
    let source = hotPane("perf-source", .claude, "Source")
    let target = hotPane("perf-target", .codex, "Target")
    let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in }, handoffJournal: journal)
    let token = try credentials.token(for: source.id)
    let body = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
    for index in 0..<count {
        let response = broker.handle(token: token, target: target.id, text: "\(index) \(body)", idempotencyKey: "perf-relay-\(index)")
        try hotExpect(response.status == 200, "fixture relay \(index) failed with \(response.status)")
    }
    var panes = [source, target]
    for index in 0..<6 { panes.append(hotPane("pane-\(index)", index % 2 == 0 ? .agy : .copilot, "Pane \(index)")) }
    return (broker.handoffs(), panes)
}

func titleBurstCostChecks() throws {
    // One Ghostty title burst against a real controller: how many state-file
    // writes and how much wall time 200 distinct titles cost.
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-title-cost-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    _ = try controller.createWorkspace(folder: root.appendingPathComponent("project").path)
    let pane = try controller.createPane(kind: .claude, cwd: root.appendingPathComponent("project").path)
    let stateFile = root.appendingPathComponent("runtime/workbench-state.json").path
    var inodes: Set<UInt64> = [inode(of: stateFile)]
    let started = DispatchTime.now().uptimeNanoseconds
    for index in 0..<200 {
        try controller.terminalDidChangeTitle(paneID: pane.id, title: "✳ Thinking… \(index)")
        inodes.insert(inode(of: stateFile))
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    let writesObserved = inodes.count - 1
    let repeated = try hotMilliseconds(200) { try controller.terminalDidChangeTitle(paneID: pane.id, title: "✳ Thinking… 199") }
    print(String(format: "  title burst: 200 distinct titles took %.1f ms; state-file rewrites observed during the burst: %d", elapsed, writesObserved))
    print(String(format: "  repeated identical title: %.3f ms per callback", repeated))
    try hotExpect(try controller.listPanes().first { $0.id == pane.id }?.terminalTitle == "✳ Thinking… 199", "the last title was not applied")
}

func attentionProjectionCostChecks() throws {
    let directory = try hotTemporaryDirectory()
    let fixture = try hotHandoffFixture(directory: directory)
    let panes = fixture.panes
    let handoffs = fixture.handoffs
    let once = try hotMilliseconds(20) { _ = PaneAttentionProjection.items(panes: panes, handoffs: handoffs) }
    // What one sidebar pass costs today: the projection is rebuilt for every
    // pane row, header and focus-strip item that asks.
    let perPass = try hotMilliseconds(5) {
        for pane in panes { _ = PaneAttentionProjection.primary(forPaneID: pane.id, in: PaneAttentionProjection.items(panes: panes, handoffs: handoffs)) }
    }
    // The same pass through the generation-keyed cache the model uses.
    var cache = PaneAttentionCache()
    let cachedPass = try hotMilliseconds(5) {
        for pane in panes { _ = PaneAttentionProjection.primary(forPaneID: pane.id, in: cache.items(generation: 1, panes: panes, handoffs: handoffs)) }
    }
    print(String(format: "  attention projection over %d handoffs and %d panes: %.3f ms once; %.2f ms per sidebar pass rebuilt per row; %.3f ms per pass through the cache", handoffs.count, panes.count, once, perPass, cachedPass))
    try hotExpect(once > 0 && perPass >= once && cache.computeCount == 1, "the projection did not run or the cache recomputed")
}

func historyFilterCostChecks() throws {
    let directory = try hotTemporaryDirectory()
    let fixture = try hotHandoffFixture(directory: directory)
    let handoffs = fixture.handoffs
    let filter = CollaborationHistoryFilter(query: "fox", kind: .all, outcome: .all)
    let once = try hotMilliseconds(20) { _ = CollaborationHistoryProjection.filter(handoffs, using: filter) }
    // The history section evaluates the filter for the count, the export
    // buttons, the empty check, the ForEach and once more per materialised
    // row; 20 visible rows is a typical window.
    let perRender = try hotMilliseconds(5) {
        for _ in 0..<24 { _ = CollaborationHistoryProjection.filter(handoffs, using: filter) }
    }
    print(String(format: "  history filter over %d handoffs: %.3f ms once (the one-pass render); %.2f ms per render evaluated 24 times as before", handoffs.count, once, perRender))
    try hotExpect(once > 0, "the filter did not run")
}

func activityJournalRecordCostChecks() throws {
    let directory = try hotTemporaryDirectory()
    let file = directory.appendingPathComponent("activity-events.jsonl")
    let journal = try RelayActivityJournal(file: file, maximumEvents: 500)
    for index in 0..<500 {
        try journal.record(RelayActivityEvent(id: "seed-\(index)", kind: .paneRestarted, occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
            workspaceID: "@0", workspaceName: "api", paneID: "%1", paneName: "Codex", paneKind: .codex, detail: "seed \(index)"))
    }
    var counter = 1_000
    let before = inode(of: file.path)
    let perRecord = try hotMilliseconds(50) {
        counter += 1
        try journal.record(RelayActivityEvent(id: "event-\(counter)", kind: .paneRestarted, occurredAt: Date(timeIntervalSince1970: TimeInterval(counter)),
            workspaceID: "@0", workspaceName: "api", paneID: "%1", paneName: "Codex", paneKind: .codex, detail: "event \(counter)"))
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    print(String(format: "  activity journal at 500 retained events: %.2f ms per record (file %d KB; inode %@ across records)", perRecord, size / 1_024,
        inode(of: file.path) == before ? "unchanged" : "replaced"))
    try hotExpect(perRecord > 0 && journal.events().count == 500, "the journal did not retain 500 events")
}

func transportTickCostChecks() throws {
    // The service tick without the broker: the directory reads it performs
    // for N endpoints, timed on this machine, then scaled to the 50 ms cadence.
    let root = try hotTemporaryDirectory()
    let manager = FileManager.default
    for index in 0..<5 {
        let endpoint = root.appendingPathComponent("pane-\(index)", isDirectory: true)
        for name in ["inbox", "processing", "outbox"] {
            try manager.createDirectory(at: endpoint.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: endpoint.path)
    }
    var syscallsPerTick = 0
    let tick = try hotMilliseconds(200) {
        syscallsPerTick = 0
        let endpoints = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        syscallsPerTick += 3 // open, getdirentries, close
        for endpoint in endpoints {
            var metadata = stat()
            _ = Darwin.lstat(endpoint.path, &metadata)
            syscallsPerTick += 1
            _ = try manager.contentsOfDirectory(at: endpoint.appendingPathComponent("inbox"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            syscallsPerTick += 3
        }
    }
    print(String(format: "  transport tick with 5 idle endpoints: %.3f ms per tick; ~%d directory syscalls per tick, ~%d per second at 50 ms (plus 5 heartbeat writes per second)", tick, syscallsPerTick, syscallsPerTick * 20))
    try hotExpect(tick > 0, "the tick simulation did not run")
}

@MainActor
let hotPathCostChecks: [(String, () throws -> Void)] = [
    ("title burst cost (informational)", titleBurstCostChecks),
    ("attention projection cost (informational)", attentionProjectionCostChecks),
    ("history filter cost (informational)", historyFilterCostChecks),
    ("activity journal record cost (informational)", activityJournalRecordCostChecks),
    ("transport tick cost (informational)", transportTickCostChecks),
]
