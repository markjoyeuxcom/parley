import Foundation
import ParleyCore

private func repoExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorktreeRepositories", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func tree(_ path: String, branch: String?, primary: Bool = false, prunable: Bool = false) -> GitWorktreeRecord {
    GitWorktreeRecord(path: path, head: "0123456789abcdef0123456789abcdef01234567", branch: branch, isDetached: branch == nil,
        lockReason: nil, pruneReason: prunable ? "gitdir file points to non-existent location" : nil, isPrimary: primary)
}

/// The repository list is a pure merge over resolved candidates: every
/// source that resolves to the same primary checkout joins one entry, an
/// added folder that resolves to nothing stays listed as missing, and any
/// other unresolved folder is not a repository at all.
func worktreeRepositoryCatalogChecks() throws {
    let a = GitWorktreeRepository(primaryPath: "/repos/alpha", worktrees: [tree("/repos/alpha", branch: "main", primary: true), tree("/repos/alpha/.worktrees/x", branch: "feat/x"), tree("/tmp/gone", branch: "feat/gone", prunable: true)])
    let b = GitWorktreeRepository(primaryPath: "/repos/beta", worktrees: [tree("/repos/beta", branch: "main", primary: true)])
    let entries = WorktreeRepositoryCatalog.merge(resolved: [
        (WorktreeRepositoryCandidate(folder: "/repos/alpha/src", source: .pane), a),
        (WorktreeRepositoryCandidate(folder: "/repos/alpha", source: .favourite), a),
        (WorktreeRepositoryCandidate(folder: "/repos/alpha/.worktrees/x", source: .record), a),
        (WorktreeRepositoryCandidate(folder: "/repos/alpha", source: .added), a),
        (WorktreeRepositoryCandidate(folder: "/repos/beta", source: .attachment), b),
        (WorktreeRepositoryCandidate(folder: "/somewhere/deleted", source: .added), nil),
        (WorktreeRepositoryCandidate(folder: "/not/a/repo", source: .recent), nil),
    ])
    try repoExpect(entries.map(\.name) == ["alpha", "beta", "deleted"], "entries were not merged and ordered by name: \(entries.map(\.name))")
    let alpha = entries[0]
    try repoExpect(alpha.sources == [.pane, .favourite, .record, .added] && !alpha.isMissing, "alpha did not union its sources: \(alpha.sources)")
    try repoExpect(alpha.linkedCount == 2 && alpha.staleCount == 1 && alpha.primary?.path == "/repos/alpha", "alpha's counts were wrong")
    try repoExpect(!alpha.canForget, "a repository known from panes could be forgotten")
    let beta = entries[1]
    try repoExpect(beta.sources == [.attachment] && beta.linkedCount == 0 && !beta.canForget, "beta was misread")
    let deleted = entries[2]
    try repoExpect(deleted.isMissing && deleted.sources == [.added] && deleted.worktrees.isEmpty && deleted.canForget && deleted.primaryPath == "/somewhere/deleted",
        "an added folder that no longer resolves was not kept as missing")
    try repoExpect(!entries.contains { $0.primaryPath == "/not/a/repo" }, "a recent folder that is not a repository was listed")
    // A missing added entry is replaced when the same key later resolves.
    let revived = WorktreeRepositoryCatalog.merge(resolved: [
        (WorktreeRepositoryCandidate(folder: "/repos/alpha", source: .added), nil),
        (WorktreeRepositoryCandidate(folder: "/repos/alpha", source: .pane), a),
    ])
    try repoExpect(revived.count == 1 && !revived[0].isMissing && revived[0].sources == [.added, .pane], "a resolved repository did not replace its missing placeholder")
}

/// Added folders persist as canonical paths, once each, and Forget removes
/// exactly one; nothing else is stored.
func worktreeRepositoryStoreChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-repo-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("app/worktree-repositories.json")
    let store = WorktreeRepositoryStore(file: file)
    try repoExpect(try store.folders().isEmpty, "a missing store was not empty")
    try store.add("/tmp/../tmp/repo-one/")
    try store.add("/tmp/repo-one")
    try store.add("/tmp/repo-two")
    try repoExpect(try store.folders() == [GitWorktreeResolver.canonicalPath("/tmp/repo-one"), GitWorktreeResolver.canonicalPath("/tmp/repo-two")],
        "folders were not stored once, canonical and sorted: \(try store.folders())")
    try repoExpect(try WorktreeRepositoryStore(file: file).folders().count == 2, "the store did not persist")
    try store.forget("/tmp/repo-one")
    try repoExpect(try store.folders() == [GitWorktreeResolver.canonicalPath("/tmp/repo-two")], "forget removed the wrong folder")
    let text = try String(contentsOf: file, encoding: .utf8)
    try repoExpect(text.contains("\"version\"") && !text.contains("token") && !text.contains("credential"), "the store holds more than folders")
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    try repoExpect(permissions == 0o600, "the store file is not private: \(String(describing: permissions))")
}

