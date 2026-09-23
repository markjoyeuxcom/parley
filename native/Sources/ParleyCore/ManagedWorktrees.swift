import Foundation

public enum ManagedWorktreeError: LocalizedError, Equatable {
    case invalid(String)
    case git(String)
    case refused([String])
    /// `git worktree add` finished but Parley could not record it. The tree
    /// exists; creating again would fail on the existing branch, so the
    /// person must open or clean it up by hand.
    case createdButUnrecorded(path: String, detail: String)
    /// The add did not complete and Git does not list the tree. Whatever it
    /// left on disk stays; Parley never deletes a tree it cannot identify.
    case incomplete(path: String, detail: String)
    /// A tree is registered at the path but Parley cannot show it created it
    /// (another creation marker was already present after a successful add).
    /// Nothing is adopted or written.
    case ambiguous(path: String, detail: String)
    /// `git worktree add` did not return success, yet Git now lists a tree at
    /// the path. Only a successful add from this process is a creation
    /// receipt, so the tree is left unmanaged: no marker, no record, nothing
    /// deleted. It may well be usable (for example after a failing
    /// post-checkout hook) and can be opened or selected as an existing tree.
    case unmanaged(path: String, detail: String)
    /// Git's registry could not be read after the mutation, so nothing about
    /// the tree is claimed.
    case uncertain(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        case let .git(message): "Git refused or failed: \(message)"
        case let .refused(reasons): "Parley refused to remove this worktree: " + reasons.joined(separator: "; ")
        case let .createdButUnrecorded(path, detail):
            "The worktree was created at \(path) but Parley could not save its record (\(detail)). Do not create it again; open it as an existing worktree or remove it by hand."
        case let .incomplete(path, detail):
            "Creating the worktree did not complete (\(detail)). Git does not register \(path); check that folder by hand before trying again. Parley did not delete anything."
        case let .ambiguous(path, detail):
            "A worktree exists at \(path) but Parley cannot confirm it created it (\(detail)). It was not adopted, no marker was written and no record was saved; inspect it by hand. Do not create it again."
        case let .uncertain(path, detail):
            "The state of \(path) could not be read after the Git command (\(detail)). Nothing was recorded or deleted; inspect the repository by hand before trying again."
        case let .unmanaged(path, detail):
            "git worktree add did not succeed (\(detail)), but Git now lists a worktree at \(path). Parley did not take ownership of it: no marker or record was written and nothing was deleted. The tree may be usable; inspect it, then open it or select it as an existing worktree, or remove it yourself. Do not create it again."
        }
    }
}

/// Stable repository identity: the canonical common directory Git reports,
/// never an assumption that `.git` is a directory or that a branch name is
/// globally unique.
public struct GitRepositoryIdentity: Codable, Equatable, Sendable {
    public let commonDirectory: String
    public let toplevel: String

    public init(commonDirectory: String, toplevel: String) {
        self.commonDirectory = commonDirectory
        self.toplevel = toplevel
    }
}

/// One entry of `git worktree list --porcelain -z`, parsed on NUL boundaries
/// so a path containing a newline survives exactly. `path` is canonical for
/// comparison; `rawPath` is what Git printed.
public struct RegisteredWorktree: Equatable, Sendable {
    public let rawPath: String
    public let path: String
    public let head: String?
    public let branch: String?
    public let isDetached: Bool
    public let isPrimary: Bool
    public let lockReason: String?
    public let isLocked: Bool
    public let pruneReason: String?
    public let isPrunable: Bool

    public static func parse(_ data: Data) -> [RegisteredWorktree] {
        // Records are NUL-terminated lines; a record ends with an empty line (two NULs).
        let lines = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var records: [RegisteredWorktree] = []
        var current: [String: String] = [:]
        var order = 0
        func flush() {
            guard let raw = current["worktree"] else { current = [:]; return }
            records.append(RegisteredWorktree(rawPath: raw, path: GitWorktreeResolver.canonicalPath(raw), head: current["HEAD"],
                branch: current["branch"], isDetached: current["detached"] != nil, isPrimary: order == 0 && current["bare"] == nil,
                lockReason: current["locked"], isLocked: current["locked"] != nil,
                pruneReason: current["prunable"], isPrunable: current["prunable"] != nil))
            order += 1
            current = [:]
        }
        for line in lines {
            if line.isEmpty { flush(); continue }
            if let space = line.firstIndex(of: " ") {
                current[String(line[..<space])] = String(line[line.index(after: space)...])
            } else {
                current[line] = ""
            }
        }
        flush()
        return records
    }
}

/// Ownership and base metadata for a worktree Parley created or attached to a
/// team. Never execution authority: losing this file loses labels, not grants.
public struct ManagedWorktreeRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let commonDirectory: String
    public let path: String
    public let branch: String
    /// The ref the person typed; `baseCommit` is what it resolved to at that moment.
    public let baseRef: String?
    public let baseCommit: String?
    public let createdAt: Date
    /// True only when Parley ran `git worktree add` itself. Attached trees are
    /// openable facts, never cleanup candidates.
    public let parleyCreated: Bool
    /// Written by Parley into the worktree's own Git admin directory at
    /// creation. Cleanup requires the live tree to still carry it, so a tree
    /// someone removed and recreated at the same path is never treated as ours.
    public let creationToken: String?
    public var teamSessionID: String?
    public var requestedByPaneID: String?
    public var warning: String?

    public var recordedBase: String { baseCommit ?? "unknown" }

    public init(id: String, commonDirectory: String, path: String, branch: String, baseRef: String?, baseCommit: String?, createdAt: Date,
                parleyCreated: Bool, creationToken: String?, teamSessionID: String?, requestedByPaneID: String?, warning: String?) {
        self.id = id
        self.commonDirectory = commonDirectory
        self.path = path
        self.branch = branch
        self.baseRef = baseRef
        self.baseCommit = baseCommit
        self.createdAt = createdAt
        self.parleyCreated = parleyCreated
        self.creationToken = creationToken
        self.teamSessionID = teamSessionID
        self.requestedByPaneID = requestedByPaneID
        self.warning = warning
    }
}

public final class ManagedWorktreeStore: @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var records: [ManagedWorktreeRecord]
    }
    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func records() throws -> [ManagedWorktreeRecord] { try lock.withLock { try load().records } }

    public func record(path: String) throws -> ManagedWorktreeRecord? {
        let canonical = GitWorktreeResolver.canonicalPath(path)
        return try records().first { $0.path == canonical }
    }

    public func add(_ record: ManagedWorktreeRecord) throws {
        try lock.withLock {
            var document = try load()
            document.records.removeAll { $0.id == record.id || $0.path == record.path }
            document.records.append(record)
            try write(document)
        }
    }

    public func remove(id: String) throws {
        try lock.withLock {
            var document = try load()
            document.records.removeAll { $0.id == id }
            try write(document)
        }
    }

    /// Compare under the same lock as the durable write; a stale recovery
    /// never overwrites a concurrent edit or another record at the destination.
    public func replace(_ expected: ManagedWorktreeRecord, with updated: ManagedWorktreeRecord) throws {
        try lock.withLock {
            var document = try load()
            guard let index = document.records.firstIndex(where: { $0.id == expected.id }),
                  document.records[index] == expected,
                  !document.records.contains(where: { $0.id != expected.id && $0.path == updated.path }) else {
                throw ManagedWorktreeError.invalid("The worktree record changed. Refresh before recovering it.")
            }
            document.records[index] = updated
            try write(document)
        }
    }

    private func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: file.path) else { return Document(records: []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Document.self, from: Data(contentsOf: file))
    }

    private func write(_ document: Document) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Branch names Parley will pass to Git: a strict subset of what Git accepts,
/// validated before any process runs so option injection, traversal and
/// control characters never reach argv.
public enum WorktreeNaming {
    public static let maximumBranchLength = 120

    public static func validateBranch(_ branch: String) throws {
        guard !branch.isEmpty, branch.count <= maximumBranchLength else { throw ManagedWorktreeError.invalid("Enter a branch name of at most \(maximumBranchLength) characters.") }
        guard !branch.hasPrefix("-"), !branch.hasPrefix("refs/"), !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.contains(".."), !branch.contains("//"), !branch.hasSuffix(".lock"), !branch.hasSuffix("."), branch != "HEAD",
              branch.unicodeScalars.allSatisfy({ scalar in
                  let v = scalar.value
                  return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5a) || (v >= 0x61 && v <= 0x7a) || v == 0x2e || v == 0x5f || v == 0x2f || v == 0x2d
              }),
              !branch.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock") }) else {
            throw ManagedWorktreeError.invalid("Branch names use letters, digits, '.', '_', '-' and '/', with no leading '-', no '..', no empty or dot-led parts and no 'refs/' prefix.")
        }
    }

    public static func validateRef(_ ref: String) throws {
        guard !ref.isEmpty, ref.count <= 200, !ref.hasPrefix("-"),
              !ref.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }) else {
            throw ManagedWorktreeError.invalid("Enter a starting ref (branch, tag or commit) without spaces, control characters or a leading '-'.")
        }
    }

    /// The folder name under `.worktrees/` for a branch: slashes become dashes.
    public static func slug(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }
}

// MARK: - Cleanup policy

