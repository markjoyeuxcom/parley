import Foundation
import ParleyCore

// On 2 October 2026 a delegation to a Codex pane was delivered (paste and
// Enter both succeeded) and Codex never received it: its own session record
// shows no turn until the person typed into it six hours later. Parley cannot
// see why and must not read terminal text, but the vendor's authenticated
// turn-start hook says whether a turn began. These pin that fact: stamped on
// the handoff when it arrives, flagged when it has not come a minute after
// delivery, and unknown for a pane that has never reported a hook.

private func startFailure(_ message: String) -> NSError {
    NSError(domain: "HandoffStart", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func startExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw startFailure(message) }
}

private func startPane(_ id: String, _ kind: PaneKind, hookSignal: VendorHookSignal? = nil) -> WorkbenchPane {
    WorkbenchPane(
        id: id, kind: kind, customName: id == "%lead" ? "Lead" : "Worker", terminalTitle: "", cwd: "/private/tmp",
        currentCommand: kind.rawValue, isActive: false, workspaceID: "w", relayEnabled: true,
        protocolVersion: AgentProtocol.version, workspaceName: "Work", inputAvailable: true,
        vendorRuntimeState: hookSignal == nil ? nil : .ready,
        vendorRuntimeSignal: hookSignal, vendorRuntimeSignaledAt: hookSignal == nil ? nil : Date(timeIntervalSinceNow: -600)
    )
}

/// The broker's clock, starting now: it times hook signals, while the
/// handoff's own transitions take the real time.
private final class StartClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor let handoffStartChecks: [(String, () throws -> Void)] = [
    ("a target's turn-start hook is stamped on the handoffs delivered to it, and survives a reload", {
        let directory = URL(fileURLWithPath: "/private/tmp/parley-handoff-start-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
        let lead = startPane("%lead", .claude)
        let worker = startPane("%worker", .codex, hookSignal: .turnEnded)
        let leadToken = try credentials.token(for: lead.id)
        let workerToken = try credentials.token(for: worker.id)
        let clock = StartClock()
        let journalFile = directory.appendingPathComponent("handoffs.jsonl")
        let broker = RelayBroker(credentials: credentials, panes: { [lead, worker] }, paste: { _, _ in }, submit: { _, _ in },
                                 clock: { clock.now }, handoffJournal: try RelayHandoffJournal(file: journalFile))
        let delegated = broker.handleDelegate(token: leadToken, target: "%worker", text: "Review the change")
        try startExpect(delegated.status == 200, "could not delegate: \(delegated.body)")
        let id = try delegated.body.handoffID.map { $0 } ?? { throw startFailure("no handoff id") }()
        try startExpect(broker.handoffs().first { $0.id == id }?.targetTurnStartedAt == nil, "a turn was stamped before any hook arrived")
        // A turn start from another pane stamps nothing here.
        clock.advance(5)
        _ = broker.handleVendorSignal(token: leadToken, signal: "turn-started")
        try startExpect(broker.handoffs().first { $0.id == id }?.targetTurnStartedAt == nil, "another pane's turn was stamped on this handoff")
        // The target's own turn start is stamped once, at the time it came.
        clock.advance(5)
        try startExpect(broker.handleVendorSignal(token: workerToken, signal: "turn-started").status == 200, "the worker's hook was refused")
        let stamped = broker.handoffs().first { $0.id == id }?.targetTurnStartedAt
        try startExpect(stamped == clock.now, "the target's turn start was not stamped at its time: \(String(describing: stamped))")
        clock.advance(5)
        _ = broker.handleVendorSignal(token: workerToken, signal: "turn-started")
        try startExpect(broker.handoffs().first { $0.id == id }?.targetTurnStartedAt == stamped, "a later turn moved the first stamp")
        let reloaded = try RelayHandoffJournal(file: journalFile).handoffs().first { $0.id == id }
        try startExpect(reloaded?.targetTurnStartedAt == stamped, "the stamp did not reach the handoff journal")
    }),
    ("a handoff with no turn a minute after delivery is flagged, only where the target reports turns", {
        let directory = URL(fileURLWithPath: "/private/tmp/parley-handoff-start-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
        let lead = startPane("%lead", .claude)
        let worker = startPane("%worker", .codex, hookSignal: .turnEnded)
        let silent = startPane("%worker", .copilot)
        let leadToken = try credentials.token(for: lead.id)
        let clock = StartClock()
        var panes = [lead, worker]
        let broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in }, clock: { clock.now })
        let delegated = broker.handleDelegate(token: leadToken, target: "%worker", text: "Review the change")
        try startExpect(delegated.status == 200, "could not delegate: \(delegated.body)")
        func handoff() throws -> RelayHandoff {
            try broker.handoffs().first { $0.kind == .delegate } ?? { throw startFailure("no delegation") }()
        }
        let delivered = clock.now
        try startExpect(!HandoffStartProjection.notStarted(try handoff(), target: worker, now: delivered.addingTimeInterval(30)),
                        "a handoff was flagged before a minute had passed")
        try startExpect(HandoffStartProjection.notStarted(try handoff(), target: worker, now: delivered.addingTimeInterval(61))
                        && HandoffStartProjection.turnStarted(try handoff(), target: worker) == false,
                        "a handoff with no turn a minute after delivery was not flagged")
        try startExpect(!HandoffStartProjection.notStarted(try handoff(), target: silent, now: delivered.addingTimeInterval(600))
                        && HandoffStartProjection.turnStarted(try handoff(), target: silent) == nil,
                        "a target that has never reported a hook was flagged instead of unknown")
        // parley status tells the delegating agent the same fact.
        func reported() throws -> Bool? {
            let status = broker.delegationStatus(token: leadToken)
            let items = try JSONDecoder().decode([RelayDelegationStatus].self, from: Data(status.text.utf8))
            return items.first?.targetTurnStarted
        }
        try startExpect(try reported() == false, "parley status did not say no turn has started")
        panes = [lead, silent]
        try startExpect(try reported() == nil, "parley status claimed a fact about a target that reports no hooks")
        panes = [lead, worker]
        clock.advance(70)
        let workerToken = try credentials.token(for: worker.id)
        _ = broker.handleVendorSignal(token: workerToken, signal: "turn-started")
        try startExpect(!HandoffStartProjection.notStarted(try handoff(), target: worker, now: clock.now.addingTimeInterval(600))
                        && (try reported()) == true,
                        "a handoff whose target started a turn is still flagged")
    }),
]
