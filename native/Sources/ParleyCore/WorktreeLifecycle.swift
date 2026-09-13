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

// MARK: - Board

/// One row of the worktree board: the facts Parley already records about a
/// tree, arranged so ownership, divergence and state read at a glance.
/// A row comes from Git's registry entry, from Parley's record, or both:
/// the registry says what is there, the record adds base, team, requester
/// and creation marker. Everything here is derived when the row is built
/// and nothing is stored.
public struct WorktreeBoardRow: Equatable, Sendable {
    public enum PanePresence: String, Equatable, Sendable {
        case running, stopped, closed
    }

    public enum Owner: Equatable, Sendable {
        /// Bound to a team session at approval.
        case team(objective: String, state: TeamSessionState)
        /// Created for an agent pane's request (a team member's tree keeps
        /// the team owner; this is the pane-requested case).
        case pane(name: String, presence: PanePresence)
        /// Created by the person from the browser, with no requester.
        case you
        /// Selected or tracked rather than created: no base and no creation
        /// marker; removal identifies it by Git's registry entry at its path.
        case person
        /// Known only from Git's registry; Parley holds no record for it.
        case unrecorded
    }

    public enum State: String, Equatable, Sendable {
        /// No background read has happened yet.
        case unread
        /// The folder is gone or Git no longer lists the tree.
        case missing
        /// Git lists the entry as prunable: the folder is gone but the
        /// registration remains. Prune is the action, never Remove.
        case stale
        /// Git could not be read; nothing is inferred.
        case unknown
        /// A pane is running inside it or its team is active.
        case inUse
        /// HEAD is contained in the primary checkout's HEAD and the tree is clean.
        case integrated
        /// Registered, nothing running, work not (or not fully) integrated.
        case idle

        public var label: String {
            switch self {
            case .unread: "Not read yet"
            case .missing: "Missing"
            case .stale: "Stale"
            case .unknown: "Unknown"
            case .inUse: "In use"
            case .integrated: "Integrated"
            case .idle: "Idle"
            }
        }
    }

    public let tree: GitWorktreeRecord?
    public let record: ManagedWorktreeRecord?
    public let facts: ManagedWorktreeFacts?
    public let owner: Owner
    public let state: State
    public let runningPaneCount: Int
    public let stoppedPaneCount: Int

    public var branch: String { record?.branch ?? tree?.shortIdentity ?? "detached" }
    public var path: String { record?.path ?? tree?.path ?? "" }
    public var warning: String? { record?.warning }
    public var isPrimary: Bool { tree?.isPrimary ?? false }
    public var isRecorded: Bool { record != nil }
    public var parleyCreated: Bool { record?.parleyCreated ?? false }
    public var lockReason: String? { tree?.lockReason }

    /// Integrate proposes a merge of the tree's branch; that needs a tree
    /// Git still lists and something to merge. A tree already contained in
    /// the primary with nothing ahead has no merge to propose; when the
    /// counts could not be read the offer stands and Git gives the answer.
    public var canIntegrate: Bool {
        guard !isPrimary, state != .stale, let facts, facts.registered == true else { return false }
        return !(facts.containedInPrimary == true && facts.aheadOfPrimary == 0)
    }

    public var ownerLabel: String {
        switch owner {
        case let .team(objective, state):
            let short = objective.count > 48 ? String(objective.prefix(47)) + "…" : objective
            return "Team: \(short) (\(state.label.lowercased()))"
        case let .pane(name, presence):
            return "\(name) (\(presence.rawValue))"
        case .you:
            return "You"
        case .person:
            return "Person-owned"
        case .unrecorded:
            return "Not recorded"
        }
    }

    public var baseLabel: String {
        guard let record else { return "" }
        guard let base = record.baseCommit else { return "base not recorded" }
        return "base \(base.prefix(12))" + (record.baseRef.map { " (\($0))" } ?? "")
    }

    public var headLabel: String {
        guard let facts, facts.registered == true else { return "" }
        guard let head = facts.head, !head.isEmpty else { return "HEAD unknown" }
        var text = "HEAD \(head.prefix(12))"
        if let branch = facts.currentBranch, branch != self.branch, branch != "HEAD" { text += " on \(branch)" }
        return text
    }

    public var changesLabel: String {
        guard let facts, facts.registered == true else { return "" }
        switch facts.changedPathCount {
        case 0?: return "clean"
        case let count?: return "\(count) changed"
        case nil: return "status unknown"
        }
    }

    public var divergenceLabel: String {
        guard let facts, facts.registered == true else { return "" }
        guard let ahead = facts.aheadOfPrimary, let behind = facts.behindPrimary else { return "divergence from primary unknown" }
        return "ahead \(ahead) · behind \(behind)"
    }

    public var panesLabel: String {
        var parts: [String] = []
        if runningPaneCount > 0 { parts.append("\(runningPaneCount) running") }
        if stoppedPaneCount > 0 { parts.append("\(stoppedPaneCount) stopped") }
        return parts.isEmpty ? "no panes" : parts.joined(separator: ", ") + (runningPaneCount + stoppedPaneCount == 1 ? " pane" : " panes")
    }