/// Everything the cleanup decision needs, read fresh from Git and the workbench.
public struct WorktreeCleanupFacts: Equatable, Sendable {
    public var parleyCreated: Bool
    /// The live tree's admin directory still carries the creation token.
    public var creationTokenVerified: Bool
    public var registered: Bool
    /// Git's worktree list was read successfully; without it "unregistered"
    /// is only a default and must never justify anything.
    public var registryReadable: Bool
    /// The recorded path could be inspected (lstat succeeded or reported "no
    /// such file"). A permission or I/O error is unknown, never absence.
    public var pathInspectable: Bool
    /// Any filesystem item at the recorded path, directory or not (a dangling
    /// symlink counts). Only a confirmed "no such file" is an absence.
    public var pathExists: Bool
    /// The item at the recorded path is a real directory; anything else that
    /// exists there makes the tree's identity uncertain.
    public var pathIsDirectory: Bool
    /// Parley's own record store was read successfully; nested trees known
    /// only by record cannot be checked without it.
    public var recordInventoryReadable: Bool
    /// The target record was found in that fresh inventory, and was equal to
    /// the record the caller holds. A deleted store reads as empty, so the
    /// caller's copy is never trusted on its own.
    public var recordPresentInInventory: Bool
    public var recordUnchangedInInventory: Bool
    public var locked: Bool
    public var prunable: Bool
    /// Other registered worktrees of the repository, or other trees Parley
    /// knows by record, whose root lies inside this tree. Removing the parent
    /// would delete them with their uncommitted files.
    public var nestedWorktreePaths: [String]
    public var livePaneFolders: [String]
    public var otherRuntimePaneFolders: [String]
    public var otherRuntimeStateUnreadable: Bool
    public var modifiedPaths: [String]
    public var untrackedPaths: [String]
    public var ignoredPaths: [String]
    public var ignoredListTruncated: Bool
    public var upstreamAheadCount: Int
    public var hasUpstream: Bool
    public var mergedIntoPrimary: Bool
    public var statusUncertain: Bool
    public var path: String
    /// Git lists the recorded path as the repository's primary checkout. A
    /// tracked record can point there; removal never can.
    public var isPrimary: Bool

    public init(parleyCreated: Bool, creationTokenVerified: Bool, registered: Bool, registryReadable: Bool, pathInspectable: Bool, pathExists: Bool, pathIsDirectory: Bool,
                recordInventoryReadable: Bool, recordPresentInInventory: Bool, recordUnchangedInInventory: Bool, locked: Bool, prunable: Bool,
                nestedWorktreePaths: [String], livePaneFolders: [String],
                otherRuntimePaneFolders: [String], otherRuntimeStateUnreadable: Bool, modifiedPaths: [String], untrackedPaths: [String],
                ignoredPaths: [String], ignoredListTruncated: Bool, upstreamAheadCount: Int, hasUpstream: Bool, mergedIntoPrimary: Bool,
                statusUncertain: Bool, path: String, isPrimary: Bool = false) {
        self.parleyCreated = parleyCreated
        self.creationTokenVerified = creationTokenVerified
        self.registered = registered
        self.registryReadable = registryReadable
        self.pathInspectable = pathInspectable
        self.pathExists = pathExists
        self.pathIsDirectory = pathIsDirectory
        self.recordInventoryReadable = recordInventoryReadable
        self.recordPresentInInventory = recordPresentInInventory
        self.recordUnchangedInInventory = recordUnchangedInInventory
        self.locked = locked
        self.prunable = prunable
        self.nestedWorktreePaths = nestedWorktreePaths
        self.livePaneFolders = livePaneFolders
        self.otherRuntimePaneFolders = otherRuntimePaneFolders
        self.otherRuntimeStateUnreadable = otherRuntimeStateUnreadable
        self.modifiedPaths = modifiedPaths
        self.untrackedPaths = untrackedPaths
        self.ignoredPaths = ignoredPaths
        self.ignoredListTruncated = ignoredListTruncated
        self.upstreamAheadCount = upstreamAheadCount
        self.hasUpstream = hasUpstream
        self.mergedIntoPrimary = mergedIntoPrimary
        self.statusUncertain = statusUncertain
        self.path = path
        self.isPrimary = isPrimary
    }
}

/// The pure decision table. Every refusal is a sentence the person sees.
public enum WorktreeCleanupPolicy {
    public static let maximumReviewedIgnoredPaths = 200

    public static func isNested(_ folder: String, in path: String) -> Bool {
        let inside = GitWorktreeResolver.canonicalPath(folder)
        let root = GitWorktreeResolver.canonicalPath(path)
        return inside == root || inside.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public enum Decision: Equatable, Sendable {
        case refuse([String])
        /// Run one `git worktree remove` for a live, verified tree.
        case removeTree
        /// The tree is gone and Git no longer lists it as present; only
        /// Parley's own record is cleared, and Git is not run.
        case clearRecordOnly
    }

    public static func decision(for facts: WorktreeCleanupFacts) -> Decision {
        // Record-only cleanup needs a confirmed absence: a readable registry
        // that does not list a present tree, and no folder on disk.
        if facts.registryReadable, facts.recordInventoryReadable, facts.recordPresentInInventory, facts.recordUnchangedInInventory,
           facts.pathInspectable, !facts.pathExists, !facts.registered || facts.prunable { return .clearRecordOnly }
        let reasons = refusals(for: facts)
        return reasons.isEmpty ? .removeTree : .refuse(reasons)
    }

    public static func refusals(for facts: WorktreeCleanupFacts) -> [String] {
        var reasons: [String] = []
        // A tracked tree has no marker to compare: Git's registry entry at the
        // recorded path is its identity, checked below. A Parley-created tree
        // must still carry the marker it was created with.
        if facts.parleyCreated, !facts.creationTokenVerified { reasons.append("the tree at this path no longer carries Parley's creation marker, so it may have been recreated by someone else") }
        if facts.isPrimary { reasons.append("this is the repository's primary checkout, not a linked worktree; Parley never removes it") }
        if !facts.nestedWorktreePaths.isEmpty {
            reasons.append("it contains another registered worktree, which would be deleted with it: " + facts.nestedWorktreePaths.prefix(5).joined(separator: ", "))
        }
        if !facts.registryReadable { reasons.append("Git's worktree list could not be read, so the tree's registration is unknown") }
        if !facts.recordInventoryReadable { reasons.append("Parley's worktree records could not be read, so nested trees it knows about cannot be checked") }
        else if !facts.recordPresentInInventory { reasons.append("Parley's record of this worktree is missing from its store; reopen the worktree browser and try again") }
        else if !facts.recordUnchangedInInventory { reasons.append("Parley's record of this worktree changed since this preview; reopen the worktree browser and try again") }
        if !facts.pathInspectable { reasons.append("the recorded path could not be inspected (permission or I/O error), so whether the tree exists is unknown") }
        if facts.pathExists, !facts.pathIsDirectory { reasons.append("something that is not a directory occupies the recorded path, so the tree's identity is uncertain") }
        if !facts.registered { reasons.append("Git does not register this path as a worktree of its repository, so its identity is uncertain") }
        if facts.locked { reasons.append("the worktree is locked") }
        if facts.prunable { reasons.append("Git reports the worktree as prunable or missing") }
        if facts.livePaneFolders.contains(where: { isNested($0, in: facts.path) }) {
            reasons.append("a live pane's working folder is inside this worktree; close or move it first")
        }
        if facts.otherRuntimeStateUnreadable { reasons.append("another Parley runtime's state could not be read, so its panes are unknown") }
        if facts.otherRuntimePaneFolders.contains(where: { isNested($0, in: facts.path) }) {
            reasons.append("another Parley runtime lists a pane inside this worktree")
        }
        if facts.statusUncertain { reasons.append("Git status could not be read") }
        if !facts.modifiedPaths.isEmpty { reasons.append("modified tracked files: " + facts.modifiedPaths.prefix(5).joined(separator: ", ")) }
        if !facts.untrackedPaths.isEmpty { reasons.append("untracked files: " + facts.untrackedPaths.prefix(5).joined(separator: ", ")) }
        if facts.ignoredListTruncated { reasons.append("more than \(maximumReviewedIgnoredPaths) ignored entries; too many to review here") }
        if facts.hasUpstream {
            if facts.upstreamAheadCount > 0 {
                reasons.append("\(facts.upstreamAheadCount) commit\(facts.upstreamAheadCount == 1 ? "" : "s") not on the upstream according to local tracking state")
            }
        } else if !facts.mergedIntoPrimary {
            reasons.append("no upstream and not merged into the primary worktree; push state is unknown")
        }
        return reasons
    }
}

public struct WorktreeCleanupPreview: Equatable, Sendable {
    public let record: ManagedWorktreeRecord
    public let facts: WorktreeCleanupFacts
    public let decision: WorktreeCleanupPolicy.Decision
    /// Ignored entries `git worktree remove` would delete silently; the person
    /// must acknowledge exactly this list. An entry ending in `/` is a
    /// directory and means its entire contents.
    public let ignoredPaths: [String]

    public var refusals: [String] {
        if case let .refuse(reasons) = decision { return reasons }
        return []
    }

