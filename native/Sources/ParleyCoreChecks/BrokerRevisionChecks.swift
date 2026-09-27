import Dispatch
import Foundation
import ParleyCore

private func revisionExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "BrokerRevision", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// The relay tick and Status Center's history fetch both skip a fetch while
/// the broker's revision is unchanged, so every change to a handoff the UI
/// reads must advance it. Agy's review of MR !111 found two that did not.
private final class RevisionPanes: @unchecked Sendable {
    let lock = NSLock()
    var panes: [WorkbenchPane]
    init(_ panes: [WorkbenchPane]) { self.panes = panes }
    var current: [WorkbenchPane] { lock.withLock { panes } }
}

private func revisionPane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/private/\(id)", currentCommand: kind.rawValue,
                  isActive: false, workspaceID: "@revision", relayEnabled: true, protocolVersion: AgentProtocol.version,
                  workspaceName: "Revision", inputAvailable: true)
}

/// A retry whose source or target pane has gone marks the handoff failed
/// with target-unavailable attention, and returned without advancing the
/// revision: the change waited up to fifteen ticks to appear.
func checkRetryOfAVanishedPaneAdvancesTheRevision() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-revision-retry-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "source")
    _ = try credentials.token(for: "target")
    let panes = RevisionPanes([revisionPane("source", .agy, "Agy"), revisionPane("target", .codex, "Codex")])
    let broker = RelayBroker(credentials: credentials, panes: { panes.current }, paste: { _, _ in },
                             submit: { _, _ in throw ParleyWorkbenchError.unsafeRelayTarget("Codex") })
    let failed = broker.handle(token: sourceToken, target: "codex", text: "Review this.", idempotencyKey: "revision-retry")
    let handoffID = try revisionRequire(failed.body.handoffID, "the failed relay returned no handoff id")
    try revisionExpect(broker.handoffs().first { $0.id == handoffID }?.canRetrySafely == true, "the fixture relay cannot be retried safely")

    panes.lock.withLock { panes.panes.removeAll { $0.id == "target" } }
    let before = broker.stateRevision()
    let retried = broker.retryHandoff(handoffID)
    try revisionExpect(retried.status == 409, "a retry to a closed pane did not refuse: \(retried.status) \(retried.text)")
    try revisionExpect(broker.handoffs().first { $0.id == handoffID }?.attention == .targetUnavailable,
                       "the refused retry did not record target-unavailable attention")
    try revisionExpect(broker.stateRevision() != before, "the refused retry changed the handoff without advancing the broker revision")
}

/// The delegation record is created and noted in one locked section; its
/// delegation-time Git facts are attached in the next, after a capture that
/// runs outside the lock. That attach did not advance the revision, so a
/// reader that fetched during the capture kept the record without them.
func checkDelegationGitFactsAdvanceTheRevision() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-revision-git-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let leadToken = try credentials.token(for: "lead")
    _ = try credentials.token(for: "worker")
    let panes = [revisionPane("lead", .claude, "Claude"), revisionPane("worker", .codex, "Codex")]
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var duringCapture: UInt64?
        var atSubmit: UInt64?
        var factsAtSubmit = false
        weak var broker: RelayBroker?
    }
    let seen = Seen()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            guard let broker = seen.broker else { return }
            let revision = broker.stateRevision()
            let facts = broker.handoffs().first?.gitFactsAtDelegation != nil
            seen.lock.withLock { seen.atSubmit = revision; seen.factsAtSubmit = facts }
        },
        gitFacts: { folder in
            // A reader that fetches now sees the created record without facts.
            let revision = seen.broker?.stateRevision()
            seen.lock.withLock { seen.duringCapture = revision }
            return .notCaptured(folder: folder, capturedAt: Date(), reason: "fixture")
        }
    )
    seen.broker = broker
    let delegated = broker.handleDelegate(token: leadToken, target: "worker", text: "Do the work.", idempotencyKey: "revision-git")
    try revisionExpect(delegated.status == 200, "the delegation failed: \(delegated.status)")
    let (during, atSubmit, facts) = seen.lock.withLock { (seen.duringCapture, seen.atSubmit, seen.factsAtSubmit) }
    try revisionExpect(during != nil && atSubmit != nil && facts, "the fixture did not observe the capture and the submit")
    try revisionExpect(atSubmit != during, "attaching delegation-time Git facts did not advance the broker revision")
}

private func revisionRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "BrokerRevision", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

@MainActor let brokerRevisionChecks: [(String, () throws -> Void)] = [
    ("a retry to a vanished pane advances the broker revision", checkRetryOfAVanishedPaneAdvancesTheRevision),
    ("attaching delegation git facts advances the broker revision", checkDelegationGitFactsAdvanceTheRevision),
]
