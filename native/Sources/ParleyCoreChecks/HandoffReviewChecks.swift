import Dispatch
import Foundation
import ParleyCore

private enum HandoffReviewCheckFailure: Error {
    case failed(String)
}

private final class HandoffReviewResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RelayTextResponse?

    var value: RelayTextResponse? {
        lock.withLock { stored }
    }

    func set(_ value: RelayTextResponse) {
        lock.withLock { stored = value }
    }
}

private func reviewExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HandoffReviewCheckFailure.failed(message) }
}

private func reviewRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw HandoffReviewCheckFailure.failed(message) }
    return value
}

private func reviewEventually(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return condition()
}

private func reviewPane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
    WorkbenchPane(
        id: id,
        kind: kind,
        customName: name,
        terminalTitle: "PRIVATE TITLE",
        cwd: "/private/project",
        currentCommand: "PRIVATE COMMAND",
        isActive: id == "%review-source",
        workspaceID: "@review",
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "Review",
        inputAvailable: true
    )
}

func checkLinkedHandoffReviewPrimitives() throws {
    let directory = URL(
        fileURLWithPath: "/tmp/parley-review-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
    let source = reviewPane("%review-source", .codex, "Owner")
    let implementer = reviewPane("%review-implementer", .claude, "Implementer")
    let reviewer = reviewPane("%review-reviewer", .copilot, "Reviewer")
    let sourceToken = try credentials.token(for: source.id)
    let implementerToken = try credentials.token(for: implementer.id)
    let reviewerToken = try credentials.token(for: reviewer.id)
    let panes = [source, implementer, reviewer]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "handoff-review-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let control = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "wrong-control")

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: implementer.id,
        text: "Implement the reviewed change.",
        idempotencyKey: "review-parent-delegate"
    )
    let parentID = try reviewRequire(delegated.body.handoffID, "parent delegation returned no identity")
    let completed = broker.handleDelegationResult(
        token: implementerToken,
        handoffID: parentID,
        text: "Implemented with deterministic checks.",
        succeeded: true
    )
    try reviewExpect(completed.status == 200, "parent delegation did not complete")
    let parent = try reviewRequire(
        broker.handoffs().first(where: { $0.id == parentID }),
        "completed parent handoff disappeared"
    )

    let missingParent = try control.reviewAskFromUI(
        sourcePaneID: source.id,
        targetPaneID: reviewer.id,
        text: "Challenge this result.",
        idempotencyKey: "review-missing-parent",
        inReplyToHandoffID: "missing-parent",
        relationship: .challenge
    )
    try reviewExpect(missingParent.status == 404, "review Ask accepted a missing parent")

    let responseBox = HandoffReviewResponseBox()
    DispatchQueue.global(qos: .utility).async {
        responseBox.set((try? control.reviewAskFromUI(
            sourcePaneID: source.id,
            targetPaneID: reviewer.id,
            text: """
            Challenge the assumptions in this result:

                let retained = true
            """,
            idempotencyKey: "review-child-challenge",
            inReplyToHandoffID: parentID,
            relationship: .challenge
        )) ?? RelayTextResponse(status: 599, text: "native review client failed"))
    }
    try reviewExpect(
        reviewEventually { broker.consultations().contains(where: { $0.targetPaneID == reviewer.id }) },
        "linked review Ask did not create a correlated consultation"
    )
    let consultation = try reviewRequire(
        broker.consultations().first(where: { $0.targetPaneID == reviewer.id }),
        "linked review consultation disappeared"
    )
    let answered = broker.handleAnswer(
        token: reviewerToken,
        consultationID: consultation.id,
        text: "The implementation did not test recovery after restart."
    )
    try reviewExpect(answered.status == 200, "reviewer could not return the linked answer")
    try reviewExpect(reviewEventually { responseBox.value?.status == 200 }, "linked review Ask did not return")

    let child = try reviewRequire(
        broker.handoffs().first(where: { $0.id == consultation.id }),
        "linked child handoff disappeared"
    )
    try reviewExpect(child.inReplyToHandoffID == parentID, "linked handoff lost its parent")
    try reviewExpect(child.relationship == .challenge, "linked handoff lost its Challenge purpose")
    try reviewExpect(
        child.text.contains("\n\n    let retained = true"),
        "linked review Ask flattened the returned result formatting"
    )

    let rejectedReview = try unauthorized.updateHandoffReview(RelayHandoffReviewUpdate(
        handoffID: parentID,
        expectedReviewRevision: parent.reviewRevision ?? 0,
        verdict: .accepted,
        note: "An unauthenticated UI must not save this."
    ))
    try reviewExpect(rejectedReview.status == 401, "unauthenticated UI changed a human review")

    let saved = try control.updateHandoffReview(RelayHandoffReviewUpdate(
        handoffID: parentID,
        expectedReviewRevision: parent.reviewRevision ?? 0,
        verdict: .needsChanges,
        note: "Add a restart-recovery check before accepting this result."
    ))
    try reviewExpect(saved.status == 200, "person-owned review did not save")
    let stale = try control.updateHandoffReview(RelayHandoffReviewUpdate(
        handoffID: parentID,
        expectedReviewRevision: parent.reviewRevision ?? 0,
        verdict: .accepted,
        note: "This stale edit must not win."
    ))
    try reviewExpect(stale.status == 409, "stale review overwrote the current verdict")

    let reviewedParent = try reviewRequire(
        broker.handoffs().first(where: { $0.id == parentID }),
        "reviewed parent handoff disappeared"
    )
    try reviewExpect(reviewedParent.humanVerdict == .needsChanges, "human verdict was not retained")
    try reviewExpect(
        reviewedParent.humanReviewNote == "Add a restart-recovery check before accepting this result.",
        "human review note was not retained"
    )
    try reviewExpect(reviewedParent.reviewedAt != nil, "human review time was not retained")
    try reviewExpect(
        reviewedParent.updatedAt == parent.updatedAt,
        "human review rewrote the handoff lifecycle timestamp"
    )

    let eventResponse = broker.agentEvents(token: sourceToken, since: "beginning")
    let eventPage = try JSONDecoder().decode(RelayAgentEventPage.self, from: Data(eventResponse.text.utf8))
    try reviewExpect(eventPage.events.contains(where: {
        $0.handoffID == child.id
            && $0.inReplyToHandoffID == parentID
            && $0.relationship == .challenge
    }), "content-minimal events lost handoff lineage")

    let part = try ContextPackBuilder().handoffResult(reviewedParent)
    try reviewExpect(part.text.contains("Human verdict: needsChanges"), "Context Pack lost the human verdict")
    try reviewExpect(
        part.text.contains("Add a restart-recovery check before accepting this result."),
        "Context Pack lost the human review note"
    )
    let childPart = try ContextPackBuilder().handoffResult(child)
    try reviewExpect(childPart.text.contains("In reply to: \(parentID)"), "Context Pack lost parent lineage")
    try reviewExpect(childPart.text.contains("Relationship: challenge"), "Context Pack lost review purpose")

    let markdown = CollaborationHistoryMarkdown.document(handoffs: [reviewedParent, child], scopeName: "Review")
    try reviewExpect(markdown.contains("Human verdict: needsChanges"), "history export lost the human verdict")
    try reviewExpect(markdown.contains("In reply to: `\(parentID)`"), "history export lost parent lineage")

    let durable = try reviewRequire(
        journal.handoffs().first(where: { $0.id == parentID }),
        "review update was not written to the durable journal"
    )
    try reviewExpect(durable.humanVerdict == .needsChanges, "journal lost the human verdict")

    let encoded = try JSONEncoder().encode(reviewedParent)
    var legacyObject = try reviewRequire(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
        "could not create a legacy handoff fixture"
    )
    legacyObject.removeValue(forKey: "inReplyToHandoffID")
    legacyObject.removeValue(forKey: "relationship")
    legacyObject.removeValue(forKey: "humanVerdict")
    legacyObject.removeValue(forKey: "humanReviewNote")
    legacyObject.removeValue(forKey: "reviewedAt")
    legacyObject.removeValue(forKey: "reviewRevision")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacy = try JSONDecoder().decode(RelayHandoff.self, from: legacyData)
    try reviewExpect(
        legacy.inReplyToHandoffID == nil
            && legacy.relationship == nil
            && legacy.humanVerdict == nil
            && legacy.humanReviewNote == nil
            && legacy.reviewedAt == nil
            && legacy.reviewRevision == nil,
        "legacy handoff did not load with empty review metadata"
    )
}