    /// The preservation evidence the removal actually relies on, worded from
    /// the facts rather than from a fixed sentence.
    public var preservationSummary: String {
        var parts = ["Git status shows no modified tracked files and no untracked files"]
        if facts.hasUpstream {
            parts.append("the branch has an upstream and local remote-tracking state shows no commits ahead of it (Parley did not contact the remote; a newer push or a rewritten remote branch is not known here)")
        } else {
            parts.append("the branch has no upstream and its HEAD is already contained in the primary worktree's HEAD")
        }
        parts.append("no pane folder of this runtime or the other Parley runtime is inside the tree")
        parts.append("the tree is not locked and contains no other registered worktree")
        return parts.joined(separator: "; ")
    }
}

public struct WorktreeRemovalOutcome: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// The folder is gone and Git no longer lists the tree (or it was
        /// already absent and only the record was cleared).
        case removed
        /// Git still lists the tree and the folder remains. After a Git error
        /// some files may already have been deleted, so the folder is not
        /// guaranteed intact; the record is kept.
        case retained
        /// Git's registry could not be read, or registration and folder
        /// disagree; nothing is claimed and the record is kept.
        case uncertain
    }

    public let path: String
    public let state: State
    /// Parley's own record was cleared. Only ever true with `.removed`.
    public let recordRemoved: Bool
    /// Set when the record could not be cleared after a confirmed removal.
    public let recordError: String?
    public let detail: String

    public var removedPath: String { path }
}

/// Facts for display, read in the background; nil means unknown, never clean.
public struct ManagedWorktreeFacts: Equatable, Sendable {
    public let recordID: String
    public let currentBranch: String?
    public let head: String?
    public let changedPathCount: Int?
    public let upstreamAheadCount: Int?
    public let hasUpstream: Bool?
    /// true: Git lists the tree; false: the folder is gone or Git lists the
    /// repository without it; nil: the question could not be answered.
    public let registered: Bool?
    /// The primary checkout's HEAD at read time, so the board can say what
    /// "ahead" and "behind" are measured against.
    public let primaryHead: String?
    /// Commits on this tree's HEAD that the primary checkout does not have,
    /// and the reverse, from one `rev-list --left-right --count`. nil when
    /// either side was unreadable.
    public let aheadOfPrimary: Int?
    public let behindPrimary: Int?
    /// Whether this tree's HEAD is an ancestor of the primary checkout's HEAD:
    /// true means every commit here is already integrated. nil is unknown.
    public let containedInPrimary: Bool?

    public init(recordID: String, currentBranch: String?, head: String?, changedPathCount: Int?, upstreamAheadCount: Int?,
                hasUpstream: Bool?, registered: Bool?, primaryHead: String? = nil, aheadOfPrimary: Int? = nil,
                behindPrimary: Int? = nil, containedInPrimary: Bool? = nil) {
        self.recordID = recordID
        self.currentBranch = currentBranch
        self.head = head
        self.changedPathCount = changedPathCount
        self.upstreamAheadCount = upstreamAheadCount
        self.hasUpstream = hasUpstream
        self.registered = registered
        self.primaryHead = primaryHead
        self.aheadOfPrimary = aheadOfPrimary
        self.behindPrimary = behindPrimary
        self.containedInPrimary = containedInPrimary
    }
}

// MARK: - Service

/// Native-only worktree lifecycle: fixed executable, fixed argv, scrubbed
/// environment, bounded timeouts, and Git's own refusals with no `--force`.
public struct ManagedWorktreeService: Sendable {
    public struct CreateRequest: Equatable, Sendable {
        public let repositoryFolder: String
        public let branch: String
        public let baseRef: String
        /// The commit the person saw in the preview. When set, creation is
        /// refused if the ref now resolves elsewhere instead of silently
        /// following the moved ref.
        public let expectedBaseCommit: String?
        /// The repository and exact path the person approved. When set, the
        /// folder is re-resolved and both must match before any directory,
        /// exclude line or Git command is written.
        public let expectedCommonDirectory: String?
        public let expectedPath: String?
        public let teamSessionID: String?
        public let requestedByPaneID: String?

        public init(repositoryFolder: String, branch: String, baseRef: String, expectedBaseCommit: String? = nil, expectedCommonDirectory: String? = nil,
                    expectedPath: String? = nil, teamSessionID: String? = nil, requestedByPaneID: String? = nil) {
            self.repositoryFolder = repositoryFolder
            self.branch = branch
            self.baseRef = baseRef
            self.expectedBaseCommit = expectedBaseCommit
            self.expectedCommonDirectory = expectedCommonDirectory
            self.expectedPath = expectedPath
            self.teamSessionID = teamSessionID
            self.requestedByPaneID = requestedByPaneID
        }

        /// The only form native flows use: every value comes from the preview
        /// the person approved, so the mutation is bound to that location.
        public init(preview: CreatePreview, repositoryFolder: String, teamSessionID: String? = nil, requestedByPaneID: String? = nil) {
            self.init(repositoryFolder: repositoryFolder, branch: preview.branch, baseRef: preview.baseRef, expectedBaseCommit: preview.baseCommit,
                expectedCommonDirectory: preview.commonDirectory, expectedPath: preview.path, teamSessionID: teamSessionID, requestedByPaneID: requestedByPaneID)
        }
    }

    /// What the person is shown before approving a creation. Every value is
    /// read from Git at preview time and captured, never inferred.
    public struct CreatePreview: Equatable, Sendable {
        public let repositoryToplevel: String
        public let commonDirectory: String
        public let branch: String
        public let baseRef: String
        public let baseCommit: String
        public let path: String
        public let excludeEntryPresent: Bool
        public static let executionNotice = "Git will check out the base commit into the new folder. That runs any configured post-checkout hooks and clean/smudge or process filters (for example git-lfs) from this repository and your Git configuration with this application's permissions, possibly including network access. Parley does not disable hooks or filters and never retries a failed add."
    }

    public static let worktreesDirectoryName = ".worktrees"
    public static let excludeEntry = ".worktrees/"
    public static let creationMarkerName = "parley-worktree-owner"

    private let store: ManagedWorktreeStore
    private let gitExecutable: URL
    /// For the operations the person confirms (create, prune, remove,
    /// delete a branch), which Git may need to run programs for.
    private let environment: [String: String]
    /// For every read, which runs inside `GitReadBoundary`.
    private let readEnvironment: [String: String]
    private let readTimeout: TimeInterval
    private let mutationTimeout: TimeInterval

    public init(store: ManagedWorktreeStore, gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                readTimeout: TimeInterval = 5, mutationTimeout: TimeInterval = 120) {
        self.store = store
        self.gitExecutable = gitExecutable
        // Inherited GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_CONFIG_* and the
        // like would redirect -C; none of them may reach a native command.
        var scrubbed = environment.filter { !$0.key.hasPrefix("GIT_") }
        scrubbed["GIT_OPTIONAL_LOCKS"] = "0"
        scrubbed["GIT_TERMINAL_PROMPT"] = "0"
        scrubbed["GIT_PAGER"] = "cat"
        scrubbed["PAGER"] = "cat"
        scrubbed["LC_ALL"] = "C"
        self.environment = scrubbed
        self.readEnvironment = GitReadBoundary.environment(scrubbed)
        self.readTimeout = max(0.5, readTimeout)
        self.mutationTimeout = max(1, mutationTimeout)
    }

    public func scrubbedEnvironment() -> [String: String] { environment }

    enum ItemState: Equatable {
        case absent
        case present(isDirectory: Bool)
        case unknown
    }

