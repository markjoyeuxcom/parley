import Foundation

/// Remembers only routes the person explicitly chose during this application
/// session. The route is source-specific so changing the active pane cannot
/// silently reverse a handoff.
public struct QuickRelayTargetHistory: Equatable, Sendable {
    private static let maximumSources = 128

    private var targetPaneIDsBySourcePaneID: [String: String] = [:]
    private var sourceOrder: [String] = []

    public init() {}

    public mutating func record(sourcePaneID: String, targetPaneID: String) {
        guard !sourcePaneID.isEmpty,
              !targetPaneID.isEmpty,
              sourcePaneID != targetPaneID else { return }

        if targetPaneIDsBySourcePaneID[sourcePaneID] != nil {
            sourceOrder.removeAll { $0 == sourcePaneID }
        }
        targetPaneIDsBySourcePaneID[sourcePaneID] = targetPaneID
        sourceOrder.append(sourcePaneID)

        while sourceOrder.count > Self.maximumSources {
            let oldest = sourceOrder.removeFirst()
            targetPaneIDsBySourcePaneID.removeValue(forKey: oldest)
        }
    }

    public func targetPaneID(
        for sourcePaneID: String,
        eligibleTargetPaneIDs: Set<String>
    ) -> String? {
        guard let targetPaneID = targetPaneIDsBySourcePaneID[sourcePaneID],
              targetPaneID != sourcePaneID,
              eligibleTargetPaneIDs.contains(targetPaneID) else { return nil }
        return targetPaneID
    }
}
