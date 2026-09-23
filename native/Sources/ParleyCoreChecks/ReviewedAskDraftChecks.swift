import Foundation
import ParleyCore

private func draftExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ReviewedAskDraft", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func draftRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "ReviewedAskDraft", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// Review of 22 September 2026, M9: a person's Ask draft or context pack was
/// cleared as soon as it was sent, so a refusal (the target already had
/// tracked work) lost it; and the busy pre-check read Status Center's history,
/// which stops refreshing when that window closes. The decisions the app makes
/// about a refused Ask live in `ReviewedAskHistory`, checked here against a
/// real broker.
func checkRefusedReviewedAsksAreRecognisedAndBusyStateIsCurrent() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-draft-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/\(id)", currentCommand: "x", isActive: false,
                      workspaceID: "@draft", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Draft", inputAvailable: true)
    }
    let source = pane("source", .claude), target = pane("target", .codex), lead = pane("lead", .agy)
    let leadToken = try credentials.token(for: lead.id)
    let broker = RelayBroker(credentials: credentials, panes: { [source, target, lead] }, paste: { _, _ in }, submit: { _, _ in },
                             consultationTimeout: 1, livenessPollInterval: 0.01,
                             contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json")))

    // The target is busy with a delegation, so the person's Ask is refused
    // before anything reaches it: the draft must come back.
    let delegated = broker.handleDelegate(token: leadToken, target: target.id, text: "Busy work.", idempotencyKey: "draft-busy")
    let busyID = try draftRequire(delegated.body.handoffID, "the busy delegation returned no id")
    let refusedKey = "draft-refused-\(UUID().uuidString.lowercased().prefix(8))"
    let refused = broker.handleAskFromUI(sourcePaneID: source.id, targetPaneID: target.id, text: "A reviewed question.", idempotencyKey: refusedKey)
    try draftExpect(refused.status == 409, "a UI Ask to a busy target was not refused: \(refused.status) \(refused.text)")
    let history = broker.handoffs()
    try draftExpect(!ReviewedAskHistory.reachedTarget(idempotencyKey: refusedKey, in: history),
                    "a refused UI Ask was treated as delivered, so its draft would be lost")
    try draftExpect(ReviewedAskHistory.targetHasTrackedWork(target.id, in: history), "the busy target was not recognised as busy")

    // A delivered Ask that then times out stays sent: bringing the draft back
    // would invite sending the same question twice.
    _ = broker.handleDelegationResult(token: try credentials.token(for: target.id), handoffID: busyID, text: "Done.", succeeded: true)
    let deliveredKey = "draft-delivered-\(UUID().uuidString.lowercased().prefix(8))"
    let timedOut = broker.handleAskFromUI(sourcePaneID: source.id, targetPaneID: target.id, text: "Another question.", idempotencyKey: deliveredKey)
    try draftExpect(timedOut.status == 408, "the delivered Ask did not time out as arranged: \(timedOut.status) \(timedOut.text)")
    try draftExpect(ReviewedAskHistory.reachedTarget(idempotencyKey: deliveredKey, in: broker.handoffs()),
                    "a delivered Ask that timed out was treated as never sent")
    try draftExpect(!ReviewedAskHistory.targetHasTrackedWork(target.id, in: broker.handoffs()), "an idle target was reported busy")

    // Status Center's history stops refreshing when its window closes; the
    // newest record for each handoff wins whichever list carries it.
    let fresh = broker.handoffs()
    let delegation = try draftRequire(fresh.first { $0.id == busyID }, "the delegation disappeared")
    var stale = delegation
    stale.state = .waiting
    stale.updatedAt = delegation.updatedAt.addingTimeInterval(-60)
    let merged = ReviewedAskHistory.newestPerHandoff([stale], fresh.filter { $0.id != busyID } + [delegation])
    try draftExpect(merged.first { $0.id == busyID }?.state == .completed, "a stale waiting record beat the newer completed one")
    try draftExpect(merged.count == Set(merged.map(\.id)).count, "the merged history repeats a handoff")
    try draftExpect(zip(merged, merged.dropFirst()).allSatisfy { $0.updatedAt >= $1.updatedAt }, "the merged history is not newest first")
    try draftExpect(!ReviewedAskHistory.targetHasTrackedWork(target.id, in: merged),
                    "a stale waiting record in one list made the idle target look busy")
}

@MainActor let reviewedAskDraftChecks: [(String, () throws -> Void)] = [
    ("refused reviewed asks are recognised and busy state is current", checkRefusedReviewedAsksAreRecognisedAndBusyStateIsCurrent),
]
