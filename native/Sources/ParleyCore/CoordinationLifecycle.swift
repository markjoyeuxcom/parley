import Foundation

/// The app-resident broker may be stopped only when no correlated or tracked
/// work is live. Closing a window never consults this policy because it does
/// not stop the application, pane processes, or broker.
public enum CoordinationShutdownPolicy {
    private static let activeStates: Set<RelayHandoffState> = [
        .created, .delivered, .waiting, .answered,
    ]

    public static func canStop(
        activeConsultationCount: Int,
        handoffs: [RelayHandoff]
    ) -> Bool {
        activeConsultationCount == 0
            && !handoffs.contains(where: { activeStates.contains($0.state) })
    }
}
