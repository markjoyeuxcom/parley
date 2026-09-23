import Foundation

/// What the app decides about a person's reviewed Ask from the handoff
/// history, kept here so it can be checked (the app target cannot be).
///
/// Review of 22 September 2026, M9: the composer and a person's context pack
/// were cleared the moment Send was pressed, so a refusal (the target already
/// had tracked work) lost a draft that existed only in memory; and the busy
/// pre-check read Status Center's history, which stops refreshing when that
/// window closes, so the refusal was reachable in ordinary use.
public enum ReviewedAskHistory {
    /// States in which a pane's tracked work is still open.
    public static let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]

    /// Every handoff the lists carry, one record each: the one updated most
    /// recently, newest first as the broker returns them. Status Center's
    /// longer history and the tick's short list disagree whenever one of
    /// them is stale; neither may hide the other's newer record.
    public static func newestPerHandoff(_ lists: [RelayHandoff]...) -> [RelayHandoff] {
        var newest: [String: RelayHandoff] = [:]
        for handoff in lists.joined() {
            if let known = newest[handoff.id], known.updatedAt >= handoff.updatedAt { continue }
            newest[handoff.id] = handoff
        }
        return newest.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    public static func targetHasTrackedWork(_ paneID: String, in history: [RelayHandoff]) -> Bool {
        history.contains { $0.targetPaneID == paneID && activeStates.contains($0.state) }
    }

    /// Whether the Ask the app launched with this idempotency key reached its
    /// target. Refused before delivery (no record, or a record that never got
    /// past created), the person's draft is still theirs to keep or queue;
    /// delivered and then timed out or failed, it stays sent, because giving
    /// the draft back would invite asking the same question twice.
    public static func reachedTarget(idempotencyKey: String, in history: [RelayHandoff]) -> Bool {
        let reached: Set<RelayHandoffState> = [.delivered, .waiting, .answered, .completed]
        guard let handoff = history.first(where: { $0.kind == .ask && $0.idempotencyKey == idempotencyKey }) else { return false }
        return reached.contains(handoff.state) || handoff.transitions.contains { reached.contains($0.state) }
    }
}
