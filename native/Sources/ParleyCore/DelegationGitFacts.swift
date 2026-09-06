import Foundation

/// A bounded, informational snapshot of one working folder as Git reports it:
/// the HEAD revision, the branch or detached state, and a capped list of dirty
/// paths. Paths only; never file contents, patches, diffs, command output,
/// authorship or blame. Other panes and the person edit the same tree, so
/// nothing here says who changed anything.
/// The managed worktree containing the folder at capture time, copied from
/// Parley's own record then: path, branch, the base commit the tree was
/// created from and whether Parley created it. It is evidence recorded with
/// the handoff, never a later lookup, and never a claim about who changed a file.
public struct ManagedWorktreeEvidence: Codable, Equatable, Sendable {
    public let path: String
    public let branch: String
    public let baseCommit: String?
    public let parleyCreated: Bool

    public init(path: String, branch: String, baseCommit: String?, parleyCreated: Bool) {
        self.path = path
        self.branch = branch
        self.baseCommit = baseCommit
        self.parleyCreated = parleyCreated
    }

    public init(record: ManagedWorktreeRecord) {
        self.init(path: record.path, branch: record.branch, baseCommit: record.baseCommit, parleyCreated: record.parleyCreated)
    }

    public var summary: String {
        "worktree \(branch) · recorded base \(baseCommit.map { String($0.prefix(12)) } ?? "not recorded") · \(parleyCreated ? "created by Parley" : "person-owned")"
    }
}

public struct DelegationGitSnapshot: Codable, Equatable, Sendable {
    public static let maximumPaths = 200
    public static let label = "Shared worktree: not attribution"

    public let capturedAt: Date
    public let folder: String
    /// Full object id of HEAD; nil on an unborn branch or when unavailable.
    public let headRevision: String?
    /// Branch name; nil when detached or unavailable.
    public let branch: String?
    public let isDetached: Bool
    /// Sorted, deduplicated and capped at `maximumPaths`.
    public let dirtyPaths: [String]
    /// The true count before the cap.
    public let dirtyPathCount: Int
    /// Set when the folder exists but Git could not report; the other fields
    /// are then empty. A non-Git folder produces no snapshot at all.
    public let unavailableReason: String?
    /// Present when the folder was inside a Parley-managed worktree at
    /// capture time. Older records decode without it.
    public var managedWorktree: ManagedWorktreeEvidence? = nil

    public init(
        capturedAt: Date,
        folder: String,
        headRevision: String?,
        branch: String?,
        isDetached: Bool,
        dirtyPaths: [String],
        dirtyPathCount: Int,
        unavailableReason: String? = nil,
        managedWorktree: ManagedWorktreeEvidence? = nil
    ) {
        self.capturedAt = capturedAt
        self.folder = folder
        self.headRevision = headRevision
        self.branch = branch
        self.isDetached = isDetached
        self.dirtyPaths = dirtyPaths
        self.dirtyPathCount = dirtyPathCount
        self.unavailableReason = unavailableReason
        self.managedWorktree = managedWorktree
    }

    public var isAvailable: Bool { unavailableReason == nil }
    public var isTruncated: Bool { dirtyPathCount > dirtyPaths.count }
    public var shortRevision: String? { headRevision.map { String($0.prefix(7)) } }

    public var summary: String {
        let base = baseSummary
        return managedWorktree.map { base + " · " + $0.summary } ?? base
    }

    private var baseSummary: String {
        if let unavailableReason { return "Git facts unavailable: \(unavailableReason)" }
        let head = shortRevision.map { "HEAD \($0)" } ?? "no commits yet"
        let reference = isDetached ? "detached" : (branch ?? "no branch")
        let dirty: String = if dirtyPathCount == 0 {
            "clean"
        } else if isTruncated {
            "\(dirtyPathCount) dirty paths (\(dirtyPaths.count) listed)"
        } else {
            "\(dirtyPathCount) dirty path\(dirtyPathCount == 1 ? "" : "s")"
        }
        return "\(head) · \(reference) · \(dirty)"
    }
}

/// What changed between two available snapshots: the paths whose dirty status
/// differs, whether HEAD moved, and whether either list was truncated. It is
/// derived, never stored, and never attributes a change to anyone.
public struct DelegationGitComparison: Equatable, Sendable {
    public let changedPaths: [String]
    public let changedPathCount: Int
    public let isLowerBound: Bool
    public let headMoved: Bool
    public let folderChanged: Bool

