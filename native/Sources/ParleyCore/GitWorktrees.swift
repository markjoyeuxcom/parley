import Foundation

/// One entry from Git's stable `worktree list --porcelain` format. Paths are
/// canonicalised by the resolver before they reach the app; parsing remains a
/// pure operation so the wire format can be checked deterministically.
public struct GitWorktreeRecord: Identifiable, Equatable, Sendable {
    public let path: String
    public let head: String
    public let branch: String?
    public let isDetached: Bool
    public let lockReason: String?
    public let pruneReason: String?
    public let isPrimary: Bool

    public init(
        path: String,
        head: String,
        branch: String?,
        isDetached: Bool,
        lockReason: String?,
        pruneReason: String?,
        isPrimary: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.lockReason = lockReason
        self.pruneReason = pruneReason
        self.isPrimary = isPrimary
    }

    public var id: String { path }
    public var shortIdentity: String {
        if let branch, !branch.isEmpty { return branch }
        guard !head.isEmpty else { return "detached" }
        return "@" + head.prefix(8)
    }
    public var locationKind: String { isPrimary ? "Primary worktree" : "Linked worktree" }
}

public struct GitWorktreeRepository: Identifiable, Equatable, Sendable {
    public let primaryPath: String
    public let worktrees: [GitWorktreeRecord]

    public init(primaryPath: String, worktrees: [GitWorktreeRecord]) {
        self.primaryPath = primaryPath
        self.worktrees = worktrees
    }

    public var id: String { primaryPath }
    public var name: String {
        let component = URL(fileURLWithPath: primaryPath).lastPathComponent
        return component.isEmpty ? primaryPath : component
    }
}

public struct GitWorktreeScan: Equatable, Sendable {
    public let repositories: [GitWorktreeRepository]
    /// Pane id to the exact canonical top-level worktree containing its cwd.
    public let paneWorktreePaths: [String: String]

    public init(repositories: [GitWorktreeRepository], paneWorktreePaths: [String: String]) {
        self.repositories = repositories
        self.paneWorktreePaths = paneWorktreePaths
    }

    public static let empty = GitWorktreeScan(repositories: [], paneWorktreePaths: [:])

