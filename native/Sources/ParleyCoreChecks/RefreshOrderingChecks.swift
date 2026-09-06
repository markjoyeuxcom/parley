import Foundation
import ParleyCore

private func orderExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RefreshOrdering", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func historyHandoff(_ id: String, state: RelayHandoffState = .completed, read: Bool = true) throws -> RelayHandoff {
    // Journal shape, like the Status Center checks: the app never constructs
    // handoffs directly, so fixtures decode the durable form.
    var object: [String: Any] = [
        "id": id, "idempotencyKey": "key-\(id)", "kind": "delegate",
        "sourcePaneID": "a", "sourceName": "A", "sourceKind": "claude", "sourceWorkspaceID": "w", "sourceWorkspaceName": "W",
        "targetPaneID": "b", "targetName": "B", "targetKind": "codex", "targetWorkspaceID": "w", "targetWorkspaceName": "W",
        "text": "body \(id)", "submitted": true, "state": state.rawValue, "updatedAt": 1_000.0,
        "transitions": [["state": state.rawValue, "occurredAt": 1_000.0, "detail": "fixture"]],
    ]
    if state == .completed { object["resultText"] = "done" }
    if read { object["readAt"] = 1_001.0 }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(RelayHandoff.self, from: data)
}

/// Deterministic delayed-fetch regression: a Status Center history fetch that
/// started before Clear History, mark-read or a dismissal completes after the
/// action and must change nothing, prune nothing and notify nobody.
func refreshOrderingChecks() throws {
    let retention = CollaborationHistoryRetentionPolicy.defaultPolicy
    let old = [try historyHandoff("old-1"), try historyHandoff("old-2")]
    var gate = RefreshSequenceGate()

    // Clear History: an older fetch of the pre-clear list lands after the synchronous clear.
    let clearedToken = gate.token()
    let olderFetch = StatusHistoryRefresh.Fetched(handoffs: old, activity: [], retention: retention)
    gate.invalidate() // the explicit refresh inside clearStatusHistory / refreshStatusCenterQuietly
    let cleared = StatusHistoryRefresh.State(handoffs: [], activity: [], retention: retention, dismissedHandoffIDs: [])
    try orderExpect(StatusHistoryRefresh.apply(olderFetch, token: clearedToken, gate: gate, to: cleared) == nil,
        "an older history fetch restored cleared history after Clear History")

    // Mark read: the older fetch still carries the unread result.
    var unread = try historyHandoff("unread", read: false)
    try orderExpect(unread.hasUnreadResult, "the unread fixture is not unread")
    let readToken = gate.token()
    let staleUnread = StatusHistoryRefresh.Fetched(handoffs: [unread], activity: [], retention: retention)
    gate.invalidate() // markRead refreshes synchronously
    unread.readAt = Date()
    let readState = StatusHistoryRefresh.State(handoffs: [unread], activity: [], retention: retention, dismissedHandoffIDs: [])
    try orderExpect(StatusHistoryRefresh.apply(staleUnread, token: readToken, gate: gate, to: readState) == nil,
        "an older history fetch reverted a mark-read")

    // Dismissal preservation: the person dismisses a record that only exists in a newer list.
    let newer = try historyHandoff("new")
    let dismissToken = gate.token()
    let withoutNew = StatusHistoryRefresh.Fetched(handoffs: old, activity: [], retention: retention)
    gate.invalidate() // dismissFromStatusCenter invalidates before mutating
    let dismissed = StatusHistoryRefresh.State(handoffs: old + [newer], activity: [], retention: retention, dismissedHandoffIDs: ["new"])
    try orderExpect(StatusHistoryRefresh.apply(withoutNew, token: dismissToken, gate: gate, to: dismissed) == nil,
        "an older history fetch was allowed to prune a newer dismissal")
    // Without the gate the same input would have pruned it: prove the check has teeth.
    var ungated = RefreshSequenceGate()
    let ungatedOutcome = StatusHistoryRefresh.apply(withoutNew, token: ungated.token(), gate: ungated, to: dismissed)
    try orderExpect(ungatedOutcome?.dismissalsChanged == true && ungatedOutcome?.state.dismissedHandoffIDs.isEmpty == true,
        "the fixture does not exercise dismissal pruning")
    ungated.invalidate()

    // A fresh fetch taken after the action is accepted, prunes only what the fetched list justifies,
    // reports change for view reconciliation, and hands notifications the fetched list.
    let freshToken = gate.token()
    let fresh = StatusHistoryRefresh.Fetched(handoffs: old + [newer], activity: [], retention: retention)
    guard let outcome = StatusHistoryRefresh.apply(fresh, token: freshToken, gate: gate, to: cleared) else {
        throw NSError(domain: "RefreshOrdering", code: 1, userInfo: [NSLocalizedDescriptionKey: "a current fetch was rejected"])
    }
    try orderExpect(outcome.state.handoffs.count == 3 && outcome.changed && !outcome.dismissalsChanged && outcome.notificationInput.count == 3,
        "a current fetch did not apply cleanly")
    let unchangedAgain = StatusHistoryRefresh.apply(fresh, token: gate.token(), gate: gate, to: outcome.state)
    try orderExpect(unchangedAgain?.changed == false && unchangedAgain?.dismissalsChanged == false,
        "an unchanged fetch reported a change (would publish on idle)")

    // Client replacement or shutdown invalidates everything in flight.
    let beforeReplace = gate.token()
    gate.invalidate() // relayClient didSet
    try orderExpect(!gate.accepts(beforeReplace) && gate.accepts(gate.token()), "client replacement did not invalidate in-flight results")
}
