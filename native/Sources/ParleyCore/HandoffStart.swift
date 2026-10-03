import Foundation

/// Whether the target of an Ask or Delegate has started a turn since it was
/// delivered, from the vendor's authenticated turn-start hook
/// (`RelayHandoff.targetTurnStartedAt`), never from terminal text. On 2
/// October 2026 a delegation was delivered (paste and Enter succeeded) and
/// the Codex pane never received it; nothing in Parley said so. Unknown for a
/// pane that has not reported any hook this run: Agy has none, and Copilot
/// reports only when its plugin hook actually runs.
public enum HandoffStartProjection {
    /// A turn can take a moment to begin, and a vendor busy with an earlier
    /// turn submits a queued message only when that turn ends.
    public static let window: TimeInterval = 60
    private static let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]

    /// True once the target's turn-start hook arrived after this handoff was
    /// created; false while it has not, for a target that reports hooks; nil
    /// when that cannot be known.
    public static func turnStarted(_ handoff: RelayHandoff, target: WorkbenchPane?) -> Bool? {
        if handoff.targetTurnStartedAt != nil { return true }
        guard handoff.kind == .ask || handoff.kind == .delegate,
              handoff.transitions.contains(where: { $0.state == .delivered }),
              let target, target.id == handoff.targetPaneID,
              HandoffComposerSignalProjection.advisory(for: target) != nil else { return nil }
        return false
    }

    /// Delivered over a minute ago, still active, and no turn has started.
    public static func notStarted(_ handoff: RelayHandoff, target: WorkbenchPane?, now: Date) -> Bool {
        guard activeStates.contains(handoff.state), turnStarted(handoff, target: target) == false,
              let deliveredAt = handoff.transitions.first(where: { $0.state == .delivered })?.occurredAt else { return false }
        return now.timeIntervalSince(deliveredAt) >= window
    }

    public static let title = "Delivered, no turn started"
    public static func detail(targetName: String) -> String {
        "\(targetName) has not reported starting a turn since this was delivered. It may still be finishing an earlier turn, or the text may not have arrived. Check that pane before sending it again."
    }
}