    /// lstat-style inspection: a real "no such file" is the only absence;
    /// permission or I/O errors are unknown, and symlinks are not followed.
    static func itemState(at path: String) -> ItemState {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return .present(isDirectory: (attributes[.type] as? FileAttributeType) == .typeDirectory)
        } catch {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError { return .absent }
            if underlying?.domain == NSPOSIXErrorDomain, underlying?.code == Int(ENOENT) { return .absent }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return .absent }
            return .unknown
        }
    }

    /// Records are compared against the store before destructive cleanup, and
    /// the store keeps whole-second ISO 8601 dates, so a record is created
    /// with the exact value the store will read back.
    static func storedNow() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    // MARK: Reads

    public func identity(of folder: String) throws -> GitRepositoryIdentity {
        // Each output is one path. Combining them and splitting on LF makes
        // an embedded newline in a legal filename indistinguishable from a delimiter.
        let common = GitWorktreeResolver.singlePathOutput(try run(in: folder,
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: readTimeout).stdoutText)
        let top = GitWorktreeResolver.singlePathOutput(try run(in: folder,
            ["rev-parse", "--path-format=absolute", "--show-toplevel"], timeout: readTimeout).stdoutText)
        guard common.hasPrefix("/"), top.hasPrefix("/") else {
            throw ManagedWorktreeError.git("could not resolve the repository for \(folder)")
        }
        return GitRepositoryIdentity(commonDirectory: GitWorktreeResolver.canonicalPath(common), toplevel: GitWorktreeResolver.canonicalPath(top))
    }

    public func registeredWorktrees(of identity: GitRepositoryIdentity) throws -> [RegisteredWorktree] {
        let output = try run(in: identity.toplevel, ["worktree", "list", "--porcelain", "-z"], timeout: readTimeout)
        return RegisteredWorktree.parse(output.stdout)
    }

    public func resolveCommit(_ ref: String, in folder: String) throws -> String {
        try WorktreeNaming.validateRef(ref)
        let output = try run(in: folder, ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], timeout: readTimeout)
        let commit = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.count == 40, commit.allSatisfy({ $0.isHexDigit }) else { throw ManagedWorktreeError.git("\(ref) did not resolve to a commit") }
        return commit
    }

    public func plannedPath(for branch: String, in identity: GitRepositoryIdentity) throws -> String {
        try WorktreeNaming.validateBranch(branch)
        return identity.toplevel + "/" + Self.worktreesDirectoryName + "/" + WorktreeNaming.slug(for: branch)
    }

    public func createPreview(repositoryFolder: String, branch: String, baseRef: String) throws -> CreatePreview {
        try WorktreeNaming.validateBranch(branch)
        try WorktreeNaming.validateRef(baseRef)
        let identity = try identity(of: repositoryFolder)
        let baseCommit = try resolveCommit(baseRef, in: identity.toplevel)
        try refuseExistingBranch(branch, in: identity)
        let path = try plannedPath(for: branch, in: identity)
        guard !FileManager.default.fileExists(atPath: path) else { throw ManagedWorktreeError.invalid("\(path) already exists.") }
        let exclude = URL(fileURLWithPath: identity.commonDirectory).appendingPathComponent("info/exclude")
        let present = (try? String(contentsOf: exclude, encoding: .utf8))?.components(separatedBy: "\n")
            .contains(where: { $0 == Self.excludeEntry || $0 == Self.worktreesDirectoryName }) ?? false
        return CreatePreview(repositoryToplevel: identity.toplevel, commonDirectory: identity.commonDirectory, branch: branch, baseRef: baseRef,
            baseCommit: baseCommit, path: path, excludeEntryPresent: present)
    }

    private func refuseExistingBranch(_ branch: String, in identity: GitRepositoryIdentity) throws {
        do {
            _ = try run(in: identity.toplevel, ["check-ref-format", "--branch", branch], timeout: readTimeout)
        } catch { throw ManagedWorktreeError.invalid("Git does not accept the branch name \(branch).") }
        let lookup = try runAllowingFailure(in: identity.toplevel, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], timeout: readTimeout)
        switch lookup.status {
        case 0: throw ManagedWorktreeError.invalid("The branch \(branch) already exists. Choose a new branch name; Parley never reuses or forces a branch.")
        case 1: return
        default: throw ManagedWorktreeError.git("could not check whether \(branch) exists: \(lookup.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Create / attach

    public func create(_ request: CreateRequest) throws -> ManagedWorktreeRecord {
        try WorktreeNaming.validateBranch(request.branch)
        try WorktreeNaming.validateRef(request.baseRef)
        let identity = try identity(of: request.repositoryFolder)
        // The approved location is checked before anything is written: a
        // folder that now resolves to another repository or another path is
        // refused, whatever commits that repository happens to share.
        if let expected = request.expectedCommonDirectory, expected != identity.commonDirectory {
            throw ManagedWorktreeError.invalid("\(request.repositoryFolder) now resolves to a different repository (\(identity.commonDirectory)) than the one previewed (\(expected)). Nothing was created; review the preview again.")
        }
        let baseCommit = try resolveCommit(request.baseRef, in: identity.toplevel)
        if let expected = request.expectedBaseCommit, expected != baseCommit {
            throw ManagedWorktreeError.invalid("\(request.baseRef) now resolves to \(baseCommit.prefix(12)), not the previewed \(expected.prefix(12)). Review the preview again.")
        }
        let path = try plannedPath(for: request.branch, in: identity)
        if let expected = request.expectedPath, GitWorktreeResolver.canonicalPath(expected) != path {
            throw ManagedWorktreeError.invalid("The worktree would now be created at \(path), not at the previewed \(expected). Nothing was created; review the preview again.")
        }
        try refuseExistingBranch(request.branch, in: identity)
        let worktreesDirectory = identity.toplevel + "/" + Self.worktreesDirectoryName
        try prepareWorktreesDirectory(worktreesDirectory, toplevel: identity.toplevel)
        guard !FileManager.default.fileExists(atPath: path) else { throw ManagedWorktreeError.invalid("\(path) already exists.") }
        try ensureLocalExclude(commonDirectory: identity.commonDirectory)

        // The add checks out the base commit, which may run configured hooks and
        // filters. It is bounded and never retried: afterwards Git's own
        // registry decides what happened, and nothing on disk is deleted.
        let add = try runObserving(in: identity.toplevel, ["worktree", "add", "-b", request.branch, "--end-of-options", path, baseCommit], timeout: mutationTimeout)
        let canonicalPath = GitWorktreeResolver.canonicalPath(path)
        let addDetail = add.status == 124
            ? "timed out after \(Int(mutationTimeout)) seconds"
            : "exit status \(add.status)" + (add.stderrText.isEmpty ? "" : ": " + add.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let registry = try? registeredWorktrees(of: identity) else {
            throw ManagedWorktreeError.uncertain(path: path, detail: "git worktree add \(addDetail); Git's worktree list could not be read afterwards")
        }
        guard registry.contains(where: { $0.path == canonicalPath }) else {
            throw ManagedWorktreeError.incomplete(path: path, detail: add.status == 0 ? "Git returned success but does not list the tree" : addDetail)
        }
        // Only a successful add from this process is a creation receipt. A
        // nonzero or timed-out add that nonetheless registered a tree leaves it
        // unmanaged: neither stderr wording nor a matching branch and HEAD
        // proves who created it.
        guard add.status == 0 else {
            throw ManagedWorktreeError.unmanaged(path: path, detail: addDetail)
        }
        let adminDirectory = try? adminDirectory(ofWorktreeAt: canonicalPath, commonDirectory: identity.commonDirectory)
        let markerFile = adminDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent(Self.creationMarkerName) }
        guard let markerFile else {
            throw ManagedWorktreeError.ambiguous(path: path, detail: "the tree's admin directory could not be resolved inside the repository")
        }
        if FileManager.default.fileExists(atPath: markerFile.path) {
            throw ManagedWorktreeError.ambiguous(path: path, detail: "the tree already carries another creation marker")
        }
        var warning: String?
        let record = ManagedWorktreeRecord(id: UUID().uuidString.lowercased(), commonDirectory: identity.commonDirectory,
            path: canonicalPath, branch: request.branch, baseRef: request.baseRef, baseCommit: baseCommit,
            createdAt: Self.storedNow(), parleyCreated: true, creationToken: UUID().uuidString.lowercased(), teamSessionID: request.teamSessionID,
            requestedByPaneID: request.requestedByPaneID, warning: nil)
        do {
            try Data(((record.creationToken ?? "") + "\n").utf8).write(to: markerFile, options: .withoutOverwriting)
        } catch {
            throw ManagedWorktreeError.createdButUnrecorded(path: path, detail: "creation marker: \(error.localizedDescription)")
        }
        let head = (try? run(in: canonicalPath, ["rev-parse", "HEAD"], timeout: readTimeout))?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if head != baseCommit {
            warning = (warning.map { $0 + " " } ?? "") + "HEAD after creation is \(head ?? "unknown"), not the recorded base."
        }
        var recorded = record
        recorded.warning = warning
        do { try store.add(recorded) } catch {
            throw ManagedWorktreeError.createdButUnrecorded(path: path, detail: error.localizedDescription)
        }
        return recorded
    }

    /// The worktree's own admin directory under `<common>/worktrees/<name>`,
    /// resolved by Git for the live tree and required to sit inside the
    /// recorded common directory.
    private func adminDirectory(ofWorktreeAt path: String, commonDirectory: String) throws -> String {
        let output = try run(in: path, ["rev-parse", "--path-format=absolute", "--git-dir"], timeout: readTimeout)
        let directory = GitWorktreeResolver.canonicalPath(GitWorktreeResolver.singlePathOutput(output.stdoutText))
        guard directory.hasPrefix(commonDirectory + "/worktrees/") else {
            throw ManagedWorktreeError.invalid("\(path) is not a linked worktree of the recorded repository.")
        }
        return directory
    }

    public func creationTokenMatches(_ record: ManagedWorktreeRecord) -> Bool {
        guard record.parleyCreated, let token = record.creationToken, !token.isEmpty,
              let directory = try? adminDirectory(ofWorktreeAt: record.path, commonDirectory: record.commonDirectory),
              let stored = try? String(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(Self.creationMarkerName), encoding: .utf8) else {
            return false
        }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == token
    }

    /// Records a registered worktree as attached without taking ownership. The
    /// base is recorded only when the person supplies a ref now.
    public func attach(existingPath: String, in repositoryFolder: String, baseRef: String?, teamSessionID: String? = nil,
                       requestedByPaneID: String? = nil) throws -> ManagedWorktreeRecord {
        let identity = try identity(of: repositoryFolder)
        let canonical = GitWorktreeResolver.canonicalPath(existingPath)
        guard let registered = try registeredWorktrees(of: identity).first(where: { $0.path == canonical }) else {
            throw ManagedWorktreeError.invalid("\(existingPath) is not a registered worktree of this repository.")
        }
        guard !registered.isPrunable else { throw ManagedWorktreeError.invalid("\(existingPath) is missing or prunable.") }
        // Ownership never transfers by path: an existing record keeps
        // parleyCreated only while the live tree still carries its token.
        if let existing = try store.record(path: canonical), existing.parleyCreated {
            guard existing.commonDirectory == identity.commonDirectory, creationTokenMatches(existing) else {
                throw ManagedWorktreeError.invalid("This path has a Parley creation record but its repository or creation marker no longer matches. Inspect the existing record; attaching cannot replace it with an unowned tree.")
            }
            var updated = existing
            updated.teamSessionID = teamSessionID ?? existing.teamSessionID
            try store.add(updated)
            return updated
        }
        let baseCommit = try baseRef.map { try resolveCommit($0, in: identity.toplevel) }
        let branch = registered.branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 } ?? (registered.isDetached ? "(detached)" : "(unknown)")
        let record = ManagedWorktreeRecord(id: UUID().uuidString.lowercased(), commonDirectory: identity.commonDirectory, path: canonical,
            branch: branch, baseRef: baseRef, baseCommit: baseCommit, createdAt: Self.storedNow(), parleyCreated: false, creationToken: nil,
            teamSessionID: teamSessionID, requestedByPaneID: requestedByPaneID, warning: nil)
        try store.add(record)
        return record
    }

    // MARK: Prune and branch deletion

    /// What `git worktree prune` would forget: every entry Git lists as
    /// prunable. Git has no per-entry prune, so the preview shows them all
    /// and the person acknowledges the whole list.
    public struct PrunePreview: Equatable, Sendable {
        public let repositoryToplevel: String
        public let entries: [RegisteredWorktree]
        public var paths: [String] { entries.map(\.path) }
    }

    public struct PruneOutcome: Equatable, Sendable {
        public let forgotten: [String]
        public let remaining: [String]
        public let detail: String
    }

    public func prunePreview(in repositoryFolder: String) throws -> PrunePreview {
        let identity = try identity(of: repositoryFolder)
        let toplevel = primaryToplevel(identity) ?? identity.toplevel
        let entries = try registeredWorktrees(of: GitRepositoryIdentity(commonDirectory: identity.commonDirectory, toplevel: toplevel)).filter(\.isPrunable)
        return PrunePreview(repositoryToplevel: toplevel, entries: entries)
    }

    /// One `git worktree prune` after re-reading the registry and requiring
    /// the acknowledged list to match it exactly. A prunable entry has no
    /// folder, so nothing on disk is touched and no branch changes; the
    /// outcome reports only what the registry shows afterwards.
    public func prune(in repositoryFolder: String, acknowledgedPaths: [String]) throws -> PruneOutcome {
        let preview = try prunePreview(in: repositoryFolder)
        guard !preview.entries.isEmpty else { throw ManagedWorktreeError.invalid("Git lists no prunable worktree entry for this repository.") }
        guard Set(preview.paths) == Set(acknowledgedPaths) else {
            throw ManagedWorktreeError.refused(["the prunable entries changed since the preview; review the list again"])
        }
        let result = try runObserving(in: preview.repositoryToplevel, ["worktree", "prune"], timeout: mutationTimeout)
        let after = (try? prunePreview(in: repositoryFolder).paths) ?? preview.paths
        let forgotten = preview.paths.filter { !after.contains($0) }
        let detail: String
        if result.status == 0 {
            detail = "Git forgot \(forgotten.count) of \(preview.paths.count) prunable entr\(preview.paths.count == 1 ? "y" : "ies"). No folder or branch changed."
        } else {
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = (result.status == 124 ? "git worktree prune timed out after \(Int(mutationTimeout)) seconds" : "git worktree prune reported exit status \(result.status)")
                + (text.isEmpty ? "" : ": " + text) + ". \(forgotten.count) entr\(forgotten.count == 1 ? "y is" : "ies are") no longer listed."
        }
        return PruneOutcome(forgotten: forgotten, remaining: after, detail: detail)
    }

    public struct BranchDeletionPreview: Equatable, Sendable {
        public let branch: String
        public let commit: String
        public let mergedIntoPrimaryHead: Bool
        /// The registered worktree that has the branch checked out, if any;
        /// Git refuses to delete such a branch and so does the preview.
        public let checkedOutAt: String?
        /// The holder is a prunable entry whose folder is gone: Git still
        /// counts the branch as checked out until the entry is pruned.
        public let heldByStaleEntry: Bool
    }

    public enum BranchDeletionOutcome: Equatable, Sendable {
        case deleted(commit: String)
        /// Git's own words, shown as they are. Parley never retries with -D.
        case refused(String)
    }

    public func branchDeletionPreview(_ branch: String, in repositoryFolder: String) throws -> BranchDeletionPreview {
        try WorktreeNaming.validateBranch(branch)
        let identity = try identity(of: repositoryFolder)
        let toplevel = primaryToplevel(identity) ?? identity.toplevel
        let commit = try run(in: toplevel, ["rev-parse", "--verify", "--end-of-options", "refs/heads/\(branch)"], timeout: readTimeout)
            .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try run(in: toplevel, ["rev-parse", "HEAD"], timeout: readTimeout).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = (try? runAllowingFailure(in: toplevel, ["merge-base", "--is-ancestor", commit, head], timeout: readTimeout))?.status == 0
        let registry = try registeredWorktrees(of: GitRepositoryIdentity(commonDirectory: identity.commonDirectory, toplevel: toplevel))
        let checkedOut = registry.first { $0.branch == "refs/heads/\(branch)" }
        return BranchDeletionPreview(branch: branch, commit: commit, mergedIntoPrimaryHead: merged, checkedOutAt: checkedOut?.path,
            heldByStaleEntry: checkedOut?.isPrunable ?? false)
    }

    /// One `git branch -d`, from the primary checkout. Git refuses an unmerged
    /// or checked-out branch and its message is what the person sees; the
    /// upper-case form never appears in Parley's argv.
    public func deleteBranch(_ branch: String, in repositoryFolder: String) throws -> BranchDeletionOutcome {
        let preview = try branchDeletionPreview(branch, in: repositoryFolder)
        let identity = try identity(of: repositoryFolder)
        let toplevel = primaryToplevel(identity) ?? identity.toplevel
        let result = try runObserving(in: toplevel, ["branch", "-d", "--end-of-options", branch], timeout: mutationTimeout)
        guard result.status == 0 else {
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .refused(text.isEmpty ? "git branch -d reported exit status \(result.status)" : text)
        }
        return .deleted(commit: preview.commit)
    }

    // MARK: Facts

    public func facts(for record: ManagedWorktreeRecord) -> ManagedWorktreeFacts {
        facts(forTreeAt: record.path, id: record.id, expectedCommonDirectory: record.commonDirectory)
    }

    /// The same read for a tree known only from Git's registry: identified by
    /// its path, with no record whose common directory it must match.
    public func facts(forTreeAt path: String, id: String, expectedCommonDirectory: String?) -> ManagedWorktreeFacts {
        func unknown(_ registered: Bool?) -> ManagedWorktreeFacts {
            ManagedWorktreeFacts(recordID: id, currentBranch: nil, head: nil, changedPathCount: nil, upstreamAheadCount: nil, hasUpstream: nil, registered: registered)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return unknown(false) }
        // A failed read is unknown; only Git's own listing may say "absent".
        guard let identity = try? identity(of: path), expectedCommonDirectory == nil || identity.commonDirectory == expectedCommonDirectory,
              let registry = try? registeredWorktrees(of: identity) else { return unknown(nil) }
        guard registry.contains(where: { $0.path == path }) else { return unknown(false) }
        let branch = (try? run(in: path, ["rev-parse", "--abbrev-ref", "HEAD"], timeout: readTimeout))?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = (try? run(in: path, ["rev-parse", "HEAD"], timeout: readTimeout))?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try? statusEntries(in: path)
        let upstream = upstreamState(in: path)
        let divergence = divergenceFromPrimary(identity: identity, treePath: path, head: head)
        return ManagedWorktreeFacts(recordID: id, currentBranch: branch, head: head,
            changedPathCount: status.map { $0.modified.count + $0.untracked.count }, upstreamAheadCount: upstream.ahead,
            hasUpstream: upstream.hasUpstream, registered: true, primaryHead: divergence.primaryHead,
            aheadOfPrimary: divergence.ahead, behindPrimary: divergence.behind, containedInPrimary: divergence.contained)
    }

    /// Where this tree stands against the primary checkout (the registry's
    /// first entry): one `rev-list --left-right --count` for the two counts
    /// and one `merge-base --is-ancestor` for containment. Every value Git
    /// did not answer stays nil; a failed read is never "0 ahead".
    struct PrimaryDivergence: Equatable {
        let primaryHead: String?
        let ahead: Int?
        let behind: Int?
        let contained: Bool?
        static let unknown = PrimaryDivergence(primaryHead: nil, ahead: nil, behind: nil, contained: nil)
    }

    private func divergenceFromPrimary(identity: GitRepositoryIdentity, treePath: String, head: String?) -> PrimaryDivergence {
        guard let primary = primaryToplevel(identity), primary != treePath, let head, !head.isEmpty,
              let primaryHead = (try? run(in: primary, ["rev-parse", "HEAD"], timeout: readTimeout))?
                  .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines),
              !primaryHead.isEmpty else { return .unknown }
        var ahead: Int?
        var behind: Int?
        if let counts = try? run(in: treePath, ["rev-list", "--left-right", "--count", "\(primaryHead)...\(head)"], timeout: readTimeout) {
            let parts = counts.stdoutText.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
            if parts.count == 2 {
                behind = parts[0]
                ahead = parts[1]
            }
        }
        var contained: Bool?
        if let ancestor = try? runAllowingFailure(in: treePath, ["merge-base", "--is-ancestor", head, primaryHead], timeout: readTimeout) {
            switch ancestor.status {
            case 0: contained = true
            case 1: contained = false
            default: contained = nil
            }
        }
        return PrimaryDivergence(primaryHead: primaryHead, ahead: ahead, behind: behind, contained: contained)
    }

    // MARK: Cleanup

    public func cleanupPreview(_ record: ManagedWorktreeRecord, livePaneFolders: [String], otherRuntimeStateFiles: [URL]) throws -> WorktreeCleanupPreview {
        let facts = try cleanupFacts(record, livePaneFolders: livePaneFolders, otherRuntimeStateFiles: otherRuntimeStateFiles)
        return WorktreeCleanupPreview(record: record, facts: facts, decision: WorktreeCleanupPolicy.decision(for: facts), ignoredPaths: facts.ignoredPaths)
    }

    /// Re-reads every fact immediately before mutating, requires the ignored
    /// list the person acknowledged to match exactly, then runs one plain
    /// `git worktree remove` with no `--force` and reports what is observed
    /// afterwards. The branch is never deleted. A tree that is already gone
    /// clears only Parley's record and runs no Git command.
    public func remove(_ record: ManagedWorktreeRecord, acknowledgedIgnoredPaths: [String], livePaneFolders: [String],
                       otherRuntimeStateFiles: [URL]) throws -> WorktreeRemovalOutcome {
        let facts = try cleanupFacts(record, livePaneFolders: livePaneFolders, otherRuntimeStateFiles: otherRuntimeStateFiles)
        switch WorktreeCleanupPolicy.decision(for: facts) {
        case let .refuse(reasons):
            throw ManagedWorktreeError.refused(reasons)
        case .clearRecordOnly:
            do {
                try store.remove(id: record.id)
                return WorktreeRemovalOutcome(path: record.path, state: .removed, recordRemoved: true, recordError: nil,
                    detail: "The worktree folder was already absent" + (facts.registered ? " (Git still lists it as prunable; run git worktree prune yourself if you want that entry gone)" : " and Git no longer lists it")
                        + "; Parley's record was cleared and no Git command ran. The branch \(record.branch) was not touched.")
            } catch {
                return WorktreeRemovalOutcome(path: record.path, state: .removed, recordRemoved: false, recordError: error.localizedDescription,
                    detail: "The worktree folder was already absent; no Git command ran, but Parley's record could not be cleared.")
            }
        case .removeTree:
            break
        }
        if Set(facts.ignoredPaths) != Set(acknowledgedIgnoredPaths) {
            throw ManagedWorktreeError.refused([facts.ignoredPaths.isEmpty
                ? "the acknowledged ignored files no longer match the tree"
                : "ignored files would be deleted with the tree and were not all acknowledged: " + facts.ignoredPaths.prefix(8).joined(separator: ", ")])
        }
        // Run the removal from a folder that survives it: the primary worktree
        // of the same common directory, captured before anything changes.
        guard let identity = try? identity(of: record.path), identity.commonDirectory == record.commonDirectory,
              let survivingFolder = primaryToplevel(identity), survivingFolder != record.path,
              FileManager.default.fileExists(atPath: survivingFolder) else {
            throw ManagedWorktreeError.refused(["the primary worktree of the recorded repository could not be found"])
        }
        let survivingIdentity = GitRepositoryIdentity(commonDirectory: identity.commonDirectory, toplevel: survivingFolder)
        // `git worktree remove` checks the tree with its own `git status`,
        // which would run the repository's clean filters. It needs to start
        // that child, so it cannot run inside the read guard; the filter
        // drivers configured now are turned off for it instead.
        let removal = try runObserving(in: survivingFolder, ["worktree", "remove", "--end-of-options", record.path], timeout: mutationTimeout,
                                       environment: filterFreeEnvironment(in: record.path, base: environment))
        let gitDetail = removal.status == 0 ? "Git returned success"
            : removal.status == 124 ? "git worktree remove timed out after \(Int(mutationTimeout)) seconds"
            : "git worktree remove reported exit status \(removal.status)" + (removal.stderrText.isEmpty ? "" : ": " + removal.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        // Whatever the status said, only the registry and the filesystem decide.
        let item = Self.itemState(at: record.path)
        let folderDescription: String = {
            switch item {
            case .absent: "the folder is gone"
            case .present: "the folder still exists"
            case .unknown: "the folder's state could not be read"
            }
        }()
        guard let registry = try? registeredWorktrees(of: survivingIdentity) else {
            return WorktreeRemovalOutcome(path: record.path, state: .uncertain, recordRemoved: false, recordError: nil,
                detail: "\(gitDetail), and Git's worktree list could not be read afterwards; \(folderDescription). Nothing was recorded; inspect the repository by hand.")
        }
        let stillListed = registry.first { $0.path == record.path }
        guard item != .unknown else {
            return WorktreeRemovalOutcome(path: record.path, state: .uncertain, recordRemoved: false, recordError: nil,
                detail: "\(gitDetail); \(folderDescription) (permission or I/O error) and Git \(stillListed == nil ? "no longer lists" : "still lists") the worktree. Nothing was recorded; inspect \(record.path) by hand.")
        }
        let folderExists = item != .absent
        switch (stillListed, folderExists) {
        case (let entry?, true) where !entry.isPrunable:
            return WorktreeRemovalOutcome(path: record.path, state: .retained, recordRemoved: false, recordError: nil,
                detail: "\(gitDetail); Git still lists the worktree and the folder remains, so the record was kept. "
                    + (removal.status == 0 ? "Inspect the folder before trusting it." : "Git may have deleted some files before stopping, so a partial removal is possible; inspect the folder before relying on it."))
        case (nil, false), (.some, false):
            var recordError: String?
            do { try store.remove(id: record.id) } catch { recordError = error.localizedDescription }
            let registration = stillListed == nil ? "" : " Git still lists a prunable entry for it; run git worktree prune yourself if you want that gone."
            return WorktreeRemovalOutcome(path: record.path, state: .removed, recordRemoved: recordError == nil, recordError: recordError,
                detail: "\(gitDetail); the folder is gone and the worktree is \(stillListed == nil ? "no longer listed" : "no longer present").\(registration) The branch \(record.branch) was kept."
                    + (recordError.map { " Parley's record could not be cleared: \($0)" } ?? ""))
        default:
            let listing = stillListed.map { "lists it" + ($0.isPrunable ? " as prunable" : "") } ?? "no longer lists it"
            return WorktreeRemovalOutcome(path: record.path, state: .uncertain, recordRemoved: false, recordError: nil,
                detail: "\(gitDetail); Git's registry and the folder disagree: Git \(listing) while \(folderDescription). Nothing was recorded; inspect \(record.path) by hand.")
        }
    }

    private func cleanupFacts(_ record: ManagedWorktreeRecord, livePaneFolders: [String], otherRuntimeStateFiles: [URL]) throws -> WorktreeCleanupFacts {
        var registered: RegisteredWorktree?
        var registryReadable = false
        var primaryHead: String?
        var nested: [String] = []
        let item = Self.itemState(at: record.path)
        let pathInspectable = item != .unknown
        let pathExists: Bool = { if case .present = item { return true } else { return false } }()
        let pathIsDirectory = item == .present(isDirectory: true)
        // The registry is read through the surviving primary tree so an absent
        // linked folder still answers; identity from inside the tree is a
        // cross-check, not the only route.
        let identity = (try? identity(of: record.path)).flatMap { $0.commonDirectory == record.commonDirectory ? $0 : nil }
            ?? GitRepositoryIdentity(commonDirectory: record.commonDirectory, toplevel: record.commonDirectory)
        if let list = try? registeredWorktrees(of: GitRepositoryIdentity(commonDirectory: identity.commonDirectory, toplevel: primaryToplevel(identity) ?? identity.toplevel)) {
            registryReadable = true
            registered = list.first { $0.path == record.path }
            primaryHead = list.first(where: \.isPrimary)?.head
            nested = list.filter { $0.path != record.path && WorktreeCleanupPolicy.isNested($0.path, in: record.path) }.map(\.path)
        }
        var recordInventoryReadable = false
        var recordPresent = false
        var recordUnchanged = false
        if let known = try? store.records() {
            recordInventoryReadable = true
            if let stored = known.first(where: { $0.id == record.id }) {
                recordPresent = true
                recordUnchanged = stored == record
            }
            for other in known where other.id != record.id && other.path != record.path && WorktreeCleanupPolicy.isNested(other.path, in: record.path) && !nested.contains(other.path) {
                nested.append(other.path)
            }
        }
        var other: [String] = []
        var otherUnreadable = false
        for file in otherRuntimeStateFiles {
            if Self.itemState(at: file.path) == .absent { continue }
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let panes = object["panes"] as? [[String: Any]] else { otherUnreadable = true; continue }
            // Keep one relevant folder per pane so usage counts stay accurate,
            // while either its reviewed root or its reported cwd blocks removal.
            let folders = panes.compactMap { pane -> String? in
                guard let cwd = pane["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
                guard pane["kind"] as? String != PaneKind.shell.rawValue,
                      pane["launchFolder"] != nil else { return cwd }
                guard let launch = pane["launchFolder"] as? String, launch.hasPrefix("/") else { return nil }
                return WorktreeCleanupPolicy.isNested(launch, in: record.path) ? launch : cwd
            }
            guard folders.count == panes.count else {
                otherUnreadable = true; continue
            }
            other += folders
        }
        var modified: [String] = [], untracked: [String] = [], ignored: [String] = []
        var truncated = false
        var uncertain = false
        if registered != nil, !(registered?.isPrunable ?? true), pathIsDirectory {
            if let status = try? statusEntries(in: record.path) {
                modified = status.modified; untracked = status.untracked
                truncated = status.ignored.count > WorktreeCleanupPolicy.maximumReviewedIgnoredPaths
                ignored = Array(status.ignored.prefix(WorktreeCleanupPolicy.maximumReviewedIgnoredPaths))
                // Git collapses an ignored directory into one !! entry. A
                // nested independent repository inside it is not disposable
                // merely because the person acknowledged that outer entry.
                if !truncated {
                    let directories = status.ignored.filter { $0.hasSuffix("/") }
                        .map { URL(fileURLWithPath: record.path).appendingPathComponent($0) }
                    nested += try nestedRepositories(in: directories)
                }
            } else { uncertain = true }
        }
        let upstream: UpstreamState = registered == nil || !pathIsDirectory ? UpstreamState(hasUpstream: nil, ahead: nil) : upstreamState(in: record.path)
        let merged: Bool = {
            guard let primaryHead, registered != nil, pathIsDirectory else { return false }
            return (try? run(in: record.path, ["merge-base", "--is-ancestor", "HEAD", primaryHead], timeout: readTimeout)) != nil
        }()
        let tokenVerified = registered != nil && pathIsDirectory && creationTokenMatches(record)
        return WorktreeCleanupFacts(parleyCreated: record.parleyCreated, creationTokenVerified: tokenVerified, registered: registered != nil,
            registryReadable: registryReadable, pathInspectable: pathInspectable, pathExists: pathExists, pathIsDirectory: pathIsDirectory,
            recordInventoryReadable: recordInventoryReadable,
            recordPresentInInventory: recordPresent, recordUnchangedInInventory: recordUnchanged, locked: registered?.isLocked ?? false, prunable: registered?.isPrunable ?? true,
            nestedWorktreePaths: Set(nested.map(GitWorktreeResolver.canonicalPath)).sorted(),
            livePaneFolders: livePaneFolders, otherRuntimePaneFolders: other, otherRuntimeStateUnreadable: otherUnreadable, modifiedPaths: modified,
            untrackedPaths: untracked, ignoredPaths: ignored, ignoredListTruncated: truncated, upstreamAheadCount: upstream.ahead ?? 0,
            hasUpstream: upstream.hasUpstream ?? false, mergedIntoPrimary: merged,
            statusUncertain: uncertain || upstream.hasUpstream == nil || (upstream.hasUpstream == true && upstream.ahead == nil), path: record.path,
            isPrimary: registered?.isPrimary ?? false)
    }

    // MARK: Helpers

    private func nestedRepositories(in directories: [URL]) throws -> [String] {
        var pending = directories
        var repositories: [String] = []
        var inspected = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(readTimeout * 1_000_000_000)
        while let folder = pending.popLast() {
            guard inspected < 20_000, DispatchTime.now().uptimeNanoseconds < deadline else {
                throw ManagedWorktreeError.refused(["the ignored directory is too large to check for nested repositories; inspect or move it before removal"])
            }
            var folderInfo = stat()
            guard lstat(folder.path, &folderInfo) == 0, folderInfo.st_mode & S_IFMT == S_IFDIR else {
                throw ManagedWorktreeError.refused(["an ignored directory changed or could not be inspected for nested repositories"])
            }
            let entries: [URL]
            do { entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
            catch {
                throw ManagedWorktreeError.refused(["an ignored directory could not be read to check for nested repositories"])
            }
            if entries.contains(where: { $0.lastPathComponent == ".git" }) {
                repositories.append(folder.path)
                continue
            }
            // A bare repository has no .git entry.
            let names = Set(entries.map(\.lastPathComponent))
            if names.contains("HEAD"), names.contains("objects"), names.contains("refs") {
                repositories.append(folder.path)
                continue
            }
            for entry in entries {
                inspected += 1
                guard inspected <= 20_000, DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw ManagedWorktreeError.refused(["the ignored directory is too large to check for nested repositories; inspect or move it before removal"])
                }
                var info = stat()
                guard lstat(entry.path, &info) == 0 else {
                    throw ManagedWorktreeError.refused(["an ignored path could not be inspected for nested repositories"])
                }
                if info.st_mode & S_IFMT == S_IFDIR { pending.append(entry) }
            }
        }
        return repositories
    }

    private func primaryToplevel(_ identity: GitRepositoryIdentity) -> String? {
        (try? registeredWorktrees(of: identity))?.first(where: \.isPrimary)?.path
    }

    private func prepareWorktreesDirectory(_ directory: String, toplevel: String) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: directory) {
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw ManagedWorktreeError.invalid("\(directory) is a symbolic link; Parley only uses a real .worktrees directory inside the repository.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ManagedWorktreeError.invalid("\(directory) exists and is not a directory.")
            }
        } else {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        }
        guard GitWorktreeResolver.canonicalPath(directory) == GitWorktreeResolver.canonicalPath(toplevel) + "/" + Self.worktreesDirectoryName else {
            throw ManagedWorktreeError.invalid("\(directory) does not resolve inside the repository.")
        }
    }

    /// Adds `.worktrees/` to the repository's local exclude file once. Tracked
    /// ignore rules and every other local exclude line are left untouched.
    private func ensureLocalExclude(commonDirectory: String) throws {
        let info = URL(fileURLWithPath: commonDirectory).appendingPathComponent("info", isDirectory: true)
        let exclude = info.appendingPathComponent("exclude")
        var existing = ""
        if FileManager.default.fileExists(atPath: exclude.path) {
            existing = try String(contentsOf: exclude, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        }
        let lines = existing.components(separatedBy: "\n")
        guard !lines.contains(where: { $0 == Self.excludeEntry || $0 == Self.worktreesDirectoryName }) else { return }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += Self.excludeEntry + "\n"
        try updated.write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// A filter-free status: every configured filter driver is turned off, so
    /// a file under one is compared as raw bytes and may read as modified,
    /// which only ever makes cleanup more cautious.
    private func statusEntries(in folder: String) throws -> (modified: [String], untracked: [String], ignored: [String]) {
        let output = try run(in: folder, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"] + GitReadBoundary.statusArguments,
                             timeout: readTimeout, environment: filterFreeEnvironment(in: folder, base: readEnvironment))
        let tokens = output.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var modified: [String] = [], untracked: [String] = [], ignored: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.count >= 4 else { continue }
            let code = String(token.prefix(2))
            let path = String(token.dropFirst(3))
            if code.hasPrefix("R") || code.hasPrefix("C") { index += 1 } // rename/copy carries the origin path next
            switch code {
            case "!!": ignored.append(path)
            case "??": untracked.append(path)
            default: modified.append(path)
            }
        }
        return (modified, untracked, ignored)
    }

    /// `hasUpstream == nil` means Git could not answer; that is never treated
    /// as "no upstream". `ahead == nil` with an upstream means the count failed.
    struct UpstreamState: Equatable { let hasUpstream: Bool?; let ahead: Int? }

    private func upstreamState(in folder: String) -> UpstreamState {
        guard let branchLookup = try? runAllowingFailure(in: folder, ["symbolic-ref", "--quiet", "--short", "HEAD"], timeout: readTimeout) else {
            return UpstreamState(hasUpstream: nil, ahead: nil)
        }
        if branchLookup.status == 1 { return UpstreamState(hasUpstream: false, ahead: nil) } // detached HEAD: no upstream by definition
        guard branchLookup.status == 0 else { return UpstreamState(hasUpstream: nil, ahead: nil) }
        let branch = branchLookup.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The configured upstream is read from config, so a tracking branch whose
        // remote or remote-tracking ref is missing counts as configured-but-unknown.
        guard !branch.isEmpty, let configured = try? runAllowingFailure(in: folder, ["config", "--get", "branch.\(branch).merge"], timeout: readTimeout) else {
            return UpstreamState(hasUpstream: nil, ahead: nil)
        }
        switch configured.status {
        case 1: return UpstreamState(hasUpstream: false, ahead: nil)
        case 0: break
        default: return UpstreamState(hasUpstream: nil, ahead: nil)
        }
        guard let count = (try? run(in: folder, ["rev-list", "--count", "--end-of-options", "@{upstream}..HEAD"], timeout: readTimeout))?
            .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), let ahead = Int(count) else {
            return UpstreamState(hasUpstream: true, ahead: nil)
        }
        return UpstreamState(hasUpstream: true, ahead: ahead)
    }

    /// For mutations: returns whatever happened, including status 124 for a
    /// timeout, so the caller reconciles against Git's registry instead of
    /// skipping the partial-result handling. Throws only if the process could
    /// not start.
    private func runObserving(in folder: String, _ arguments: [String], timeout: TimeInterval,
                              environment mutationEnvironment: [String: String]? = nil) throws -> CommandOutput {
        do {
            return try ProcessCommandRunner(timeout: timeout).run(executable: gitExecutable,
                arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments, environment: mutationEnvironment ?? environment, input: nil)
        } catch {
            throw ManagedWorktreeError.git("git \(arguments.first ?? "") did not start: \(error.localizedDescription)")
        }
    }

    /// `base` with every filter driver configured for `folder` turned off,
    /// listed by a guarded read. Both environments are free of inherited
    /// `GIT_*`, so the overrides are the only command-scope configuration.
    private func filterFreeEnvironment(in folder: String, base: [String: String]) -> [String: String] {
        base.merging(GitReadBoundary.filterOverrides(in: folder, git: gitExecutable, environment: readEnvironment,
                                                     runner: ProcessCommandRunner(timeout: readTimeout))) { _, override in override }
    }

    /// Returns Git's real exit status; throws only when the process could not
    /// run or timed out, so callers can tell "no" from "unknown".
    private func runAllowingFailure(in folder: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try GitReadBoundary.run(git: gitExecutable, arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments,
                environment: readEnvironment, runner: ProcessCommandRunner(timeout: timeout))
        } catch {
            throw ManagedWorktreeError.git("git \(arguments.first ?? "") did not complete: \(error.localizedDescription)")
        }
        if output.status == 124 { throw ManagedWorktreeError.git("git \(arguments.first ?? "") timed out after \(Int(timeout)) seconds") }
        return output
    }

    /// Every read goes through `GitReadBoundary`, so nothing a repository's
    /// configuration names can start from it.
    @discardableResult
    private func run(in folder: String, _ arguments: [String], timeout: TimeInterval,
                     environment overridingEnvironment: [String: String]? = nil) throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try GitReadBoundary.run(git: gitExecutable, arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments,
                environment: overridingEnvironment ?? readEnvironment, runner: ProcessCommandRunner(timeout: timeout))
        } catch {
            throw ManagedWorktreeError.git("git \(arguments.first ?? "") did not complete: \(error.localizedDescription)")
        }
        guard output.status == 0 else {
            let text = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagedWorktreeError.git("exit status \(output.status)\(text.isEmpty ? "" : ": " + text)")
        }
        return output
    }
}