    public var title: String {
        if isLowerBound {
            return changedPathCount == 0
                ? "Path changes since delegated are unknown (dirty list truncated)"
                : "At least \(changedPathCount) paths changed since delegated"
        }
        if changedPathCount == 0 { return "No path changes since delegated" }
        return "\(changedPathCount) path\(changedPathCount == 1 ? "" : "s") changed since delegated"
    }

    public var displayPaths: [String] { changedPaths.map(DelegationGitFacts.displayPath) }

    public var detail: String? {
        var parts: [String] = []
        if headMoved { parts.append("HEAD moved since delegated; committed paths are not listed.") }
        if isLowerBound {
            parts.append("The dirty path list was truncated at \(DelegationGitSnapshot.maximumPaths), so the count is a lower bound.")
        }
        if folderChanged { parts.append("The working folder changed between delegation and return.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public enum DelegationGitFacts {
    /// A display-only projection of one path in which every Unicode control
    /// (C0, DEL and C1), format character (zero-width, bidi override and
    /// isolate, soft hyphen, BOM, tag and interlinear controls), line or
    /// paragraph separator, and every backslash is visibly escaped. One
    /// filename can therefore neither inject lines, emit terminal-like
    /// control, nor visually spoof another path in Status Center or
    /// Markdown, and distinct raw paths stay distinct because the escape
    /// introducer itself is escaped. Raw paths stay raw in the snapshot for
    /// exact comparison; nothing is read from disk.
    public static func displayPath(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{1b}": result += "\\e"
            case _ where scalar.value < 0x20 || scalar.value == 0x7f:
                result += String(format: "\\x%02x", scalar.value)
            case _ where Self.isInvisibleControl(scalar):
                result += String(format: "\\u{%04x}", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func isInvisibleControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    /// The one fixed argv used for every capture: a porcelain status with NUL
    /// separators. No diff, log, show or blame is ever requested.
    public static func arguments(for folder: String) -> [String] {
        [
            "-C", folder, "-c", "core.fsmonitor=false",
            "status", "--porcelain=v2", "--branch", "--untracked-files=normal", "-z",
        ]
    }

    public static func parseStatus(_ output: Data, folder: String, capturedAt: Date) -> DelegationGitSnapshot {
        let tokens = output.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var headRevision: String?
        var branch: String?
        var isDetached = false
        var paths: Set<String> = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.isEmpty { continue }
            if token.hasPrefix("# branch.oid ") {
                let oid = String(token.dropFirst("# branch.oid ".count))
                headRevision = oid == "(initial)" || oid.isEmpty ? nil : oid
                continue
            }
            if token.hasPrefix("# branch.head ") {
                let head = String(token.dropFirst("# branch.head ".count))
                if head == "(detached)" {
                    isDetached = true
                    branch = nil
                } else if !head.isEmpty {
                    branch = head
                }
                continue
            }
            if token.hasPrefix("# ") { continue }
            switch token.first {
            case "1":
                if let path = lastField(token, count: 9) { paths.insert(path) }
            case "2":
                if let path = lastField(token, count: 10) { paths.insert(path) }
                if index < tokens.count {
                    let original = tokens[index]
                    index += 1
                    if !original.isEmpty { paths.insert(original) }
                }
            case "u":
                if let path = lastField(token, count: 11) { paths.insert(path) }
            case "?", "!":
                let path = String(token.dropFirst(2))
                if !path.isEmpty { paths.insert(path) }
            default:
                continue
            }
        }
        let sorted = paths.sorted()
        return DelegationGitSnapshot(
            capturedAt: capturedAt,
            folder: folder,
            headRevision: headRevision,
            branch: branch,
            isDetached: isDetached,
            dirtyPaths: Array(sorted.prefix(DelegationGitSnapshot.maximumPaths)),
            dirtyPathCount: sorted.count
        )
    }

    public static func compare(
        delegation: DelegationGitSnapshot?,
        returned: DelegationGitSnapshot?
    ) -> DelegationGitComparison? {
        guard let delegation, let returned, delegation.isAvailable, returned.isAvailable else { return nil }
        let before = Set(delegation.dirtyPaths), after = Set(returned.dirtyPaths)
        // Absence is evidence only when the opposite snapshot is complete.
        let removed = returned.isTruncated ? Set<String>() : before.subtracting(after)
        let added = delegation.isTruncated ? Set<String>() : after.subtracting(before)
        let changed = removed.union(added).sorted()
        return DelegationGitComparison(
            changedPaths: Array(changed.prefix(DelegationGitSnapshot.maximumPaths)),
            changedPathCount: changed.count,
            isLowerBound: delegation.isTruncated || returned.isTruncated,
            headMoved: delegation.headRevision != returned.headRevision,
            folderChanged: delegation.folder != returned.folder
        )
    }

    /// Porcelain v2 records end with the path; everything before it is fixed
    /// columns (status, submodule, modes, hashes, rename score) that are
    /// deliberately dropped.
    private static func lastField(_ token: String, count: Int) -> String? {
        let parts = token.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false)
        guard parts.count == count else { return nil }
        let path = String(parts[count - 1])
        return path.isEmpty ? nil : path
    }
}

/// Runs the one fixed Git status command with a hard timeout through the
/// existing argv-only runner. A non-Git folder yields nil; any other failure
/// yields an informational snapshot with a short reason and no paths.
public final class DelegationGitSnapshotCapture: @unchecked Sendable {
    private let runner: CommandRunning
    private let gitExecutable: URL
    private let environment: [String: String]
    private let fileManager: FileManager
    private let clock: () -> Date
    /// Answers "which managed record is exactly this Git worktree root" from
    /// Parley's own records at capture time; nil when none or not configured.
    /// The root comes from Git (`--show-toplevel`), so a nested worktree or an
    /// unmanaged nested repository is never attributed to a managed parent.
    private let managedWorktreeLookup: (@Sendable (String) -> ManagedWorktreeEvidence?)?

    public init(
        runner: CommandRunning = ProcessCommandRunner(timeout: 2),
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        managedWorktreeLookup: (@Sendable (String) -> ManagedWorktreeEvidence?)? = nil
    ) {
        self.runner = runner
        self.managedWorktreeLookup = managedWorktreeLookup
        self.gitExecutable = gitExecutable
        var gitEnvironment = environment
        gitEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        gitEnvironment["GIT_PAGER"] = "cat"
        gitEnvironment["PAGER"] = "cat"
        gitEnvironment["LC_ALL"] = "C"
        self.environment = gitEnvironment
        self.fileManager = fileManager
        self.clock = clock
    }

    public func snapshot(in folder: String) -> DelegationGitSnapshot? {
        let capturedAt = clock()
        func unavailable(_ reason: String) -> DelegationGitSnapshot {
            DelegationGitSnapshot(
                capturedAt: capturedAt,
                folder: folder,
                headRevision: nil,
                branch: nil,
                isDetached: false,
                dirtyPaths: [],
                dirtyPathCount: 0,
                unavailableReason: reason
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return unavailable("the working folder is missing")
        }
        let output: CommandOutput
        do {
            output = try runner.run(
                executable: gitExecutable,
                arguments: DelegationGitFacts.arguments(for: folder),
                environment: environment,
                input: nil
            )
        } catch {
            return unavailable("git status could not start")
        }
        if output.status == 124 { return unavailable("git status timed out") }
        guard output.status == 0 else {
            if output.stderrText.lowercased().contains("not a git repository") { return nil }
            return unavailable("git status exited \(output.status)")
        }
        var snapshot = DelegationGitFacts.parseStatus(output.stdout, folder: folder, capturedAt: capturedAt)
        if let managedWorktreeLookup, let root = worktreeRoot(of: folder) {
            snapshot.managedWorktree = managedWorktreeLookup(root)
        }
        return snapshot
    }

    private func worktreeRoot(of folder: String) -> String? {
        guard let output = try? runner.run(executable: gitExecutable,
            arguments: ["-C", folder, "-c", "core.fsmonitor=false", "rev-parse", "--show-toplevel"], environment: environment, input: nil),
              output.status == 0 else { return nil }
        let root = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.hasPrefix("/") ? GitWorktreeResolver.canonicalPath(root) : nil
    }
}

extension ManagedWorktreeStore {
    /// Lookup for delegation Git facts: the record whose path is exactly this
    /// Git worktree root, read from the store file at that moment. A read
    /// failure yields nil, which the snapshot shows as no evidence.
    public func evidence(forWorktreeRoot root: String) -> ManagedWorktreeEvidence? {
        guard let records = try? records() else { return nil }
        let canonical = GitWorktreeResolver.canonicalPath(root)
        return records.first { $0.path == canonical }.map(ManagedWorktreeEvidence.init(record:))
    }
}
