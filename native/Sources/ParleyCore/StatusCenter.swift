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
    case failure
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
                    title: handoff.kind == .delegate
                        ? "\(handoff.targetName) completed a delegation"
                        : "\(handoff.targetName) returned an answer",
                    body: "Open Parley to review the returned result in \(workspace)."
                ))
            }
            if let attention = handoff.attention,
               let workspace = nonempty(handoff.targetWorkspaceName) ?? nonempty(handoff.targetWorkspaceID) {
                let title = switch attention {
                case .permissionRequired: "\(handoff.targetName) needs permission review"
                case .targetNotReady: "\(handoff.targetName) is not ready"
                case .targetUnavailable: "\(handoff.targetName) is unavailable"
                }
                events.append(StatusNotificationEvent(
                    id: "\(handoff.id):attention:\(attention.rawValue)",
                    handoffID: handoff.id,
                    workspaceName: workspace,
                    kind: .attention,
                    occurredAt: handoff.updatedAt,
                    title: title,
                    body: "Open Parley to resolve the known attention state in \(workspace)."
                ))
            }
            if handoff.attention == nil,
               handoff.state == .failed || handoff.state == .interrupted,
               let workspace = nonempty(handoff.sourceWorkspaceName) ?? nonempty(handoff.sourceWorkspaceID) {
                events.append(StatusNotificationEvent(
                    id: "\(handoff.id):failure",
                    handoffID: handoff.id,
                    workspaceName: workspace,
                    kind: .failure,
                    occurredAt: handoff.updatedAt,
                    title: handoff.state == .failed
                        ? "\(handoff.sourceName) → \(handoff.targetName) failed"
                        : "\(handoff.sourceName) → \(handoff.targetName) was interrupted",
                    body: "Open Parley to inspect the failed handoff in \(workspace)."
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
    public let agents: [WorkbenchPane]
    public let activeHandoffs: [RelayHandoff]
    public let handoffs: [RelayHandoff]
    public let timeline: [StatusTimelineEvent]

    public init(
        condition: StatusCenterCondition,
        counts: StatusCenterCounts,
        agents: [WorkbenchPane],
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
        panes: [WorkbenchPane],
        handoffs: [RelayHandoff],
        activityEvents: [RelayActivityEvent] = [],
        workspaceID: String?,
        coreAvailable: Bool,
        dismissedHandoffIDs: Set<String> = [],
        includeDismissed: Bool = false
    ) -> StatusCenterSnapshot {
        let workspaceAliases: Set<String> = if let workspaceID {
            Set(panes.lazy.filter { $0.workspaceID == workspaceID }.map(\.workspaceID))
                .union([workspaceID])
        } else {
            []
        }
        let scopedAgents = panes
            .filter { pane in
                pane.kind.isAgent && (workspaceID == nil || workspaceAliases.contains(pane.workspaceID))
            }
            .sorted { left, right in
                if left.displayName.caseInsensitiveCompare(right.displayName) == .orderedSame {
                    return left.id < right.id
                }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }
        let scopedHandoffs = handoffs
            .filter { handoff in
                guard workspaceID != nil else { return true }
                return workspaceAliases.contains(handoff.sourceWorkspaceID)
                    || workspaceAliases.contains(handoff.targetWorkspaceID)
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
                && (workspaceID == nil || workspaceAliases.contains(handoff.sourceWorkspaceID))
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
                    category: handoff.kind.label.uppercased(),
                    action: transition.state.rawValue.uppercased(),
                    occurredAt: transition.occurredAt,
                    detail: transition.detail,
                    origin: transition.origin
                )
            }
        }
        let activityTimeline = activityEvents
            .filter { event in workspaceID == nil || workspaceAliases.contains(event.workspaceID) }
            .map { event in
                let isPane = event.kind == .paneRestarted
                    || event.kind == .paneResumeRequested
                    || event.kind == .paneReaped
                    || event.kind == .recipeSubmitted
                    || event.kind == .recipeInterrupted
                    || event.kind == .comparisonForwarded
                    || VendorHookSignal(activityKind: event.kind) != nil
                let action: String
                switch event.kind {
                case .paneRestarted: action = "RESTARTED"
                case .paneResumeRequested: action = "RESUME REQUESTED"
                case .paneReaped: action = "REAPED IDLE"
                case .workspaceCreated: action = "CREATED"
                case .workspaceClosed: action = "CLOSED"
                case .workspaceRestored: action = "RESTORED"
                case .recipeSubmitted: action = "RECIPE SUBMITTED"
                case .recipeInterrupted: action = "RECIPE INTERRUPTED"
                case .comparisonForwarded: action = "COMPARISON FORWARDED"
                case .vendorSessionStarted: action = "SESSION STARTED"
                case .vendorTurnStarted: action = "TURN STARTED"
                case .vendorTurnEnded: action = "TURN ENDED"
                case .vendorAwaitingPermission: action = "AWAITING PERMISSION"
                case .vendorNotification: action = "NOTIFICATION"
                case .vendorSessionEnded: action = "SESSION ENDED"
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
                runningAgents: scopedAgents.count(where: { $0.isStarted && !$0.isDead }),
                stoppedAgents: scopedAgents.count(where: { !$0.isStarted || $0.isDead }),
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
