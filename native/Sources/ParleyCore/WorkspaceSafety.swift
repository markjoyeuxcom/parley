import Foundation

public struct WorkspaceSafetyAgent: Identifiable, Equatable, Sendable {
    public let paneID: String
    public let name: String
    public let kind: PaneKind

    public var id: String { paneID }
}

public struct WorkspaceSafetyHandoff: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: RelayHandoffKind
    public let state: RelayHandoffState
    public let sourceName: String
    public let targetName: String
}

public struct WorkspaceSafetyRepository: Identifiable, Equatable, Sendable {
    public let path: String
    public let branch: String

    public var id: String { path }
}

/// A content-free pre-action summary. The projection keeps prompt, answer and
/// terminal bodies out of its type surface so confirmation UI cannot expose
/// them accidentally.
public struct WorkspaceSafetySummary: Equatable, Sendable {
    public let workspaceID: String
    public let workspaceName: String
    public let totalPaneCount: Int
    public let runningAgents: [WorkspaceSafetyAgent]
    public let activeHandoffs: [WorkspaceSafetyHandoff]
    public let handoffStateAvailable: Bool
    public let dirtyRepositories: [WorkspaceSafetyRepository]
    public let unavailableRepositoryPaths: [String]
    public let sharedWriterWorktrees: [WorktreeWriterCollision]

    public var detailText: String {
        var lines: [String] = ["WORKSPACE SAFETY · \(workspaceName)"]

        if runningAgents.isEmpty {
            lines.append("Running agents: none")
        } else {
            lines.append("Running agents (\(runningAgents.count)):")
            lines += runningAgents.map { "  • \($0.name) · \($0.kind.label)" }
        }

        if !handoffStateAvailable {
            lines.append("Active handoffs: unavailable while the coordination core is disconnected")
        } else if activeHandoffs.isEmpty {
            lines.append("Active handoffs: none")
        } else {
            lines.append("Active handoffs (\(activeHandoffs.count)):")
            lines += activeHandoffs.map {
                "  • \($0.sourceName) → \($0.targetName) · \($0.kind.rawValue.uppercased()) · \($0.state.rawValue.uppercased())"
            }
        }

        if dirtyRepositories.isEmpty {
            lines.append("Dirty Git worktrees: none detected from current repository snapshots")
        } else {
            lines.append("Dirty Git worktrees (\(dirtyRepositories.count)):")
            lines += dirtyRepositories.map { "  • \($0.branch) · \($0.path)" }
        }
        if !unavailableRepositoryPaths.isEmpty {
            lines.append("Repository state unavailable (\(unavailableRepositoryPaths.count)):")
            lines += unavailableRepositoryPaths.map { "  • \($0)" }
        }

        if sharedWriterWorktrees.isEmpty {
            lines.append("Shared worktree writers: none detected from current path and permission snapshots")
        } else {
            lines.append("Shared worktree writers (\(sharedWriterWorktrees.count)):")
            for collision in sharedWriterWorktrees {
                lines.append("  • \(collision.worktree.path)")
                lines += collision.writers.map { writer in
                    let enforcement = writer.enforcement?.label ?? "enforcement unknown"
                    return "      \(writer.paneName) · \(writer.permissionProfileName) · \(enforcement)"
                }
            }
        }

        lines.append("")
        lines.append("Parley reports process, broker, Git and visible permission facts only. It does not infer whether an agent is thinking or which process changed a file.")
        return lines.joined(separator: "\n")
    }
}

public enum WorkspaceSafetyProjection {
    private static let activeHandoffStates: Set<RelayHandoffState> = [
        .created, .delivered, .waiting, .answered,
    ]

    public static func summary(
        workspace: TmuxWorkspace,
        panes: [TmuxPane],
        handoffs: [RelayHandoff],
        projectContextsByPaneID: [String: GitProjectContext],
        paneWorktreePaths: [String: String],
        writerCollisions: [WorktreeWriterCollision],
        coreAvailable: Bool
    ) -> WorkspaceSafetySummary {
        let workspacePanes = panes
            .filter { $0.windowID == workspace.id }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let runningAgents = workspacePanes.compactMap { pane -> WorkspaceSafetyAgent? in
            guard pane.kind.isAgent, pane.isStarted, !pane.isDead else { return nil }
            return WorkspaceSafetyAgent(paneID: pane.id, name: pane.displayName, kind: pane.kind)
        }
        let activeHandoffs: [WorkspaceSafetyHandoff] = if coreAvailable {
            handoffs.compactMap { handoff in
                guard activeHandoffStates.contains(handoff.state),
                      handoff.sourceWorkspaceID == workspace.id || handoff.targetWorkspaceID == workspace.id else {
                    return nil
                }
                return WorkspaceSafetyHandoff(
                    id: handoff.id,
                    kind: handoff.kind,
                    state: handoff.state,
                    sourceName: handoff.sourceName,
                    targetName: handoff.targetName
                )
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        } else {
            []
        }

        var dirtyByPath: [String: WorkspaceSafetyRepository] = [:]
        var knownPaths: Set<String> = []
        var unavailablePaths: Set<String> = []
        for pane in workspacePanes {
            let path = paneWorktreePaths[pane.id] ?? pane.cwd
            if let context = projectContextsByPaneID[pane.id] {
                knownPaths.insert(path)
                unavailablePaths.remove(path)
                if context.isDirty {
                    dirtyByPath[path] = WorkspaceSafetyRepository(path: path, branch: context.branch)
                }
            } else if paneWorktreePaths[pane.id] != nil, !knownPaths.contains(path) {
                unavailablePaths.insert(path)
            }
        }

        let sharedWriterWorktrees = writerCollisions.filter { collision in
            collision.writers.contains(where: { $0.workspaceID == workspace.id })
        }.sorted { $0.worktree.path.localizedStandardCompare($1.worktree.path) == .orderedAscending }

        return WorkspaceSafetySummary(
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            totalPaneCount: workspacePanes.count,
            runningAgents: runningAgents,
            activeHandoffs: activeHandoffs,
            handoffStateAvailable: coreAvailable,
            dirtyRepositories: dirtyByPath.values.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            },
            unavailableRepositoryPaths: unavailablePaths.sorted(),
            sharedWriterWorktrees: sharedWriterWorktrees
        )
    }
}
