import Foundation

/// A bounded on-demand reading, never a promise about reclaimable space:
/// APFS clones/compression and hard links can share storage.
public struct WorktreeDiskUsage: Equatable, Sendable {
    public let logicalBytes: Int64
    public let fileCount: Int
    public let isComplete: Bool
    public let detail: String

    public static func measure(path: String, maximumEntries: Int = 50_000, timeout: TimeInterval = 2) -> Self {
        let fm = FileManager.default
        guard ManagedWorktreeService.itemState(at: path) == .present(isDirectory: true) else {
            return Self(logicalBytes: 0, fileCount: 0, isComplete: false, detail: "Folder unavailable; size unknown.")
        }
        var complete = true
        let root = GitWorktreeResolver.canonicalPath(path)
        let start = ProcessInfo.processInfo.systemUptime
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: Array(keys),
                                            options: [], errorHandler: { _, _ in complete = false; return true }) else {
            return Self(logicalBytes: 0, fileCount: 0, isComplete: false, detail: "Folder could not be enumerated.")
        }
        var bytes: Int64 = 0, files = 0, entries = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= maximumEntries, ProcessInfo.processInfo.systemUptime - start < timeout, !Task.isCancelled else {
                complete = false; break
            }
            guard let values = try? url.resourceValues(forKeys: keys) else { complete = false; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard WorktreeCleanupPolicy.isNested(url.path, in: root) else { complete = false; enumerator.skipDescendants(); continue }
            if values.isRegularFile == true {
                guard let size = values.fileSize else { complete = false; continue }
                bytes += Int64(size); files += 1
            }
        }
        return Self(logicalBytes: bytes, fileCount: files, isComplete: complete,
                    detail: complete ? "Logical file bytes, including ignored files. Shared Git objects and symlink targets excluded; not reclaimable disk space."
                                     : "Partial size only: the entry/time limit, cancellation or an unreadable item stopped a complete reading.")
    }
}

public struct WorktreeWorkspaceUse: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let paneIDs: [String]
    public let canCloseWholeWorkspace: Bool
}

public struct WorktreeUsage: Equatable, Sendable {
    public let paneIDs: [String]
    public let workspaces: [WorktreeWorkspaceUse]
    public let lastRetainedActivity: Date?
    public let otherPaneCount: Int
    public let otherRuntimeUnknown: Bool
    public let hasActiveTeam: Bool
    public var isInactive: Bool { paneIDs.isEmpty && otherPaneCount == 0 && !otherRuntimeUnknown && !hasActiveTeam }

    /// Call off the main actor: canonical containment may resolve symlinks.
    /// Historical association uses the exact worktree evidence on the TARGET;
    /// the source workspace must never be included just because it delegated.
    public static func project(path: String, panes: [WorkbenchPane], workspaces: [WorkbenchWorkspace], handoffs: [RelayHandoff],
                               otherPaneFolders: [String], otherRuntimeUnknown: Bool, activeTeamPaths: [String]) -> Self {
        let relevant = panes.filter { WorktreeCleanupPolicy.isNested($0.cwd, in: path) }
        let snapshots = handoffs.flatMap { handoff in
            [handoff.gitFactsAtDelegation, handoff.gitFactsAtReturn].compactMap { $0 }.filter { $0.managedWorktree?.path == path }
        }
        var names: [String: String] = [:]
        for pane in relevant { names[pane.workspaceID] = pane.workspaceName ?? pane.workspaceID }
        for workspace in workspaces where relevant.contains(where: { $0.workspaceID == workspace.workspaceID })
            || workspace.attachedFolders.contains(where: { WorktreeCleanupPolicy.isNested($0, in: path) })
            || workspace.newPaneFolder.map({ WorktreeCleanupPolicy.isNested($0, in: path) }) == true {
            names[workspace.workspaceID] = workspace.name
        }
        for handoff in handoffs where [handoff.gitFactsAtDelegation, handoff.gitFactsAtReturn].contains(where: { $0?.managedWorktree?.path == path }) {
            if names[handoff.targetWorkspaceID] == nil { names[handoff.targetWorkspaceID] = handoff.targetWorkspaceName ?? handoff.targetWorkspaceID }
        }
        let links = names.map { id, name in
            let ids = relevant.filter { $0.workspaceID == id }.map(\.id).sorted()
            return WorktreeWorkspaceUse(id: id, name: name, paneIDs: ids,
                canCloseWholeWorkspace: !ids.isEmpty && panes.filter { $0.workspaceID == id }.allSatisfy { ids.contains($0.id) })
        }.sorted { $0.id < $1.id }
        return Self(paneIDs: relevant.map(\.id).sorted(), workspaces: links,
                    lastRetainedActivity: snapshots.map(\.capturedAt).max(),
                    otherPaneCount: otherPaneFolders.filter { WorktreeCleanupPolicy.isNested($0, in: path) }.count,
                    otherRuntimeUnknown: otherRuntimeUnknown,
                    hasActiveTeam: activeTeamPaths.contains { WorktreeCleanupPolicy.isNested($0, in: path) })
    }
}

