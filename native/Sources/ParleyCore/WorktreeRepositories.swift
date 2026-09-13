import Foundation

/// Why a repository is listed in the worktree manager. One repository can
/// be known for several reasons; the entry keeps all of them.
public enum WorktreeRepositorySource: String, Codable, CaseIterable, Hashable, Sendable {
    /// A pane's working folder, started or stopped, in this runtime.
    case pane
    /// A workspace's attached folder.
    case attachment
    case favourite
    case recent
    /// The folder of a managed worktree record.
    case record
    /// Added by the person with Add Repository…; the only source that persists.
    case added

    public var label: String {
        switch self {
        case .pane: "pane"
        case .attachment: "attached folder"
        case .favourite: "favourite"
        case .recent: "recent folder"
        case .record: "worktree record"
        case .added: "added"
        }
    }
}

/// A folder the manager should resolve to a repository, with why.
public struct WorktreeRepositoryCandidate: Equatable, Hashable, Sendable {
    public let folder: String
    public let source: WorktreeRepositorySource

    public init(folder: String, source: WorktreeRepositorySource) {
        self.folder = folder
        self.source = source
    }
}

/// One repository in the manager's list, keyed by its primary checkout.
/// `worktrees` is Git's registry as last read; a missing repository has none.
public struct WorktreeRepositoryEntry: Identifiable, Equatable, Sendable {
    public let primaryPath: String
    public let name: String
    public let sources: Set<WorktreeRepositorySource>
    public let worktrees: [GitWorktreeRecord]
    /// An added folder that no longer resolves to a Git repository. It stays
    /// listed and marked; Forget removes it and changes nothing on disk.
    public let isMissing: Bool

    public init(primaryPath: String, name: String, sources: Set<WorktreeRepositorySource>, worktrees: [GitWorktreeRecord], isMissing: Bool) {
        self.primaryPath = primaryPath
        self.name = name
        self.sources = sources
        self.worktrees = worktrees
        self.isMissing = isMissing
    }

    public var id: String { primaryPath }
    public var primary: GitWorktreeRecord? { worktrees.first { $0.isPrimary } }
    public var linked: [GitWorktreeRecord] { worktrees.filter { !$0.isPrimary } }
    public var linkedCount: Int { linked.count }
    public var staleCount: Int { linked.filter { $0.pruneReason != nil }.count }
    /// Only an entry whose sole reason for being listed is the person's own
    /// addition can be forgotten; every other source comes back on its own.
    public var canForget: Bool { sources == [.added] }
}

/// The pure merge behind the repository list: every candidate that resolved
/// joins the entry for its primary checkout and adds its source; an added
/// folder that did not resolve becomes a missing entry named by its last
/// path component; any other unresolved folder is simply not a repository.
public enum WorktreeRepositoryCatalog {
    public static func merge(resolved: [(candidate: WorktreeRepositoryCandidate, repository: GitWorktreeRepository?)]) -> [WorktreeRepositoryEntry] {
        var entries: [String: (name: String, sources: Set<WorktreeRepositorySource>, worktrees: [GitWorktreeRecord], missing: Bool)] = [:]
        for (candidate, repository) in resolved {
            if let repository {
                var entry = entries[repository.primaryPath] ?? (repository.name, [], repository.worktrees, false)
                entry.sources.insert(candidate.source)
                entry.worktrees = repository.worktrees
                entry.missing = false
                entries[repository.primaryPath] = entry
            } else if candidate.source == .added {
                let key = GitWorktreeResolver.canonicalPath(candidate.folder)
                if var existing = entries[key] {
                    existing.sources.insert(.added)
                    entries[key] = existing
                } else {
                    let component = URL(fileURLWithPath: key).lastPathComponent
                    entries[key] = (component.isEmpty ? key : component, [.added], [], true)
                }
            }
        }
        return entries.map { key, value in
            WorktreeRepositoryEntry(primaryPath: key, name: value.name, sources: value.sources, worktrees: value.worktrees, isMissing: value.missing)
        }.sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.primaryPath < $1.primaryPath : byName == .orderedAscending
        }
    }
}

/// Folders the person added to the manager, persisted so the window is
/// useful with no pane open. Paths only; no authority of any kind.
public final class WorktreeRepositoryStore: @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var folders: [String]
    }

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func folders() throws -> [String] { try lock.withLock { try load().folders } }

    /// Adds the canonical spelling once; a second add of the same folder is a no-op.
    public func add(_ folder: String) throws {
        try lock.withLock {
            var document = try load()
            let canonical = GitWorktreeResolver.canonicalPath(folder)
            guard !document.folders.contains(canonical) else { return }
            document.folders.append(canonical)
            document.folders.sort()
            try write(document)
        }
    }

    public func forget(_ folder: String) throws {
        try lock.withLock {
            var document = try load()
            let canonical = GitWorktreeResolver.canonicalPath(folder)
            document.folders.removeAll { $0 == canonical || $0 == folder }
            try write(document)
        }
    }

    private func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: file.path) else { return Document(folders: []) }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
    }

    private func write(_ document: Document) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