extension ManagedWorktreeService {
    /// Browser-only inspection. It owns no clock and authorizes no mutation.
    public func inspectLifecycle(_ record: ManagedWorktreeRecord, panes: [WorkbenchPane], workspaces: [WorkbenchWorkspace],
                                 handoffs: [RelayHandoff], activeTeamPaths: [String], otherRuntimeStateFiles: [URL]) throws -> WorktreeLifecycleInspection {
        let cleanup = try cleanupPreview(record, livePaneFolders: panes.flatMap(\.worktreeSafetyFolders), otherRuntimeStateFiles: otherRuntimeStateFiles)
        let usage = WorktreeUsage.project(path: record.path, panes: panes, workspaces: workspaces, handoffs: handoffs,
            otherPaneFolders: cleanup.facts.otherRuntimePaneFolders, otherRuntimeUnknown: cleanup.facts.otherRuntimeStateUnreadable,
            activeTeamPaths: activeTeamPaths)
        var paths: [String] = [], error: String?
        do { paths = try recoveryCandidates(record) } catch let failure { error = failure.localizedDescription }
        return WorktreeLifecycleInspection(cleanup: cleanup, usage: usage, recoveryPaths: paths, recoveryError: error, capturedAt: Date())
    }

    /// A same-branch directory is not evidence of a move. Match the original
    /// opaque marker within the same repository, and refuse ambiguous matches.
    public func recoveryCandidates(_ record: ManagedWorktreeRecord) throws -> [String] {
        guard record.parleyCreated, record.creationToken != nil else { return [] }
        let identity = GitRepositoryIdentity(commonDirectory: record.commonDirectory, toplevel: record.commonDirectory)
        return try registeredWorktrees(of: identity).filter { item in
            guard item.path != record.path, !item.isPrunable, !item.isPrimary,
                  let found = try? self.identity(of: item.path), found.commonDirectory == record.commonDirectory else { return false }
            return creationTokenMatches(relocated(record, to: item.path))
        }.map(\.path).sorted()
    }

