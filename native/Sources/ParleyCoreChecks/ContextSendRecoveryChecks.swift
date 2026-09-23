import Foundation
import ParleyCore

private func recoveryExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ContextSendRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func recoveryRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "ContextSendRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// Agy's review of MR !101 (844fa81d): sending an agent-staged context draft
/// closed it before the send, so a send that failed lost the person's edits.
/// Each way a send can fail is driven through a real broker, and the
/// recovery decision follows the review the core leaves behind.
func checkContextSendRecoveryKeepsEditsOnlyWhenNothingWasDelivered() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-ctxsend-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: directory.path, currentCommand: "x", isActive: false,
                      workspaceID: "@ctx", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Ctx", inputAvailable: true)
    }
    let source = pane("source", .claude), target = pane("target", .codex), lead = pane("lead", .agy)
    final class Delivery: @unchecked Sendable { var fail = false }
    let delivery = Delivery()
    let broker = RelayBroker(credentials: credentials, panes: { [source, target, lead] }, paste: { _, _ in },
                             submit: { paneID, _ in if delivery.fail { throw ParleyWorkbenchError.unsafeRelayTarget(paneID) } },
                             consultationTimeout: 1, livenessPollInterval: 0.01,
                             contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json")))
    func stage(_ name: String) throws -> AgentContextReview {
        let file = directory.appendingPathComponent("\(name).md")
        try "original \(name)\n".write(to: file, atomically: true, encoding: .utf8)
        let staged = broker.handleContextDraft(token: try credentials.token(for: source.id), name: name, path: file.path, text: "original \(name)\n")
        try recoveryExpect(staged.status == 201, "the draft was not staged: \(staged.text)")
        return try recoveryRequire(broker.contextReviews().first { $0.pack.name == name || $0.pack.parts.contains { $0.text.contains(name) } }, "the staged draft is missing")
    }
    func edited(_ review: AgentContextReview) -> ContextPack {
        var pack = review.pack
        pack.note = "edited note"
        pack.parts = pack.parts.map { ContextPackPart(id: $0.id, source: $0.source, capturedText: $0.capturedText, text: "edited by the person") }
        return pack
    }
    func send(_ review: AgentContextReview, pack: ContextPack, revision: Date, key: String) -> RelayTextResponse {
        broker.completeContextDraft(AgentContextReviewApproval(reviewID: review.id, expectedUpdatedAt: revision,
            targetPaneID: target.id, pack: pack, idempotencyKey: key))
    }
    func decide(_ review: AgentContextReview, sent: ContextPack, revision: Date) -> ContextSendRecovery {
        ContextSendRecovery.decide(reviewID: review.id, sent: sent, sentRevision: revision, fresh: broker.contextReviews())
    }
    func fail(_ message: String) -> NSError { NSError(domain: "ContextSendRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    // Never reached the core (a control-socket failure): the review is untouched.
    let untouched = try stage("untouched")
    guard case let .reopen(fresh) = decide(untouched, sent: edited(untouched), revision: untouched.updatedAt),
          fresh.state == .draft, fresh.updatedAt == untouched.updatedAt else { throw fail("an untouched draft was not reopened at its revision") }

    // Refused before delivery (the target is busy): the core hands it back as a
    // draft holding the person's edits, at a new revision, and a resend at that
    // revision is accepted.
    let busy = broker.handleDelegate(token: try credentials.token(for: lead.id), target: target.id, text: "Busy.", idempotencyKey: "ctx-busy")
    let busyID = try recoveryRequire(busy.body.handoffID, "the busy delegation returned no id")
    let refusedDraft = try stage("refused")
    let edits = edited(refusedDraft)
    try recoveryExpect(send(refusedDraft, pack: edits, revision: refusedDraft.updatedAt, key: "ctx-refused").status != 200, "a send to a busy target succeeded")
    guard case let .reopen(handedBack) = decide(refusedDraft, sent: edits, revision: refusedDraft.updatedAt),
          handedBack.updatedAt != refusedDraft.updatedAt, handedBack.pack.note == "edited note" else {
        throw fail("a refused draft was not reopened with the person's edits at its new revision")
    }
    _ = broker.handleDelegationResult(token: try credentials.token(for: target.id), handoffID: busyID, text: "Done.", succeeded: true)
    _ = send(refusedDraft, pack: edits, revision: handedBack.updatedAt, key: "ctx-resent")
    try recoveryExpect(broker.contextReviews().first { $0.id == refusedDraft.id }?.state == .completed,
                       "the reopened edits were not accepted at the revision they reopened with")
    // Delivered, then no answer in time: nothing to reopen, and it says so.
    guard case .delivered = decide(refusedDraft, sent: edits, revision: handedBack.updatedAt) else {
        throw fail("a delivered send that then failed was not recognised as delivered")
    }

    // The agent added a part while the person edited: the stale refusal must
    // not reopen the old copy at the new revision, which would drop the part.
    let raced = try stage("raced")
    let added = directory.appendingPathComponent("added.md")
    try "agent addition\n".write(to: added, atomically: true, encoding: .utf8)
    try recoveryExpect(broker.handleContextAdd(token: try credentials.token(for: source.id), draftID: raced.id, path: added.path, text: "agent addition\n").status < 300,
                       "the agent could not add a part")
    let racedEdits = edited(raced)
    try recoveryExpect(send(raced, pack: racedEdits, revision: raced.updatedAt, key: "ctx-raced").status == 409, "a stale send was not refused")
    guard case let .changed(current) = decide(raced, sent: racedEdits, revision: raced.updatedAt),
          current.pack.parts.count == raced.pack.parts.count + 1 else {
        throw fail("a draft the agent changed was reopened as the person's old copy")
    }

    // The agent turned the draft into an Ask while the person edited: the
    // person's copy must not become the approval of a request they never saw.
    let asked = try stage("asked")
    let askedEdits = edited(asked)
    let finished = DispatchSemaphore(value: 0)
    let sourceToken = try credentials.token(for: source.id)
    Thread.detachNewThread {
        _ = broker.handleContextAsk(token: sourceToken, draftID: asked.id, target: target.id, text: "Please review this.")
        finished.signal()
    }
    let waitDeadline = Date().addingTimeInterval(3)
    while broker.contextReviews().first(where: { $0.id == asked.id })?.state != .awaitingReview, Date() < waitDeadline { usleep(10_000) }
    let askedDecision = decide(asked, sent: askedEdits, revision: asked.updatedAt)
    _ = finished.wait(timeout: .now() + 5)
    guard case let .changed(awaiting) = askedDecision, awaiting.state == .awaitingReview else {
        throw fail("a draft the agent turned into an Ask was reopened as the person's copy: \(askedDecision)")
    }

    // Delivery failed part-way: offered to copy, never reopened for a second send.
    delivery.fail = true
    let failedDraft = try stage("failed")
    _ = send(failedDraft, pack: edited(failedDraft), revision: failedDraft.updatedAt, key: "ctx-failed")
    delivery.fail = false
    try recoveryExpect(broker.contextReviews().first { $0.id == failedDraft.id }?.state == .failed, "a failed delivery did not mark the review failed")
    guard case .copyOnly = decide(failedDraft, sent: edited(failedDraft), revision: failedDraft.updatedAt) else {
        throw fail("a failed delivery was offered for a second send")
    }

    // State that cannot be read, or a draft no longer listed, is unknown.
    guard case .copyOnly = ContextSendRecovery.decide(reviewID: untouched.id, sent: untouched.pack, sentRevision: untouched.updatedAt, fresh: nil),
          case .copyOnly = ContextSendRecovery.decide(reviewID: "gone", sent: untouched.pack, sentRevision: untouched.updatedAt, fresh: broker.contextReviews()) else {
        throw fail("unknown state was reopened")
    }
}

@MainActor let contextSendRecoveryChecks: [(String, () throws -> Void)] = [
    ("context send recovery keeps edits only when nothing was delivered", checkContextSendRecoveryKeepsEditsOnlyWhenNothingWasDelivered),
]
