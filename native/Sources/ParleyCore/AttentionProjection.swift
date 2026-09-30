import Darwin
import Foundation

public struct ExternalAttentionWorkspace: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let attentionCount: Int

    public init(id: String, name: String, attentionCount: Int) {
        self.id = id
        self.name = name
        self.attentionCount = attentionCount
    }
}

public struct ExternalAttentionPane: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: PaneKind
    public let workspaceID: String
    public let workspaceName: String

    public init(id: String, name: String, kind: PaneKind, workspaceID: String, workspaceName: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

public enum ExternalAttentionReason: String, Codable, Equatable, Sendable {
    case returnedResult
    case humanInputRequired
    case interrupted
}

public struct ExternalAttentionItem: Identifiable, Codable, Equatable, Sendable {
    public let handoffID: String
    public let workspaceID: String
    public let workspaceName: String
    public let label: String
    public let reason: ExternalAttentionReason

    public var id: String { handoffID }

    public init(
        handoffID: String,
        workspaceID: String,
        workspaceName: String,
        label: String,
        reason: ExternalAttentionReason
    ) {
        self.handoffID = handoffID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.label = label
        self.reason = reason
    }
}

/// A deliberately content-free view for local attention surfaces. It contains
/// human labels, counts and opaque ids only: never
/// prompts, results, terminal output, process commands, folders, credentials
/// or a dispatch capability.
public struct ExternalAttentionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let attentionCount: Int
    public let workspaces: [ExternalAttentionWorkspace]
    public let panes: [ExternalAttentionPane]
    public let items: [ExternalAttentionItem]
    /// When the counts next change with no new input: the soonest moment a
    /// counted failure or request passes `acknowledgementWindow`.
    public var nextChangeAt: Date? = nil

    public init(
        version: Int = currentVersion,
        generatedAt: Date,
        attentionCount: Int,
        workspaces: [ExternalAttentionWorkspace],
        panes: [ExternalAttentionPane],
        items: [ExternalAttentionItem],
        nextChangeAt: Date? = nil
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.attentionCount = attentionCount
        self.workspaces = workspaces
        self.panes = panes
        self.items = items
        self.nextChangeAt = nextChangeAt
    }

}

public enum ExternalAttentionProjection {
    /// A failed, interrupted or waiting handoff needs the person until they
    /// open it in Status Center, and for at most this long after it last
    /// changed (Mark's decision, 30 September 2026). Before, it counted until
    /// retention dropped it, since only results could be marked read, so the
    /// menu bar and the sidebar's Needs Attention filled with old failures.
    /// An unread result still counts until it is read.
    public static let acknowledgementWindow: TimeInterval = 86_400
    public static let maximumWorkspaces = 256
    public static let maximumPanes = 512
    public static let maximumItems = 512

    public static func snapshot(
        workspaces: [WorkbenchWorkspace],
        panes: [WorkbenchPane],
        handoffs: [RelayHandoff],
        generatedAt: Date = Date()
    ) -> ExternalAttentionSnapshot {
        var canonicalWorkspaceByAlias: [String: String] = [:]
        var workspaceNames: [String: String] = [:]
        for workspace in workspaces {
            canonicalWorkspaceByAlias[workspace.id] = workspace.workspaceID
            canonicalWorkspaceByAlias[workspace.workspaceID] = workspace.workspaceID
            workspaceNames[workspace.workspaceID] = workspace.name
        }
        for pane in panes {
            canonicalWorkspaceByAlias[pane.workspaceID] = pane.workspaceID
            if workspaceNames[pane.workspaceID] == nil, let name = pane.workspaceName {
                workspaceNames[pane.workspaceID] = name
            }
        }
        let actionable = handoffs.compactMap { actionableItem($0, now: generatedAt) }.map { original in
            let canonicalID = canonicalWorkspaceByAlias[original.item.workspaceID]
                ?? original.item.workspaceID
            let item = ExternalAttentionItem(
                handoffID: original.item.handoffID,
                workspaceID: canonicalID,
                workspaceName: workspaceNames[canonicalID] ?? original.item.workspaceName,
                label: original.item.label,
                reason: original.item.reason
            )
            return (item: item, updatedAt: original.updatedAt)
        }.sorted { left, right in
            if left.updatedAt == right.updatedAt { return left.item.handoffID < right.item.handoffID }
            return left.updatedAt > right.updatedAt
        }
        let items = actionable.prefix(maximumItems).map(\.item)
        let counts = Dictionary(grouping: actionable.map(\.item), by: \.workspaceID)
            .mapValues(\.count)

        return ExternalAttentionSnapshot(
            generatedAt: generatedAt,
            attentionCount: actionable.count,
            workspaces: workspaces.prefix(maximumWorkspaces).map {
                ExternalAttentionWorkspace(
                    id: $0.workspaceID,
                    name: $0.name,
                    attentionCount: counts[$0.workspaceID, default: 0]
                )
            },
            panes: panes.lazy
                .filter { $0.kind.isAgent && $0.isStarted && !$0.isDead }
                .prefix(maximumPanes)
                .map {
                    ExternalAttentionPane(
                        id: $0.id,
                        name: $0.displayName,
                        kind: $0.kind,
                        workspaceID: $0.workspaceID,
                        workspaceName: workspaceNames[$0.workspaceID]
                            ?? $0.workspaceName ?? $0.workspaceID
                    )
                },
            items: items,
            nextChangeAt: handoffs.lazy
                .filter { !$0.hasUnreadResult && $0.awaitsAcknowledgement }
                .map { $0.updatedAt.addingTimeInterval(acknowledgementWindow) }
                .filter { $0 > generatedAt }
                .min()
        )
    }

