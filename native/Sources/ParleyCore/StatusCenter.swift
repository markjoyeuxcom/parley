import Foundation

public enum StatusCenterCondition: String, Equatable, Sendable {
    case allClear
    case resultsAvailable
    case agentsWaiting
    case humanInputRequired
    case interruptedWork
    case coreUnavailable
}

public struct StatusCenterCounts: Equatable, Sendable {
    public let runningAgents: Int
    public let stoppedAgents: Int
    public let outstandingQuestions: Int
    public let trackedDelegations: Int
    public let failures: Int
    public let unreadResults: Int

    public init(
        runningAgents: Int,
        stoppedAgents: Int,
        outstandingQuestions: Int,
        trackedDelegations: Int,
        failures: Int,
        unreadResults: Int
    ) {
        self.runningAgents = runningAgents
        self.stoppedAgents = stoppedAgents
        self.outstandingQuestions = outstandingQuestions
        self.trackedDelegations = trackedDelegations
        self.failures = failures
        self.unreadResults = unreadResults
    }
}

public struct StatusTimelineEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let handoffID: String?
    public let title: String
    public let category: String
    public let action: String
    public let occurredAt: Date
    public let detail: String?
    public let origin: RelayTransitionOrigin?

    public init(
        id: String,
        handoffID: String?,
        title: String,
        category: String,
        action: String,
        occurredAt: Date,
        detail: String?,
        origin: RelayTransitionOrigin?
    ) {
        self.id = id
        self.handoffID = handoffID
        self.title = title
        self.category = category
        self.action = action
        self.occurredAt = occurredAt
        self.detail = detail
        self.origin = origin
    }
}

public enum StatusNotificationKind: String, Equatable, Sendable {
    case returnedResult
    case attention
}

public struct StatusNotificationEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let handoffID: String
    public let workspaceName: String
    public let kind: StatusNotificationKind
    public let occurredAt: Date
    public let title: String
    public let body: String
}