    private func relocated(_ record: ManagedWorktreeRecord, to path: String) -> ManagedWorktreeRecord {
        ManagedWorktreeRecord(id: record.id, commonDirectory: record.commonDirectory, path: path, branch: record.branch,
            baseRef: record.baseRef, baseCommit: record.baseCommit, createdAt: record.createdAt, parleyCreated: record.parleyCreated,
            creationToken: record.creationToken, teamSessionID: record.teamSessionID, requestedByPaneID: record.requestedByPaneID,
            warning: record.warning)
    }

    public func relocateRecord(_ record: ManagedWorktreeRecord, to path: String) throws -> ManagedWorktreeRecord {
        guard Self.itemState(at: record.path) == .absent else {
            throw ManagedWorktreeError.invalid("The old path still exists or cannot be inspected. Inspect it before updating this record.")
        }
        let canonical = GitWorktreeResolver.canonicalPath(path)
        let candidates = try recoveryCandidates(record)
        guard candidates.count == 1, candidates.first == canonical else {
            throw ManagedWorktreeError.invalid("The original marker no longer identifies exactly this destination. Refresh and inspect Git's worktree list.")
        }
        let updated = relocated(record, to: canonical)
        try store.replace(record, with: updated)
        return updated
    }

    /// Uses a private bare repository with read-only access to existing objects.
    /// Its empty config/templates prevent project hooks, filters or merge drivers
    /// from executing. Only immutable resolved commits enter merge-tree's argv.
    public func mergePreview(_ record: ManagedWorktreeRecord, targetRef: String) throws -> WorktreeMergePreview {
        try WorktreeNaming.validateRef(targetRef)
        let identity = try identity(of: record.path)
        guard identity.commonDirectory == record.commonDirectory,
              try registeredWorktrees(of: identity).contains(where: { $0.path == record.path && !$0.isPrunable }) else {
            throw ManagedWorktreeError.invalid("The worktree identity changed. Refresh before previewing a merge.")
        }
        return try performMergePreview(path: record.path, commonDirectory: record.commonDirectory, targetRef: targetRef)
    }