    /// The facts line under the branch, omitting whatever the state makes
    /// meaningless (a missing tree has no HEAD to show).
    public var factsLine: String {
        var parts = [baseLabel]
        switch state {
        case .missing: parts.append("folder gone or no longer listed by Git")
        case .stale: parts.append("folder gone; Git lists the entry as prunable")
        case .unknown: parts.append("Git could not be read")
        case .unread: parts.append("live state not read yet")
        case .inUse, .integrated, .idle:
            parts.append(headLabel)
            parts.append(changesLabel)
            parts.append(divergenceLabel)
        }
        if let lockReason { parts.append(lockReason.isEmpty ? "locked" : "locked: \(lockReason)") }
        if let record { parts.append(record.parleyCreated ? "created by Parley" : "existing tree") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The record-only form the browser used first; a registry entry is not
    /// needed when the record is the source.
    public static func derive(record: ManagedWorktreeRecord, facts: ManagedWorktreeFacts?, panesInside: [WorkbenchPane],
                              requester: WorkbenchPane?, teamObjective: String?, teamState: TeamSessionState?) -> WorktreeBoardRow {
        derive(tree: nil, record: record, facts: facts, panesInside: panesInside, requester: requester, teamObjective: teamObjective, teamState: teamState)
    }

    /// `requester` is the pane that asked for the tree if it still exists;
    /// nil with a recorded requester means that pane was closed. Team facts
    /// win over the requester, because a team member's tree belongs to the
    /// session even though one pane asked for it. A prunable registry entry
    /// is stale before any fact is consulted: there is no folder to read.
    public static func derive(tree: GitWorktreeRecord?, record: ManagedWorktreeRecord?, facts: ManagedWorktreeFacts?, panesInside: [WorkbenchPane],
                              requester: WorkbenchPane?, teamObjective: String?, teamState: TeamSessionState?) -> WorktreeBoardRow {
        let running = panesInside.filter { $0.isStarted && !$0.isDead }.count
        let stopped = panesInside.count - running
        let owner: Owner
        if let record {
            if record.teamSessionID != nil, let teamObjective, let teamState {
                owner = .team(objective: teamObjective, state: teamState)
            } else if let requesterID = record.requestedByPaneID {
                if let requester {
                    owner = .pane(name: requester.displayName, presence: requester.isStarted && !requester.isDead ? .running : .stopped)
                } else {
                    owner = .pane(name: requesterID, presence: .closed)
                }
            } else if record.parleyCreated {
                owner = .you
            } else {
                owner = .person
            }
        } else {
            owner = .unrecorded
        }
        let state: State
        if let tree, tree.pruneReason != nil {
            state = .stale
        } else if let facts {
            switch facts.registered {
            case false?: state = .missing
            case nil: state = .unknown
            case true?:
                if running > 0 || teamState == .active {
                    state = .inUse
                } else if facts.containedInPrimary == true, facts.changedPathCount == 0 {
                    state = .integrated
                } else {
                    state = .idle
                }
            }
        } else {
            state = .unread
        }
        return WorktreeBoardRow(tree: tree, record: record, facts: facts, owner: owner, state: state, runningPaneCount: running, stoppedPaneCount: stopped)
    }
}

// MARK: - Bulk removal plan

/// Remove integrated…: which of a repository's linked trees are proposed,
/// which are skipped and why, from fresh previews. Pure, so the decision
/// is checkable; the previews themselves come from the service.
public enum WorktreeBulkRemovalPlan {
    public struct Item: Equatable, Sendable {
        public let record: ManagedWorktreeRecord
        public let preview: WorktreeCleanupPreview
        public var passes: Bool { preview.decision == .removeTree }
        public var refusals: [String] { preview.refusals }
        public init(record: ManagedWorktreeRecord, preview: WorktreeCleanupPreview) {
            self.record = record
            self.preview = preview
        }
    }

    public struct Plan: Equatable, Sendable {
        public let passing: [Item]
        public let skipped: [Item]
        public var ignoredPathsByRecord: [String: [String]] { Dictionary(uniqueKeysWithValues: passing.map { ($0.record.id, $0.preview.ignoredPaths) }) }
        public var totalIgnored: Int { passing.reduce(0) { $0 + $1.preview.ignoredPaths.count } }
    }

    /// Only trees whose row reads Integrated are candidates; the previews
    /// then decide. A tree with any refusal is shown and skipped, never
    /// forced. Record-only cleanups (folder already gone) are skipped too:
    /// Prune is the action for those.
    public static func plan(items: [Item]) -> Plan {
        Plan(passing: items.filter(\.passes), skipped: items.filter { !$0.passes })
    }

    /// Whether the run continues after one removal outcome: any outcome
    /// that is not a confirmed removal stops the run so the person can look.
    public static func shouldContinue(after state: WorktreeRemovalOutcome.State) -> Bool {
        state == .removed
    }
}
