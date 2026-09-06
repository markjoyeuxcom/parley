import Foundation

/// Orders background refresh results against explicit human actions and
/// synchronous refreshes. A fetch takes a token when it starts; anything that
/// changes what that fetch would have read (an explicit refresh, a direct
/// mutation such as a dismissal, a replaced or dropped control client)
/// invalidates the gate; a result whose token no longer matches is discarded
/// before it can touch state, prune dismissals or raise notifications.
public struct RefreshSequenceGate: Equatable, Sendable {
    public private(set) var sequence = 0

    public init() {}

    public mutating func invalidate() { sequence &+= 1 }
    public func token() -> Int { sequence }
    public func accepts(_ token: Int) -> Bool { token == sequence }
}

/// The Status Center history refresh as one pure step, so its ordering and
/// its effect on dismissals and notifications can be checked deterministically.
public enum StatusHistoryRefresh {
    public struct Fetched: Equatable, Sendable {
        public let handoffs: [RelayHandoff]
        public let activity: [RelayActivityEvent]
        public let retention: CollaborationHistoryRetentionPolicy

        public init(handoffs: [RelayHandoff], activity: [RelayActivityEvent], retention: CollaborationHistoryRetentionPolicy) {
            self.handoffs = handoffs
            self.activity = activity
            self.retention = retention
        }
    }

    public struct State: Equatable, Sendable {
        public var handoffs: [RelayHandoff]
        public var activity: [RelayActivityEvent]
        public var retention: CollaborationHistoryRetentionPolicy
        public var dismissedHandoffIDs: Set<String>

        public init(handoffs: [RelayHandoff], activity: [RelayActivityEvent], retention: CollaborationHistoryRetentionPolicy,
                    dismissedHandoffIDs: Set<String>) {
            self.handoffs = handoffs
            self.activity = activity
            self.retention = retention
            self.dismissedHandoffIDs = dismissedHandoffIDs
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let state: State
        /// Whether history, activity or retention changed (drives view reconciliation).
        public let changed: Bool
        public let dismissalsChanged: Bool
        /// The list notifications must be derived from; empty when nothing was applied.
        public let notificationInput: [RelayHandoff]
    }

    /// Returns nil when `token` is stale: the caller must then change nothing,
    /// prune nothing and notify nobody.
    public static func apply(_ fetched: Fetched, token: Int, gate: RefreshSequenceGate, to state: State) -> Outcome? {
        guard gate.accepts(token) else { return nil }
        var next = state
        var changed = false
        if fetched.handoffs != next.handoffs { next.handoffs = fetched.handoffs; changed = true }
        if fetched.activity != next.activity { next.activity = fetched.activity; changed = true }
        if fetched.retention != next.retention { next.retention = fetched.retention; changed = true }
        let retained = StatusCenterVisibility.retainedDismissalIDs(state.dismissedHandoffIDs, handoffs: fetched.handoffs)
        let dismissalsChanged = retained != state.dismissedHandoffIDs
        if dismissalsChanged { next.dismissedHandoffIDs = retained }
        return Outcome(state: next, changed: changed, dismissalsChanged: dismissalsChanged, notificationInput: fetched.handoffs)
    }
}
