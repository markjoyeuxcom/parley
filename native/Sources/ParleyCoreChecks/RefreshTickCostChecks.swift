import Foundation
import ParleyCore

private func tickExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RefreshTickCost", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func tickPane(_ id: String, _ kind: PaneKind, _ name: String, workspace: String = "workspace") -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/tmp", currentCommand: kind.rawValue,
        isActive: false, workspaceID: workspace, relayEnabled: true, workspaceName: "Perf", inputAvailable: true,
        automationPolicy: .askAndDelegate)
}

/// Measures, against a real control server and client, the work the periodic
/// refresh tick used to perform on the main thread: the five relay requests
/// (server encode, socket round trip, client decode) and the Status Center's
/// 500-record history reads. The numbers are printed for the record; the
/// only assertion is that the paths still work.
func refreshTickCostChecks() throws {
    // Unix socket paths are short; keep the fixture under /tmp like the other server checks.
    let directory = URL(fileURLWithPath: "/tmp/parley-tick-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"), maximumHandoffs: 600)
    let activity = try RelayActivityJournal(file: directory.appendingPathComponent("activity-events.jsonl"), maximumEvents: 600)
    let source = tickPane("perf-source", .claude, "Source")
    let target = tickPane("perf-target", .codex, "Target")
    let panes = [source, target]
    let broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in },
        handoffJournal: journal, activityJournal: activity)
    let sourceToken = try credentials.token(for: source.id)

    // A realistic idle workspace after a day of use: 500 relayed handoffs with
    // 4 KB bodies and 500 native activity records.
    let body = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 90)
    for index in 0..<500 {
        let response = broker.handle(token: sourceToken, target: target.id, text: "\(index) \(body)", idempotencyKey: "perf-relay-\(index)")
        try tickExpect(response.status == 200, "fixture relay \(index) failed with \(response.status)")
        _ = try broker.recordActivity(RelayActivityEventRequest(kind: .paneRestarted, workspaceID: "workspace", workspaceName: "Perf",
            paneID: source.id, paneName: source.displayName, paneKind: source.kind, detail: "fixture \(index)"))
    }

    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "tick-cost-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)

    func milliseconds(_ iterations: Int, _ work: () throws -> Void) throws -> Double {
        try work() // warm caches and the socket path once
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { try work() }
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 / Double(iterations)
    }

    let tick = try milliseconds(20) {
        _ = try client.consultations()
        _ = try client.handoffs(limit: 24)
        _ = try client.unreadHandoffs()
        _ = try client.contextReviews()
        _ = try client.reviewedBusyDrafts()
    }
    var recent: [RelayHandoff] = []
    let recentDecodeOnly = try milliseconds(20) { recent = try client.handoffs(limit: 24) }
    let compare = try milliseconds(200) { _ = recent == recent.map { $0 } }
    let statusCenter = try milliseconds(10) {
        _ = try client.handoffs(limit: 500)
        _ = try client.activityEvents(limit: 500)
        _ = try client.historyRetentionPolicy()
        _ = try client.reviewedBusyDrafts()
    }
    // What an unchanged tick costs once the app asks the in-process broker first.
    let revisionBefore = broker.stateRevision()
    let revisionRead = try milliseconds(1000) { _ = broker.stateRevision() }
    _ = broker.handle(token: sourceToken, target: target.id, text: "one more", idempotencyKey: "perf-relay-final")
    try tickExpect(broker.stateRevision() > revisionBefore, "a relay did not advance the broker revision")
    let recentBytes = try JSONEncoder().encode(recent).count
    let historyBytes = try JSONEncoder().encode(try client.handoffs(limit: 500)).count

    print(String(format: "  refresh tick relay work: %.2f ms per tick (5 requests; recent 24 handoffs = %d KB)", tick, recentBytes / 1_024))
    print(String(format: "  handoffs(limit: 24) alone: %.2f ms; equality compare of the decoded array: %.3f ms", recentDecodeOnly, compare))
    print(String(format: "  unchanged tick after revision gating: %.4f ms (one in-process revision read; the 5 requests are skipped)", revisionRead))
    print(String(format: "  Status Center history read: %.2f ms per 2 s tick (500 handoffs = %d KB + 500 activity records)", statusCenter, historyBytes / 1_024))
    try tickExpect(recent.count == 24 && tick > 0 && statusCenter > 0, "the refresh paths did not return data")
}
