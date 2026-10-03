import Foundation

/// Moving transfers one retained Ghostty pane without restarting it.
public enum PaneMobilityAction: String, Equatable, Sendable {
    case move
}

public enum PaneMobilityBlocker: Equatable, Sendable {
    case sameWorkspace
    case activeHandoffs(Int)
    case roleConflict(String)
    case leadConflict

    public var explanation: String {
        switch self {
        case .sameWorkspace:
            "Choose a different workspace."
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
        pane: WorkbenchPane,
        targetWorkspaceID: String,
        panes: [WorkbenchPane],
        activeHandoffCount: Int
    ) -> PaneMobilityAssessment {
        guard pane.workspaceID != targetWorkspaceID else {
            return PaneMobilityAssessment(
                action: action,
                activeHandoffCount: activeHandoffCount,
                blockers: [.sameWorkspace]
            )
        }

        // Moving the last pane out is allowed: the source stays as an empty
        // workspace, which is a valid state.
        var blockers: [PaneMobilityBlocker] = []
        if activeHandoffCount > 0 {
            blockers.append(.activeHandoffs(activeHandoffCount))
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

    /// What a Move to Workspace item says when that destination would refuse
    /// the pane for its role or lead mark, so the refusal is visible before
    /// the choice rather than after it. Active handoffs are the pane's own
    /// state, not the destination's, and the move still checks everything
    /// again when chosen. Nil when neither collides.
    public static func destinationConflictNote(
        pane: WorkbenchPane,
        targetWorkspaceID: String,
        panes: [WorkbenchPane]
    ) -> String? {
        let notes = assess(action: .move, pane: pane, targetWorkspaceID: targetWorkspaceID, panes: panes, activeHandoffCount: 0)
            .blockers
            .compactMap { blocker -> String? in
                switch blocker {
                case let .roleConflict(role): "@\(role) is taken there"
                case .leadConflict: "already has a lead"
                case .sameWorkspace, .activeHandoffs: nil
                }
            }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }
}