/// Rows built from Git's registry alone: no owner, stale before any fact,
/// the primary never integrable, and a recorded tree still carries its base.
func worktreeRegistryRowChecks() throws {
    let facts = ManagedWorktreeFacts(recordID: "/repos/alpha/.worktrees/x", currentBranch: "feat/x", head: "abc123abc123abc1", changedPathCount: 0,
        upstreamAheadCount: nil, hasUpstream: false, registered: true, primaryHead: "def", aheadOfPrimary: 0, behindPrimary: 3, containedInPrimary: true)
    let plain = WorktreeBoardRow.derive(tree: tree("/repos/alpha/.worktrees/x", branch: "feat/x"), record: nil, facts: facts, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    try repoExpect(plain.state == .integrated && plain.ownerLabel == "Not recorded" && !plain.isRecorded && plain.branch == "feat/x" && plain.path == "/repos/alpha/.worktrees/x",
        "an unrecorded integrated tree was misread: \(plain.state) \(plain.ownerLabel)")
    try repoExpect(!plain.canIntegrate && plain.baseLabel.isEmpty && !plain.factsLine.contains("existing tree") && plain.factsLine.contains("ahead 0 · behind 3"),
        "an unrecorded row showed record-only labels: \(plain.factsLine)")
    let stale = WorktreeBoardRow.derive(tree: tree("/tmp/gone", branch: "feat/gone", prunable: true), record: nil, facts: facts, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    try repoExpect(stale.state == .stale && !stale.canIntegrate && stale.factsLine.contains("prunable"), "a prunable entry was not stale: \(stale.state)")
    let primary = WorktreeBoardRow.derive(tree: tree("/repos/alpha", branch: "main", primary: true), record: nil, facts: facts, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    try repoExpect(primary.isPrimary && !primary.canIntegrate, "the primary checkout was offered Integrate")
    let record = ManagedWorktreeRecord(id: "r", commonDirectory: "/repos/alpha/.git", path: "/repos/alpha/.worktrees/x", branch: "feat/x", baseRef: "main", baseCommit: "1234567890abcdef",
        createdAt: Date(timeIntervalSince1970: 0), parleyCreated: true, creationToken: "t", teamSessionID: nil, requestedByPaneID: nil, warning: nil)
    let recorded = WorktreeBoardRow.derive(tree: tree("/repos/alpha/.worktrees/x", branch: "feat/x"), record: record, facts: facts, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    try repoExpect(recorded.ownerLabel == "You" && recorded.baseLabel == "base 1234567890ab (main)" && recorded.factsLine.hasSuffix("created by Parley") && recorded.isRecorded,
        "a recorded tree lost its annotations: \(recorded.factsLine)")
    let locked = WorktreeBoardRow.derive(tree: GitWorktreeRecord(path: "/repos/alpha/.worktrees/l", head: "abc", branch: "feat/l", isDetached: false, lockReason: "keep", pruneReason: nil, isPrimary: false),
        record: nil, facts: nil, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    try repoExpect(locked.state == .unread && locked.factsLine.contains("locked: keep"), "a lock reason was not shown: \(locked.factsLine)")
}

@MainActor
let worktreeRepositoryChecks: [(String, () throws -> Void)] = [
    ("worktree discovery preserves literal line breaks from real Git", worktreeLineBreakPathChecks),
    ("worktree manager merges repositories from every source and keeps added folders that vanished", worktreeRepositoryCatalogChecks),
    ("worktree manager stores added folders canonically, once, privately", worktreeRepositoryStoreChecks),
    ("worktree board rows from Git's registry alone have no owner and are stale before any fact", worktreeRegistryRowChecks),
]

func worktreeLineBreakPathChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-worktree-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("primary")
    let linked = root.appendingPathComponent("linked\nworktree\rwith\ttab")
    let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    let runner = ProcessCommandRunner(timeout: 5)
    func git(_ arguments: [String]) throws {
        let output = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, environment: environment)
        try repoExpect(output.status == 0, "Git fixture failed: \(output.stderrText)")
    }
    try git(["init", "-q", "-b", "main", primary.path])
    try git(["-C", primary.path, "-c", "user.name=Parley Check", "-c", "user.email=check@example.invalid", "commit", "-qm", "fixture", "--allow-empty"])
    try git(["-C", primary.path, "worktree", "add", "-q", "-b", "linked", linked.path])
    let resolver = GitWorktreeResolver(environment: environment)
    let discovered = resolver.repository(in: linked.path)
    let expected = GitWorktreeResolver.canonicalPath(linked.path)
    try repoExpect(discovered?.currentWorktreePath == expected, "Git's top-level path lost a literal line break")
    try repoExpect(discovered?.repository.worktrees.count == 2
        && discovered?.repository.worktrees.last?.path == expected
        && discovered?.repository.worktrees.last?.branch == "linked",
        "Git's NUL-delimited worktree registration was split on a literal line break")
}
