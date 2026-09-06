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
                branch: current["branch"], isDetached: current["detached"] != nil, isPrimary: order == 0,
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

    public init(parleyCreated: Bool, creationTokenVerified: Bool, registered: Bool, registryReadable: Bool, pathInspectable: Bool, pathExists: Bool, pathIsDirectory: Bool,
                recordInventoryReadable: Bool, recordPresentInInventory: Bool, recordUnchangedInInventory: Bool, locked: Bool, prunable: Bool,
                nestedWorktreePaths: [String], livePaneFolders: [String],
                otherRuntimePaneFolders: [String], otherRuntimeStateUnreadable: Bool, modifiedPaths: [String], untrackedPaths: [String],
                ignoredPaths: [String], ignoredListTruncated: Bool, upstreamAheadCount: Int, hasUpstream: Bool, mergedIntoPrimary: Bool,
                statusUncertain: Bool, path: String) {
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
        if !facts.parleyCreated { reasons.append("this worktree was not created by Parley; open it, but never remove it here") }
        else if !facts.creationTokenVerified { reasons.append("the tree at this path no longer carries Parley's creation marker, so it may have been recreated by someone else") }
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
    private let environment: [String: String]
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
        let output = try run(in: folder, ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"], timeout: readTimeout)
        let lines = output.stdoutText.split(separator: "\n").map(String.init)
        guard lines.count == 2, lines[0].hasPrefix("/"), lines[1].hasPrefix("/") else {
            throw ManagedWorktreeError.git("could not resolve the repository for \(folder)")
        }
        return GitRepositoryIdentity(commonDirectory: GitWorktreeResolver.canonicalPath(lines[0]), toplevel: GitWorktreeResolver.canonicalPath(lines[1]))
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
        let directory = GitWorktreeResolver.canonicalPath(output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
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
        if let existing = try store.record(path: canonical), existing.parleyCreated, creationTokenMatches(existing) {
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

    // MARK: Facts

    public func facts(for record: ManagedWorktreeRecord) -> ManagedWorktreeFacts {
        func unknown(_ registered: Bool?) -> ManagedWorktreeFacts {
            ManagedWorktreeFacts(recordID: record.id, currentBranch: nil, head: nil, changedPathCount: nil, upstreamAheadCount: nil, hasUpstream: nil, registered: registered)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory), isDirectory.boolValue else { return unknown(false) }
        // A failed read is unknown; only Git's own listing may say "absent".
        guard let identity = try? identity(of: record.path), identity.commonDirectory == record.commonDirectory,
              let registry = try? registeredWorktrees(of: identity) else { return unknown(nil) }
        guard registry.contains(where: { $0.path == record.path }) else { return unknown(false) }
        let branch = (try? run(in: record.path, ["rev-parse", "--abbrev-ref", "HEAD"], timeout: readTimeout))?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = (try? run(in: record.path, ["rev-parse", "HEAD"], timeout: readTimeout))?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try? statusEntries(in: record.path)
        let upstream = upstreamState(in: record.path)
        return ManagedWorktreeFacts(recordID: record.id, currentBranch: branch, head: head,
            changedPathCount: status.map { $0.modified.count + $0.untracked.count }, upstreamAheadCount: upstream.ahead,
            hasUpstream: upstream.hasUpstream, registered: true)
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
        let removal = try runObserving(in: survivingFolder, ["worktree", "remove", "--end-of-options", record.path], timeout: mutationTimeout)
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
            primaryHead = list.first?.head
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
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let panes = object["panes"] as? [[String: Any]] else { otherUnreadable = true; continue }
            other += panes.compactMap { $0["cwd"] as? String }
        }
        var modified: [String] = [], untracked: [String] = [], ignored: [String] = []
        var truncated = false
        var uncertain = false
        if registered != nil, !(registered?.isPrunable ?? true), pathIsDirectory {
            if let status = try? statusEntries(in: record.path) {
                modified = status.modified; untracked = status.untracked
                truncated = status.ignored.count > WorktreeCleanupPolicy.maximumReviewedIgnoredPaths
                ignored = Array(status.ignored.prefix(WorktreeCleanupPolicy.maximumReviewedIgnoredPaths))
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
            recordPresentInInventory: recordPresent, recordUnchangedInInventory: recordUnchanged, locked: registered?.isLocked ?? false, prunable: registered?.isPrunable ?? true, nestedWorktreePaths: nested.sorted(),
            livePaneFolders: livePaneFolders, otherRuntimePaneFolders: other, otherRuntimeStateUnreadable: otherUnreadable, modifiedPaths: modified,
            untrackedPaths: untracked, ignoredPaths: ignored, ignoredListTruncated: truncated, upstreamAheadCount: upstream.ahead ?? 0,
            hasUpstream: upstream.hasUpstream ?? false, mergedIntoPrimary: merged,
            statusUncertain: uncertain || upstream.hasUpstream == nil || (upstream.hasUpstream == true && upstream.ahead == nil), path: record.path)
    }

    // MARK: Helpers

    private func primaryToplevel(_ identity: GitRepositoryIdentity) -> String? {
        (try? registeredWorktrees(of: identity))?.first?.path
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

    private func statusEntries(in folder: String) throws -> (modified: [String], untracked: [String], ignored: [String]) {
        let output = try run(in: folder, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"], timeout: readTimeout)
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
    private func runObserving(in folder: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        do {
            return try ProcessCommandRunner(timeout: timeout).run(executable: gitExecutable,
                arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments, environment: environment, input: nil)
        } catch {
            throw ManagedWorktreeError.git("git \(arguments.first ?? "") did not start: \(error.localizedDescription)")
        }
    }

    /// Returns Git's real exit status; throws only when the process could not
    /// run or timed out, so callers can tell "no" from "unknown".
    private func runAllowingFailure(in folder: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try ProcessCommandRunner(timeout: timeout).run(executable: gitExecutable,
                arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments, environment: environment, input: nil)
        } catch {
            throw ManagedWorktreeError.git("git \(arguments.first ?? "") did not complete: \(error.localizedDescription)")
        }
        if output.status == 124 { throw ManagedWorktreeError.git("git \(arguments.first ?? "") timed out after \(Int(timeout)) seconds") }
        return output
    }

    @discardableResult
    private func run(in folder: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try ProcessCommandRunner(timeout: timeout).run(executable: gitExecutable,
                arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments, environment: environment, input: nil)
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
