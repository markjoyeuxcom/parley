import Foundation
import ParleyCore

// Delegate This Again (3 October 2026). On 2 October a delegation was
// delivered and never reached Codex; Status Center could say so, but the
// person's only action on a delegation was Cancel Tracking, where an Ask had
// Ask This Again. Agreed with Codex and Agy: person-initiated only, after the
// original has ended, on its own route, with a fresh identity.

private func againExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "DelegateAgain", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func againRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "DelegateAgain", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

private func againPane(_ id: String, _ kind: PaneKind, started: Bool = true) -> WorkbenchPane {
    WorkbenchPane(
        id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/project", currentCommand: "x",
        isActive: false, workspaceID: "@again", relayEnabled: true, protocolVersion: AgentProtocol.version,
        workspaceName: "Again", inputAvailable: true, isStarted: started
    )
}

private final class SubmittedTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] { lock.withLock { stored } }
    func append(_ text: String) { lock.withLock { stored.append(text) } }
}

func checkDelegateAgainRepeatsOnlyAnEndedDelegationOnItsRoute() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-delegate-again-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let lead = againPane("lead", .claude)
    let worker = againPane("worker", .codex)
    let other = againPane("other", .agy)
    let panes = [lead, worker, other]
    let leadToken = try credentials.token(for: lead.id)
    let workerToken = try credentials.token(for: worker.id)
    _ = try credentials.token(for: other.id)
    let submitted = SubmittedTexts()
    let broker = RelayBroker(
        credentials: credentials, panes: { panes },
        paste: { _, _ in }, submit: { _, text in submitted.append(text) },
        consultationTimeout: 2, livenessPollInterval: 0.01
    )

    let original = broker.handleDelegate(token: leadToken, target: worker.id, text: "Implement the fix.", idempotencyKey: "again-original")
    let originalID = try againRequire(original.body.handoffID, "the original delegation was not created")

    // Active: the original still owns its target.
    let whileActive = broker.handleDelegateAgainFromUI(
        sourcePaneID: lead.id, targetPaneID: worker.id, text: "Implement the fix.",
        idempotencyKey: "again-while-active", repeatsHandoffID: originalID
    )
    try againExpect(whileActive.status == 409 && (whileActive.body.error ?? "").contains("still active"),
                    "an active delegation was repeated: \(whileActive.status) \(whileActive.body.error ?? "")")
    try againExpect(CollaborationHistoryRepeat.delegateRoute(for: try againRequire(broker.handoffs().first { $0.id == originalID }, "original"), panes: panes) == nil,
                    "an active delegation offered Delegate This Again")

    try againExpect(broker.cancelHandoff(originalID).status == 200, "the original's tracking could not be cancelled")
    let cancelled = try againRequire(broker.handoffs().first { $0.id == originalID }, "the original disappeared")
    try againExpect(CollaborationHistoryRepeat.delegateRoute(for: cancelled, panes: panes) == RepeatAskRoute(sourcePaneID: lead.id, targetPaneID: worker.id),
                    "a cancelled delegation on a ready route did not offer Delegate This Again")
    try againExpect(CollaborationHistoryRepeat.delegateRoute(for: cancelled, panes: [lead, againPane("worker", .codex, started: false)]) == nil,
                    "a stopped target was offered")

    // Only the original route, only a delegation, never from a pane.
    let elsewhere = broker.handleDelegateAgainFromUI(
        sourcePaneID: lead.id, targetPaneID: other.id, text: "Implement the fix.",
        idempotencyKey: "again-elsewhere", repeatsHandoffID: originalID
    )
    try againExpect(elsewhere.status == 409, "a repeat went to a different target: \(elsewhere.status)")
    let unknown = broker.handleDelegateAgainFromUI(
        sourcePaneID: lead.id, targetPaneID: worker.id, text: "Implement the fix.",
        idempotencyKey: "again-unknown", repeatsHandoffID: "00000000-0000-0000-0000-000000000000"
    )
    try againExpect(unknown.status == 404, "an unknown original was accepted: \(unknown.status)")
    let fromPane = broker.handleDelegate(
        token: leadToken, target: worker.id, text: "Implement the fix.",
        idempotencyKey: "again-from-pane", repeatsHandoffID: originalID
    )
    try againExpect(fromPane.status == 403, "a pane credential repeated a delegation: \(fromPane.status)")
    try againExpect(broker.handoffs().count == 1, "a refused repeat still recorded a handoff")

    // The repeat: a new identity, the edited text, the link, human origin.
    let repeated = broker.handleDelegateAgainFromUI(
        sourcePaneID: lead.id, targetPaneID: worker.id, text: "Implement the fix.\n\n    keep this indentation",
        idempotencyKey: "again-repeat", repeatsHandoffID: originalID
    )
    try againExpect(repeated.status == 200, "Delegate This Again failed: \(repeated.status) \(repeated.body.error ?? "")")
    let repeatedID = try againRequire(repeated.body.handoffID, "the repeat has no identity")
    try againExpect(repeatedID != originalID, "the repeat reused the original's identity")
    let child = try againRequire(broker.handoffs().first { $0.id == repeatedID }, "the repeat is not recorded")
    try againExpect(child.repeatsHandoffID == originalID, "the repeat does not name the original")
    try againExpect(child.inReplyToHandoffID == nil && child.relationship == nil, "a repeat was recorded as review lineage")
    try againExpect(child.transitions.first?.origin == .human, "the repeat was not recorded as the person's")
    try againExpect(child.text.contains("\n\n    keep this indentation"), "the repeat flattened the edited task")
    try againExpect(submitted.all.last?.contains(repeatedID) == true, "the delivered task does not name the new delegation's id")
    let after = try againRequire(broker.handoffs().first { $0.id == originalID }, "the original disappeared")
    try againExpect(after == cancelled, "repeating changed the original record")

    // Busy: a second repeat while the first is active is refused, not queued.
    let busy = broker.handleDelegateAgainFromUI(
        sourcePaneID: lead.id, targetPaneID: worker.id, text: "Implement the fix.",
        idempotencyKey: "again-busy", repeatsHandoffID: originalID
    )
    try againExpect(busy.status == 409 && (busy.body.error ?? "").contains("tracked work"), "a busy target accepted a repeat: \(busy.status)")
    try againExpect(broker.reviewedBusyDrafts().isEmpty, "a refused repeat entered the busy queue")
    try againExpect(broker.handleDelegationResult(token: workerToken, handoffID: repeatedID, text: "Done.", succeeded: true).status == 200,
                    "the repeat could not be completed")

    // An Ask is not a delegation to repeat.
    let markdown = CollaborationHistoryMarkdown.document(handoffs: broker.handoffs(), scopeName: "Again")
    try againExpect(markdown.contains("- Repeats: `\(originalID)`"), "the history export lost the repeat link")
}

