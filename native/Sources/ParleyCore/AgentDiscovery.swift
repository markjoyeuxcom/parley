import Foundation

public enum RelayAgentPaneLifecycle: String, Codable, Equatable, Sendable {
    case running
    case stopped
    case exited
    case protocolRestartRequired
    case relayUnavailable
    case inputUnavailable

    init(pane: WorkbenchPane) {
        if !pane.isStarted {
            self = .stopped
        } else if pane.isDead {
            self = .exited
        } else if !pane.hasCurrentProtocol {
            self = .protocolRestartRequired
        } else if !pane.relayEnabled {
            self = .relayUnavailable
        } else if !pane.inputAvailable {
            self = .inputUnavailable
        } else {
            self = .running
        }
    }
}

public struct RelayAgentIdentity: Codable, Equatable, Sendable {
    public let paneID: String
    public let name: String
    public let vendor: PaneKind
    public let workspaceID: String
    public let workspaceName: String
    public let role: String?
    public let qualifiedRole: String?
    public let isWorkspaceLead: Bool
    public let lifecycle: RelayAgentPaneLifecycle
    public let inputPathAvailable: Bool
    public let relayEnabled: Bool
    public let protocolVersion: String?

    init(pane: WorkbenchPane) {
        let canonicalRole = canonicalAgentRole(pane.role)
        let canonicalWorkspaceName = boundedAgentLabel(pane.workspaceName ?? pane.workspaceID)
        paneID = boundedAgentLabel(pane.id)
        name = boundedAgentLabel(pane.displayName)
        vendor = pane.kind
        workspaceID = boundedAgentLabel(pane.workspaceID)
        workspaceName = canonicalWorkspaceName
        role = canonicalRole
        qualifiedRole = canonicalRole.map { "\(boundedAgentLabel(pane.workspaceID))/\($0)" }
        isWorkspaceLead = pane.isWorkspaceLead
        lifecycle = RelayAgentPaneLifecycle(pane: pane)
        inputPathAvailable = pane.inputAvailable
        relayEnabled = pane.relayEnabled
        protocolVersion = pane.protocolVersion.map(boundedAgentLabel)
    }
}

public struct RelayAgentPane: Codable, Equatable, Sendable {
    public let paneID: String
    public let target: String
    public let name: String
    public let vendor: PaneKind
    public let workspaceID: String
    public let workspaceName: String
    public let role: String?
    public let qualifiedRole: String?
    public let isWorkspaceLead: Bool
    public let lifecycle: RelayAgentPaneLifecycle
    public let inputPathAvailable: Bool
    public let relayEnabled: Bool
    public let protocolVersion: String?
    public let hasActiveHandoff: Bool

    init(pane: WorkbenchPane, hasActiveHandoff: Bool) {
        let canonicalRole = canonicalAgentRole(pane.role)
        let canonicalWorkspaceName = boundedAgentLabel(pane.workspaceName ?? pane.workspaceID)
        paneID = boundedAgentLabel(pane.id)
        target = boundedAgentLabel(pane.id)
        name = boundedAgentLabel(pane.displayName)
        vendor = pane.kind
        workspaceID = boundedAgentLabel(pane.workspaceID)
        workspaceName = canonicalWorkspaceName
        role = canonicalRole
        qualifiedRole = canonicalRole.map { "\(boundedAgentLabel(pane.workspaceID))/\($0)" }
        isWorkspaceLead = pane.isWorkspaceLead
        lifecycle = RelayAgentPaneLifecycle(pane: pane)
        inputPathAvailable = pane.inputAvailable
        relayEnabled = pane.relayEnabled
        protocolVersion = pane.protocolVersion.map(boundedAgentLabel)
        self.hasActiveHandoff = hasActiveHandoff
    }
}

public struct RelayAgentPaneList: Codable, Equatable, Sendable {
    public static let maximumPanes = 128

    public let panes: [RelayAgentPane]
    public let truncated: Bool

    init(panes: [RelayAgentPane], truncated: Bool) {
        self.panes = panes
        self.truncated = truncated
    }
}