    /// A prediction needs repository identity, never an ownership record.
    public func mergePreview(path: String, repositoryFolder: String, targetRef: String) throws -> WorktreeMergePreview {
        try WorktreeNaming.validateRef(targetRef)
        let identity = try identity(of: repositoryFolder)
        let path = GitWorktreeResolver.canonicalPath(path)
        guard try self.identity(of: path).commonDirectory == identity.commonDirectory,
              try registeredWorktrees(of: identity).contains(where: { $0.path == path && !$0.isPrunable }) else {
            throw ManagedWorktreeError.invalid("The worktree identity changed. Refresh before previewing a merge.")
        }
        return try performMergePreview(path: path, commonDirectory: identity.commonDirectory, targetRef: targetRef)
    }

    private func performMergePreview(path: String, commonDirectory: String, targetRef: String) throws -> WorktreeMergePreview {
        let source = try resolveCommit("HEAD", in: path)
        let target = try resolveCommit(targetRef, in: path)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("parley-merge-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Inside `GitReadBoundary` like every other read, although this
        // scratch repository reads neither the project's configuration nor
        // its attributes: the guard holds even if that ever changes.
        var env = readEnvironment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_NO_LAZY_FETCH"] = "1"
        // C-quoted environment entry protects colons, newlines and backslashes.
        let objects = commonDirectory + "/objects"
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = "\"" + objects.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
        let runner = ProcessCommandRunner(timeout: 15, maximumCapturedBytes: 200_001)
        let initialized = try GitReadBoundary.run(git: gitExecutable,
            arguments: ["-C", scratch.path, "init", "--bare", "--template=", "--quiet"], environment: env, runner: runner)
        guard initialized.status == 0 else { throw ManagedWorktreeError.git("Could not initialize temporary merge storage.") }
        let output = try GitReadBoundary.run(git: gitExecutable,
            arguments: ["-C", scratch.path, "-c", "core.attributesFile=/dev/null", "-c", "core.fsmonitor=false",
                        "merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", target, source], environment: env, runner: runner)
        guard output.status == 0 || output.status == 1 else {
            throw ManagedWorktreeError.git("Merge preview unavailable (exit \(output.status)). Git may lack merge-tree support, objects may be missing or the branches may have no common history. " + String(output.stderrText.prefix(1000)))
        }
        guard output.stdout.count <= 200_000, output.stdout.last == 0 else {
            throw ManagedWorktreeError.git("Merge preview output was incomplete or exceeded the display bound.")
        }
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let tree = fields.first, tree.count == 40, tree.allSatisfy(\.isHexDigit) else {
            throw ManagedWorktreeError.git("Git returned an unrecognized merge preview.")
        }
        let paths = Array(fields.dropFirst().prefix(while: { !$0.isEmpty }))
        guard paths.count <= 200 else { throw ManagedWorktreeError.git("More than 200 conflicting paths; inspect this merge with Git.") }
        return WorktreeMergePreview(sourceCommit: source, targetCommit: target, targetRef: targetRef,
            hasConflicts: output.status == 1, conflictedPaths: paths, capturedAt: Date())
    }
}
