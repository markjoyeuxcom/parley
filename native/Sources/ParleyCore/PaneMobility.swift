import Foundation

/// Moving transfers one live tmux pane without restarting it. Cloning copies
/// only the visible Parley configuration and never copies an agent session or
/// pane-scoped relay credential.
public enum PaneMobilityAction: String, Equatable, Sendable {
    case move
    case clone
}

public enum PaneMobilityBlocker: Equatable, Sendable {
    case sameWorkspace
    case lastSourcePane
    case activeHandoffs(Int)
    case roleConflict(String)
    case leadConflict

    public var explanation: String {
        switch self {
        case .sameWorkspace:
            "Choose a different workspace."
        case .lastSourcePane:
            "Moving the final pane would destroy its source workspace."
        case let .activeHandoffs(count):
            "This pane participates in \(count) active \(count == 1 ? "handoff" : "handoffs"). Finish or cancel them before moving it."
        case let .roleConflict(role):
            "The target workspace already has @\(role)."
        case .leadConflict:
            "The target workspace already has a Workspace Lead."
        }
    }
}

public struct PaneMobilityAssessment: Equatable, Sendable {
    public let action: PaneMobilityAction
    public let activeHandoffCount: Int
    public let blockers: [PaneMobilityBlocker]

    public init(
        action: PaneMobilityAction,
        activeHandoffCount: Int,
        blockers: [PaneMobilityBlocker]
    ) {
        self.action = action
        self.activeHandoffCount = activeHandoffCount
        self.blockers = blockers
    }

    public var isAllowed: Bool { blockers.isEmpty }

    public var refusalText: String {
        blockers.map(\.explanation).joined(separator: "\n")
    }
}

public enum PaneMobilityPolicy {
    public static func assess(
        action: PaneMobilityAction,
        pane: TmuxPane,
        targetWorkspaceID: String,
        panes: [TmuxPane],
        activeHandoffCount: Int
    ) -> PaneMobilityAssessment {
        guard pane.workspaceID != targetWorkspaceID else {
            return PaneMobilityAssessment(
                action: action,
                activeHandoffCount: activeHandoffCount,
                blockers: [.sameWorkspace]
            )
        }

        var blockers: [PaneMobilityBlocker] = []
        if action == .move {
            if panes.filter({ $0.workspaceID == pane.workspaceID }).count <= 1 {
                blockers.append(.lastSourcePane)
            }
            if activeHandoffCount > 0 {
                blockers.append(.activeHandoffs(activeHandoffCount))
            }
        }

        let targetPanes = panes.filter { $0.workspaceID == targetWorkspaceID }
        if let role = pane.role,
           targetPanes.contains(where: {
               $0.role?.caseInsensitiveCompare(role) == .orderedSame
           }) {
            blockers.append(.roleConflict(role.lowercased()))
        }
        if pane.isWorkspaceLead && targetPanes.contains(where: \.isWorkspaceLead) {
            blockers.append(.leadConflict)
        }

        return PaneMobilityAssessment(
            action: action,
            activeHandoffCount: activeHandoffCount,
            blockers: blockers
        )
    }
}