public enum RelayAgentEventCategory: String, Codable, Equatable, Sendable {
    case handoffTransition
    case activity
    case vendorSignal
}

public struct RelayAgentEvent: Codable, Equatable, Sendable {
    public var cursor: String
    public let id: String
    public let category: RelayAgentEventCategory
    public let occurredAt: Date
    public let origin: RelayTransitionOrigin?

    public let handoffID: String?
    public let handoffKind: RelayHandoffKind?
    public let handoffState: RelayHandoffState?
    public let sourcePaneID: String?
    public let sourceVendor: PaneKind?
    public let sourceWorkspaceID: String?
    public let targetPaneID: String?
    public let targetVendor: PaneKind?
    public let targetWorkspaceID: String?
    public let inReplyToHandoffID: String?
    public let relationship: RelayHandoffRelationship?

    public let activityKind: RelayActivityEventKind?
    public let workspaceID: String?
    public let paneID: String?
    public let paneVendor: PaneKind?
    public let vendorSignal: VendorHookSignal?

    static func handoff(
        _ handoff: RelayHandoff,
        transition: RelayHandoffTransition,
        index: Int
    ) -> RelayAgentEvent {
        let id = "handoff:\(handoff.id):\(String(format: "%04d", index))"
        return RelayAgentEvent(
            cursor: "v1:\(id)",
            id: id,
            category: .handoffTransition,
            occurredAt: transition.occurredAt,
            origin: transition.origin,
            handoffID: handoff.id,
            handoffKind: handoff.kind,
            handoffState: transition.state,
            sourcePaneID: handoff.sourcePaneID,
            sourceVendor: handoff.sourceKind,
            sourceWorkspaceID: handoff.sourceWorkspaceID,
            targetPaneID: handoff.targetPaneID,
            targetVendor: handoff.targetKind,
            targetWorkspaceID: handoff.targetWorkspaceID,
            inReplyToHandoffID: handoff.inReplyToHandoffID,
            relationship: handoff.relationship,
            activityKind: nil,
            workspaceID: nil,
            paneID: nil,
            paneVendor: nil,
            vendorSignal: nil
        )
    }

    static func activity(_ activity: RelayActivityEvent) -> RelayAgentEvent {
        let id = "activity:\(activity.id)"
        return RelayAgentEvent(
            cursor: "v1:\(id)",
            id: id,
            category: VendorHookSignal(activityKind: activity.kind) == nil ? .activity : .vendorSignal,
            occurredAt: activity.occurredAt,
            origin: activity.origin,
            handoffID: nil,
            handoffKind: nil,
            handoffState: nil,
            sourcePaneID: nil,
            sourceVendor: nil,
            sourceWorkspaceID: nil,
            targetPaneID: nil,
            targetVendor: nil,
            targetWorkspaceID: nil,
            inReplyToHandoffID: nil,
            relationship: nil,
            activityKind: activity.kind,
            workspaceID: activity.workspaceID,
            paneID: activity.paneID,
            paneVendor: activity.paneKind,
            vendorSignal: VendorHookSignal(activityKind: activity.kind)
        )
    }

    static func project(
        handoffs: [RelayHandoff],
        activities: [RelayActivityEvent]
    ) -> [RelayAgentEvent] {
        var events = handoffs.flatMap { handoff in
            handoff.transitions.enumerated().map { index, transition in
                RelayAgentEvent.handoff(handoff, transition: transition, index: index)
            }
        }
        events.append(contentsOf: activities.map(RelayAgentEvent.activity))
        return events.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt < $1.occurredAt
        }
    }
}

public struct RelayAgentEventPage: Codable, Equatable, Sendable {
    public static let maximumEvents = 100

    public let events: [RelayAgentEvent]
    public let nextCursor: String
    public let hasMore: Bool

    init(events: [RelayAgentEvent], nextCursor: String, hasMore: Bool) {
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

private func boundedAgentLabel(_ value: String) -> String {
    let singleLine = value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(singleLine.prefix(160))
}

private func canonicalAgentRole(_ role: String?) -> String? {
    guard let role, PaneRoleRules.validationError(role) == nil else { return nil }
    return "@\(role)"
}