/// Builds privacy-bounded notification facts from the same durable records as
/// the Status Center. Prompt and result bodies are deliberately excluded.
public enum StatusNotificationProjection {
    public static func events(handoffs: [RelayHandoff]) -> [StatusNotificationEvent] {
        handoffs.flatMap { handoff -> [StatusNotificationEvent] in
            var events: [StatusNotificationEvent] = []
            if handoff.hasUnreadResult,
               let workspace = nonempty(handoff.sourceWorkspaceName) ?? nonempty(handoff.sourceWorkspaceID) {
                events.append(StatusNotificationEvent(
                    id: "\(handoff.id):result",
                    handoffID: handoff.id,
                    workspaceName: workspace,
                    kind: .returnedResult,
                    occurredAt: handoff.updatedAt,
                    title: "\(handoff.targetName) returned a result",
                    body: "Open Parley to review the returned result in \(workspace)."
                ))
            }
            if let attention = handoff.attention,
               let workspace = nonempty(handoff.targetWorkspaceName) ?? nonempty(handoff.targetWorkspaceID) {
                events.append(StatusNotificationEvent(
                    id: "\(handoff.id):attention:\(attention.rawValue)",
                    handoffID: handoff.id,
                    workspaceName: workspace,
                    kind: .attention,
                    occurredAt: handoff.updatedAt,
                    title: "\(handoff.targetName) needs attention",
                    body: "Open Parley to resolve the known attention state in \(workspace)."
                ))
            }
            return events
        }.sorted { left, right in
            if left.occurredAt == right.occurredAt { return left.id < right.id }
            return left.occurredAt > right.occurredAt
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public struct StatusCenterSnapshot: Equatable, Sendable {
    public let condition: StatusCenterCondition
    public let counts: StatusCenterCounts
    public let agents: [TmuxPane]
    public let activeHandoffs: [RelayHandoff]
    public let handoffs: [RelayHandoff]
    public let timeline: [StatusTimelineEvent]

    public init(
        condition: StatusCenterCondition,
        counts: StatusCenterCounts,
        agents: [TmuxPane],
        activeHandoffs: [RelayHandoff],
        handoffs: [RelayHandoff],
        timeline: [StatusTimelineEvent]
    ) {
        self.condition = condition
        self.counts = counts
        self.agents = agents
        self.activeHandoffs = activeHandoffs
        self.handoffs = handoffs
        self.timeline = timeline
    }
}

/// Local presentation preferences may hide routine completed records, but
/// never live work, failures, or a result the person has not viewed. The
/// durable handoff journal is untouched.
public enum StatusCenterVisibility {
    public static func isDismissible(_ handoff: RelayHandoff) -> Bool {
        handoff.state == .completed && !handoff.hasUnreadResult
    }

    public static func retainedDismissalIDs(
        _ dismissedIDs: Set<String>,
        handoffs: [RelayHandoff]
    ) -> Set<String> {
        Set(handoffs.lazy.filter(isDismissible).map(\.id)).intersection(dismissedIDs)
    }
}

/// A deterministic view of facts Parley owns. It deliberately does not infer
/// thinking, idleness, token use, unread output, or vendor-internal state.
public enum StatusCenterProjection {
    private static let activeStates: Set<RelayHandoffState> = [
        .created, .delivered, .waiting, .answered,
    ]
    private static let failureStates: Set<RelayHandoffState> = [.failed, .interrupted]

    public static func snapshot(
        panes: [TmuxPane],
        handoffs: [RelayHandoff],
        activityEvents: [RelayActivityEvent] = [],
        workspaceID: String?,
        coreAvailable: Bool,
        dismissedHandoffIDs: Set<String> = [],
        includeDismissed: Bool = false
    ) -> StatusCenterSnapshot {
        let scopedAgents = panes
            .filter { pane in
                pane.kind.isAgent && (workspaceID == nil || pane.windowID == workspaceID)
            }
            .sorted { left, right in
                if left.displayName.caseInsensitiveCompare(right.displayName) == .orderedSame {
                    return left.id < right.id
                }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }
        let scopedHandoffs = handoffs
            .filter { handoff in
                guard let workspaceID else { return true }
                return handoff.sourceWorkspaceID == workspaceID || handoff.targetWorkspaceID == workspaceID
            }
            .filter { handoff in
                includeDismissed
                    || !dismissedHandoffIDs.contains(handoff.id)
                    || !StatusCenterVisibility.isDismissible(handoff)
            }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt { return left.id < right.id }
                return left.updatedAt > right.updatedAt
            }
        let active = scopedHandoffs.filter { activeStates.contains($0.state) }
        let failures = scopedHandoffs.filter { failureStates.contains($0.state) }
        let unreadResults = scopedHandoffs.count { handoff in
            handoff.hasUnreadResult
                && (workspaceID == nil || handoff.sourceWorkspaceID == workspaceID)
        }

        let condition: StatusCenterCondition
        if !coreAvailable {
            condition = .coreUnavailable
        } else if scopedHandoffs.contains(where: { $0.attention != nil }) {
            condition = .humanInputRequired
        } else if !failures.isEmpty {
            condition = .interruptedWork
        } else if !active.isEmpty {
            condition = .agentsWaiting
        } else if unreadResults > 0 {
            condition = .resultsAvailable
        } else {
            condition = .allClear
        }

        let handoffTimeline = scopedHandoffs.flatMap { handoff in
            handoff.transitions.enumerated().map { index, transition in
                StatusTimelineEvent(
                    id: "\(handoff.id):\(index)",
                    handoffID: handoff.id,
                    title: "\(handoff.sourceName) → \(handoff.targetName)",
                    category: handoff.kind.rawValue.uppercased(),
                    action: transition.state.rawValue.uppercased(),
                    occurredAt: transition.occurredAt,
                    detail: transition.detail,
                    origin: transition.origin
                )
            }
        }
        let activityTimeline = activityEvents
            .filter { event in workspaceID == nil || event.workspaceID == workspaceID }
            .map { event in
                let isPane = event.kind == .paneRestarted
                let action: String
                switch event.kind {
                case .paneRestarted: action = "RESTARTED"
                case .workspaceCreated: action = "CREATED"
                case .workspaceClosed: action = "CLOSED"
                case .workspaceRestored: action = "RESTORED"
                }
                return StatusTimelineEvent(
                    id: "activity:\(event.id)",
                    handoffID: nil,
                    title: isPane ? (event.paneName ?? event.workspaceName) : event.workspaceName,
                    category: isPane ? "PANE" : "WORKSPACE",
                    action: action,
                    occurredAt: event.occurredAt,
                    detail: event.detail,
                    origin: event.origin
                )
            }
        let timeline = (handoffTimeline + activityTimeline).sorted { left, right in
            if left.occurredAt == right.occurredAt { return left.id < right.id }
            return left.occurredAt > right.occurredAt
        }

        return StatusCenterSnapshot(
            condition: condition,
            counts: StatusCenterCounts(
                runningAgents: scopedAgents.count(where: { $0.isStarted }),
                stoppedAgents: scopedAgents.count(where: { !$0.isStarted }),
                outstandingQuestions: active.count(where: { $0.kind == .ask }),
                trackedDelegations: active.count(where: { $0.kind == .delegate }),
                failures: failures.count,
                unreadResults: unreadResults
            ),
            agents: scopedAgents,
            activeHandoffs: active,
            handoffs: scopedHandoffs,
            timeline: timeline
        )
    }
}
