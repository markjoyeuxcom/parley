import Foundation

/// Decides which agent panes an opt-in reaper may stop. The reaper only ever
/// stops a process and leaves the seat visible as a stopped slot — nothing is
/// closed, hidden or resumed automatically — so every gate errs towards
/// keeping a process alive.
public enum IdleAgentReaper {
    public static let defaultIdleInterval: TimeInterval = 30 * 60

    /// True when the pane may be reaped: a started background agent with no
    /// live collaboration, quiet for at least the idle interval. The active
    /// pane, workspace leads and panes involved in any consultation or
    /// delegation are never touched.
    public static func shouldReap(
        pane: WorkbenchPane,
        lastActivity: Date?,
        now: Date,
        idleAfter: TimeInterval = defaultIdleInterval,
        hasLiveCollaboration: Bool
    ) -> Bool {
        guard pane.kind.isAgent, pane.isStarted, !pane.isDead else { return false }
        guard !pane.isActive, !pane.isWorkspaceLead else { return false }
        guard !hasLiveCollaboration else { return false }
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= idleAfter
    }
}