/// A record written before the field existed decodes with no repeat, and a
/// record without one writes no key, so an older Parley reads it unchanged.
func checkRepeatLinkIsAbsentFromOlderRecords() throws {
    // Decoded as the journal would, from a record written before the field.
    let older: [String: Any] = [
        "id": "h1", "idempotencyKey": "k1", "kind": "delegate",
        "sourcePaneID": "lead", "sourceName": "Lead", "sourceKind": "claude",
        "sourceWorkspaceID": "@again", "sourceWorkspaceName": "Again",
        "targetPaneID": "worker", "targetName": "Worker", "targetKind": "codex",
        "targetWorkspaceID": "@again", "targetWorkspaceName": "Again",
        "text": "Task.", "submitted": true, "state": "cancelled", "updatedAt": 0,
        "transitions": [["state": "created", "occurredAt": 0, "detail": NSNull()]],
    ]
    let handoff = try JSONDecoder().decode(RelayHandoff.self, from: JSONSerialization.data(withJSONObject: older))
    try againExpect(handoff.repeatsHandoffID == nil, "an older record decoded with a repeat")
    let data = try JSONEncoder().encode(handoff)
    try againExpect(!String(decoding: data, as: UTF8.self).contains("repeatsHandoffID"), "a record with no repeat writes the key")
    var repeated = handoff
    repeated.repeatsHandoffID = "h0"
    try againExpect(try JSONDecoder().decode(RelayHandoff.self, from: JSONEncoder().encode(repeated)).repeatsHandoffID == "h0",
                    "the repeat link did not survive the journal round trip")
}

/// The advisory row says what to do once the person has looked, and the
/// native action runs off the main thread like the other tracked routes.
func checkDelegateAgainIsOfferedWhereTheAdvisoryIs() throws {
    try againExpect(HandoffStartProjection.recovery(kind: .delegate)?.contains("Delegate This Again") == true, "the advisory does not name Delegate This Again")
    try againExpect(HandoffStartProjection.recovery(kind: .ask)?.contains("Ask This Again") == true, "the advisory does not name Ask This Again")
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let status = SwiftSourceReader(try String(contentsOf: sources.appendingPathComponent("ParleyNative/StatusCenterView.swift"), encoding: .utf8)).text
    try againExpect(status.contains("model.delegateAgain(handoff)") && status.contains("\"Delegate This Again…\""), "Status Center does not offer Delegate This Again")
    try againExpect(status.contains("HandoffStartProjection.recovery(kind: handoff.kind)"), "the advisory row does not show its recovery")
    let app = SwiftSourceReader(try String(contentsOf: sources.appendingPathComponent("ParleyNative/AppModel.swift"), encoding: .utf8))
    guard let start = app.text.range(of: "func delegateAgain(_ handoff: RelayHandoff)"),
          let open = app.text[start.upperBound...].firstIndex(of: "{"),
          let body = app.balanced(at: open) else { throw NSError(domain: "DelegateAgain", code: 2, userInfo: [NSLocalizedDescriptionKey: "delegateAgain is gone"]) }
    try againExpect(body.contains("Task.detached") && body.contains("relayClient.delegateAgainFromUI("), "Delegate This Again does not run off the main thread")
    try againExpect(body.contains("handoffReviewTargetIsBusy(target)"), "Delegate This Again does not refuse a busy target first")
    try againExpect(body.contains("editRelay("), "Delegate This Again sends without the editable preview")
}

@MainActor let delegateAgainChecks: [(String, () throws -> Void)] = [
    ("delegate again repeats only an ended delegation on its route", checkDelegateAgainRepeatsOnlyAnEndedDelegationOnItsRoute),
    ("delegate again link is absent from older records", checkRepeatLinkIsAbsentFromOlderRecords),
    ("delegate again is offered where the advisory is", checkDelegateAgainIsOfferedWhereTheAdvisoryIs),
]