    public var worktrees: [GitWorktreeRecord] {
        var byPath: [String: GitWorktreeRecord] = [:]
        for worktree in repositories.flatMap(\.worktrees) { byPath[worktree.path] = worktree }
        return byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Read-only Git worktree discovery. Both calls are direct argv executions,
/// suppress locks and pagers, and have fixed timeouts. Parley never creates,
/// prunes, moves or removes a worktree through this surface.
public struct GitWorktreeResolver: Sendable {
    private let gitExecutable: URL
    private let environment: [String: String]
    private let timeout: TimeInterval

    public init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 2
    ) {
        self.gitExecutable = gitExecutable
        var gitEnvironment = environment
        gitEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        gitEnvironment["GIT_PAGER"] = "cat"
        gitEnvironment["PAGER"] = "cat"
        gitEnvironment["LC_ALL"] = "C"
        self.environment = gitEnvironment
        self.timeout = max(0.1, timeout)
    }

    public func scan(paneFolders: [String: String]) -> GitWorktreeScan {
        var repositories: [String: GitWorktreeRepository] = [:]
        var paneWorktreePaths: [String: String] = [:]
        var paneIDsByFolder: [String: [String]] = [:]

        for (paneID, folder) in paneFolders {
            paneIDsByFolder[Self.canonicalPath(folder), default: []].append(paneID)
        }

        var currentRoots: Set<String> = []
        for (folder, paneIDs) in paneIDsByFolder.sorted(by: { $0.key < $1.key }) {
            guard let root = topLevel(in: folder) else { continue }
            currentRoots.insert(root)
            for paneID in paneIDs { paneWorktreePaths[paneID] = root }
        }

        for root in currentRoots.sorted() {
            guard let repository = repository(atRoot: root) else { continue }
            repositories[repository.primaryPath] = repository
        }

        return GitWorktreeScan(
            repositories: repositories.values.sorted {
                $0.primaryPath.localizedStandardCompare($1.primaryPath) == .orderedAscending
            },
            paneWorktreePaths: paneWorktreePaths
        )
    }

    public func repository(in folder: String) -> (repository: GitWorktreeRepository, currentWorktreePath: String)? {
        guard let currentWorktreePath = topLevel(in: folder),
              let repository = repository(atRoot: currentWorktreePath) else { return nil }
        return (repository, currentWorktreePath)
    }

    private func topLevel(in folder: String) -> String? {
        let standardized = Self.canonicalPath(folder)
        guard let root = runGit(
            in: standardized,
            arguments: ["rev-parse", "--path-format=absolute", "--show-toplevel"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !root.isEmpty else { return nil }
        return Self.canonicalPath(root)
    }

    private func repository(atRoot currentWorktreePath: String) -> GitWorktreeRepository? {
        guard let porcelain = runGit(
            in: currentWorktreePath,
            arguments: ["worktree", "list", "--porcelain", "-z"]
        ) else { return nil }

        let parsed = Self.parsePorcelain(porcelain).map { record in
            GitWorktreeRecord(
                path: Self.canonicalPath(record.path),
                head: record.head,
                branch: record.branch,
                isDetached: record.isDetached,
                lockReason: record.lockReason,
                pruneReason: record.pruneReason,
                isPrimary: record.isPrimary
            )
        }
        guard let primary = parsed.first else { return nil }
        return GitWorktreeRepository(primaryPath: primary.path, worktrees: parsed)
    }

    private func runGit(in folder: String, arguments: [String]) -> String? {
        let output: CommandOutput
        do {
            output = try ProcessCommandRunner(timeout: timeout).run(
                executable: gitExecutable,
                arguments: ["-C", folder, "-c", "core.fsmonitor=false"] + arguments,
                environment: environment,
                input: nil
            )
        } catch {
            return nil
        }
        guard output.status == 0 else { return nil }
        return output.stdoutText
    }

    public static func parsePorcelain(_ text: String) -> [GitWorktreeRecord] {
        struct Draft {
            var path = ""
            var head = ""
            var branch: String?
            var detached = false
            var lockReason: String?
            var pruneReason: String?
        }

        var records: [GitWorktreeRecord] = []
        var draft: Draft?

        func finish(_ value: Draft?) -> GitWorktreeRecord? {
            guard let value, !value.path.isEmpty else { return nil }
            return GitWorktreeRecord(
                path: value.path,
                head: value.head,
                branch: value.branch,
                isDetached: value.detached,
                lockReason: value.lockReason,
                pruneReason: value.pruneReason,
                isPrimary: records.isEmpty
            )
        }

        let normalized = text.replacingOccurrences(of: "\0", with: "\n")
        for line in normalized.components(separatedBy: .newlines) {
            if line.isEmpty {
                if let record = finish(draft) { records.append(record) }
                draft = nil
                continue
            }
            if line.hasPrefix("worktree ") {
                if let record = finish(draft) { records.append(record) }
                draft = Draft(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                draft?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                draft?.branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if line == "detached" {
                draft?.detached = true
            } else if line == "locked" {
                draft?.lockReason = ""
            } else if line.hasPrefix("locked ") {
                draft?.lockReason = String(line.dropFirst("locked ".count))
            } else if line == "prunable" {
                draft?.pruneReason = ""
            } else if line.hasPrefix("prunable ") {
                draft?.pruneReason = String(line.dropFirst("prunable ".count))
            }
        }
        if let record = finish(draft) { records.append(record) }
        return records
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct WorktreeWriter: Identifiable, Equatable, Sendable {
    public let paneID: String
    public let paneName: String
    public let paneKind: PaneKind
    public let workspaceID: String
    public let permissionProfileName: String
    public let enforcement: PermissionEnforcementLevel?

    public var id: String { paneID }
}

public struct WorktreeWriterCollision: Identifiable, Equatable, Sendable {
    public let worktree: GitWorktreeRecord
    public let writers: [WorktreeWriter]

    public var id: String { worktree.path }
}

/// A warning projection only: it uses configured, visible permission state and
/// exact resolver-produced paths. It intentionally makes no claim that any
/// pane has touched a file or that an idle-looking terminal is safe.
public enum WorktreeWriterCollisionProjection {
    public static func collisions(
        panes: [WorkbenchPane],
        profiles: [PermissionProfileDefinition],
        worktrees: [GitWorktreeRecord],
        paneWorktreePaths: [String: String]
    ) -> [WorktreeWriterCollision] {
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let worktreeByPath = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.path, $0) })
        var writersByPath: [String: [WorktreeWriter]] = [:]

        for pane in panes where pane.kind.isAgent && pane.isStarted && !pane.isDead {
            guard let selection = pane.permissionSelection,
                  let profile = profileByID[selection.profileID],
                  profile.rule(for: .projectWrite) == .allow,
                  let path = paneWorktreePaths[pane.id],
                  worktreeByPath[path] != nil else { continue }
            writersByPath[path, default: []].append(WorktreeWriter(
                paneID: pane.id,
                paneName: pane.displayName,
                paneKind: pane.kind,
                workspaceID: pane.workspaceID,
                permissionProfileName: profile.name,
                enforcement: pane.permissionEnforcement
            ))
        }

        return writersByPath.compactMap { path, writers in
            guard writers.count > 1, let worktree = worktreeByPath[path] else { return nil }
            return WorktreeWriterCollision(
                worktree: worktree,
                writers: writers.sorted { $0.paneID.localizedStandardCompare($1.paneID) == .orderedAscending }
            )
        }.sorted { $0.worktree.path.localizedStandardCompare($1.worktree.path) == .orderedAscending }
    }
}