    private static func actionableItem(_ handoff: RelayHandoff, now: Date) -> (item: ExternalAttentionItem, updatedAt: Date)? {
        let reason: ExternalAttentionReason
        let workspaceID: String
        let workspaceName: String
        let label: String
        if handoff.hasUnreadResult {
            reason = .returnedResult
            workspaceID = handoff.sourceWorkspaceID
            workspaceName = handoff.sourceWorkspaceName ?? handoff.sourceWorkspaceID
            label = switch handoff.kind {
            case .delegate: "\(handoff.targetName) completed a delegation"
            case .commandRun: "\(handoff.targetName) returned a captured command result"
            default: "\(handoff.targetName) returned an answer"
            }
        } else if handoff.awaitsAcknowledgement,
                  now.timeIntervalSince(handoff.updatedAt) >= acknowledgementWindow {
            // Seen ones never reach here; one this old has stopped counting.
            return nil
        } else if !handoff.awaitsAcknowledgement {
            return nil
        } else if let attention = handoff.attention {
            reason = .humanInputRequired
            workspaceID = handoff.targetWorkspaceID
            workspaceName = handoff.targetWorkspaceName ?? handoff.targetWorkspaceID
            label = switch attention {
            case .permissionRequired: handoff.kind == .commandRun ? "\(handoff.sourceName) requests command approval" : "\(handoff.targetName) needs permission review"
            case .targetNotReady: "\(handoff.targetName) is not ready"
            case .targetUnavailable: "\(handoff.targetName) is unavailable"
            }
        } else if handoff.state == .failed || handoff.state == .interrupted {
            reason = .interrupted
            workspaceID = handoff.sourceWorkspaceID
            workspaceName = handoff.sourceWorkspaceName ?? handoff.sourceWorkspaceID
            label = handoff.state == .failed
                ? "\(handoff.sourceName) → \(handoff.targetName) failed"
                : "\(handoff.sourceName) → \(handoff.targetName) was interrupted"
        } else {
            return nil
        }
        return (
            ExternalAttentionItem(
                handoffID: handoff.id,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                label: label,
                reason: reason
            ),
            handoff.updatedAt
        )
    }
}

public struct MenuBarAttentionSummary: Equatable, Sendable {
    public let coreAvailable: Bool
    public let totalCount: Int
    public let headline: String
}

/// The count and headline behind the menu-bar indicator. It never receives a
/// RelayHandoff and carries no item labels, so nothing but a number and a
/// fixed sentence can reach menu-bar presentation code.
public enum MenuBarAttentionProjection {
    public static func summary(
        snapshot: ExternalAttentionSnapshot,
        coreAvailable: Bool
    ) -> MenuBarAttentionSummary {
        let totalCount = max(0, snapshot.attentionCount)
        let headline: String
        if !coreAvailable {
            headline = "Coordination unavailable"
        } else if totalCount == 0 {
            headline = "No items need attention"
        } else if totalCount == 1 {
            headline = "1 item needs attention"
        } else {
            headline = "\(totalCount) items need attention"
        }
        return MenuBarAttentionSummary(
            coreAvailable: coreAvailable,
            totalCount: totalCount,
            headline: headline
        )
    }
}

/// One in-app navigation target chosen from an attention item: focus a live
/// pane or open one Status Center handoff. It carries an opaque id only and
/// cannot start a pane or submit input.
public enum AttentionNavigationRequest: Equatable, Sendable {
    case pane(String)
    case handoff(String)
}