public struct WorktreeMergePreview: Equatable, Sendable {
    public let sourceCommit: String
    public let targetCommit: String
    public let targetRef: String
    public let hasConflicts: Bool
    public let conflictedPaths: [String]
    public let capturedAt: Date
    public static let limitation = "Prediction for these committed revisions using Git's built-in merge behavior. Uses isolated Git defaults; uncommitted edits, project/global configuration and merge drivers, working-tree attributes and remote updates are not included. Actual merge results may differ. No checkout, index, branch or source Git object is changed."
}

public struct WorktreeLifecycleInspection: Equatable, Sendable {
    public let cleanup: WorktreeCleanupPreview
    public let usage: WorktreeUsage
    public let recoveryPaths: [String]
    public let recoveryError: String?
    public let capturedAt: Date

    public var recoveryGuidance: String {
        let facts = cleanup.facts
        if !facts.registryReadable || !facts.recordInventoryReadable || !facts.pathInspectable {
            return "State is unknown. Restore access to the repository and Parley records, then Refresh. Do not recreate or remove the tree based on this reading."
        }
        if !recoveryPaths.isEmpty {
            return "Git lists the original creation marker at another path. Review that path, then Update Recorded Path. Only Parley's metadata changes."
        }
        if !facts.pathExists {
            return "The recorded folder is absent. Inspect Git's current worktree list for an external move. Clear Record is available only after a fresh check confirms absence; it never prunes Git's registry."
        }
        if facts.registered && !facts.creationTokenVerified && facts.parleyCreated {
            return "The folder's creation marker no longer matches. Parley cannot claim ownership. Open and inspect it as an existing worktree; removal here stays blocked. Do not recreate it."
        }
        if !facts.registered {
            return "The folder exists but Git does not register it at this path. Inspect it in Finder and Git before choosing any repair. Parley preserves the folder and its record."
        }
        return "Git still registers this path. Refresh after an external Git change. If creation previously succeeded without a record, select that existing tree in the browser and choose Track Existing; it remains person-owned."
    }
}

/// Guidance is chosen by the person, never inferred from terminal text.
public enum WorktreePermissionGuide {
    public static let explanation = "Linked worktrees keep their index and shared Git metadata outside the working folder. Being able to edit files does not prove a CLI can commit, switch branches or push. Parley cannot inspect a vendor's pending permission prompt."
    public static func guidance(for kind: PaneKind) -> String {
        switch kind {
        case .shell:
            return "A human Shell uses your normal account permissions. Check the exact Git error, directory ownership and any index.lock before changing anything; do not delete a lock while another Git operation is running."
        default:
            return "\(kind.label) retains its own tool approvals. Inspect its exact error and permission prompt in the pane. If it offers approval for the intended Git operation, review that operation there. If the vendor's sandbox still refuses the shared Git directory, review the pane's selected permission profile and the vendor's supported approval options. You can use a human Shell for that Git step. A changed launch profile takes effect only when you explicitly restart the pane. Parley never adds a permission root or retries the operation for you."
        }
    }
}
