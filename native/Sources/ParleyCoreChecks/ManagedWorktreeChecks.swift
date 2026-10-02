import Foundation
import ParleyCore

private func wtExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func wtRejects(_ message: String, _ operation: () throws -> Void) throws -> String {
    do { try operation() } catch { return error.localizedDescription }
    throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// A throwaway repository with one commit on `main`, plus a store and service
/// pointing at a private application directory.
private struct WorktreeFixture {
    let root: URL
    let repo: URL
    let service: ManagedWorktreeService
    let store: ManagedWorktreeStore

    init() throws {
        let root = URL(fileURLWithPath: "/tmp/parley-wt-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        self.root = root
        repo = root.appendingPathComponent("repo", isDirectory: true)
        store = ManagedWorktreeStore(file: root.appendingPathComponent("app/managed-worktrees.json"))
        service = ManagedWorktreeService(store: store, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path,
            "GIT_DIR": "/nonexistent/should-be-stripped", "GIT_WORK_TREE": "/nonexistent"])
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.email", "check@example.invalid"], in: repo)
        try git(["config", "user.name", "Check"], in: repo)
        try "print(1)\n".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "initial"], in: repo)
    }

    @discardableResult
    func git(_ arguments: [String], in folder: URL) throws -> String {
        let output = try ProcessCommandRunner(timeout: 20).run(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", folder.path] + arguments, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"])
        guard output.status == 0 else { throw NSError(domain: "ManagedWorktree", code: 2, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(output.stderrText)"]) }
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ message: String, in folder: URL, file: String = "src/main.swift", contents: String) throws -> String {
        try contents.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: folder)
        try git(["commit", "-q", "-m", message], in: folder)
        return try git(["rev-parse", "HEAD"], in: folder)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A fake `git` in front of the real one. `PARLEY_CHECK_MODE` selects a
    /// deterministic misbehaviour for `worktree add` or `worktree remove`;
    /// every other command passes through. Calls are logged for assertions.
    func wrappedService(mode: String, mutationTimeout: TimeInterval = 1) throws -> (service: ManagedWorktreeService, log: URL) {
        let wrapper = root.appendingPathComponent("fake-git-\(mode).sh")
        let log = root.appendingPathComponent("fake-git-\(mode).log")
        let script = """
        #!/bin/sh
        REAL=/usr/bin/git
        LOG=\(log.path)
        echo "$*" >> "$LOG"
        # argv: -C <folder> -c core.fsmonitor=false <command> <sub> ...
        if [ "$5" = "worktree" ] && [ "$6" = "add" ]; then
          case "\(mode)" in
            competitor-marker)
              "$REAL" "$@" >/dev/null 2>&1
              DIR=$("$REAL" -C "${10}" rev-parse --path-format=absolute --git-dir)
              echo competitor > "$DIR/parley-worktree-owner"
              echo "fatal: a branch named '$8' already exists" >&2
              exit 128 ;;
            competitor-plain)
              "$REAL" "$@" >/dev/null 2>&1
              echo "fatal: a branch named '$8' already exists" >&2
              exit 128 ;;
            competitor-marker-success)
              "$REAL" "$@" >/dev/null 2>&1
              DIR=$("$REAL" -C "${10}" rev-parse --path-format=absolute --git-dir)
              echo competitor > "$DIR/parley-worktree-owner"
              exit 0 ;;
            add-timeout)
              "$REAL" "$@" >/dev/null 2>&1
              sleep 3
              exit 0 ;;
          esac
        fi
        if [ "$5" = "worktree" ] && [ "$6" = "remove" ]; then
          case "\(mode)" in
            remove-hook-error)
              "$REAL" "$@" >/dev/null 2>&1
              echo "error: a hook complained after removal" >&2
              exit 1 ;;
            remove-noop)
              exit 0 ;;
            remove-timeout)
              "$REAL" "$@" >/dev/null 2>&1
              sleep 3
              exit 0 ;;
            remove-unlisted)
              "$REAL" "$@" >/dev/null 2>&1
              exit 0 ;;
          esac
        fi
        if [ "$5" = "worktree" ] && [ "$6" = "list" ] && [ "\(mode)" = "list-broken" ]; then
          echo "fatal: simulated registry read failure" >&2
          exit 128
        fi
        exec "$REAL" "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let service = ManagedWorktreeService(store: store, gitExecutable: wrapper, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path],
            readTimeout: 5, mutationTimeout: mutationTimeout)
        return (service, log)
    }
}

func managedWorktreeIdentityChecks() throws {
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let identity = try fixture.service.identity(of: fixture.repo.path)
    try wtExpect(identity.toplevel == GitWorktreeResolver.canonicalPath(fixture.repo.path)
        && identity.commonDirectory == GitWorktreeResolver.canonicalPath(fixture.repo.appendingPathComponent(".git").path),
        "repository identity did not resolve the canonical common directory: \(identity)")
    // Inherited GIT_DIR/GIT_WORK_TREE would have redirected -C; the scrubbed environment ignores them.
    try wtExpect(!fixture.service.scrubbedEnvironment().keys.contains { $0.hasPrefix("GIT_") && !["GIT_OPTIONAL_LOCKS", "GIT_TERMINAL_PROMPT", "GIT_PAGER"].contains($0) },
        "inherited GIT_* overrides survived environment scrubbing")
    // Paths with a newline survive the NUL-separated listing exactly.
    let odd = fixture.root.appendingPathComponent("odd\nname", isDirectory: true)
    try fixture.git(["worktree", "add", "-q", "--detach", odd.path], in: fixture.repo)
    let registered = try fixture.service.registeredWorktrees(of: identity)
    try wtExpect(registered.contains { $0.path == GitWorktreeResolver.canonicalPath(odd.path) && $0.isDetached },
        "a newline-bearing worktree path was not preserved: \(registered.map(\.path))")
    try wtExpect(registered.first?.isPrimary == true && registered.first?.branch == "refs/heads/main", "the primary worktree was not first or lost its branch")
    try wtExpect(try fixture.service.resolveCommit("main", in: fixture.repo.path) == (try fixture.git(["rev-parse", "HEAD"], in: fixture.repo)),
        "a branch ref did not resolve to its commit")
    _ = try wtRejects("a ref beginning with a dash was passed to git") { _ = try fixture.service.resolveCommit("--output=/tmp/x", in: fixture.repo.path) }
    _ = try wtRejects("a missing ref resolved") { _ = try fixture.service.resolveCommit("no-such-ref", in: fixture.repo.path) }
}

func managedWorktreeCreationChecks() throws {
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let base = try fixture.git(["rev-parse", "HEAD"], in: fixture.repo)
    let exclude = fixture.repo.appendingPathComponent(".git/info/exclude")
    try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# keep me\nlocal-notes/\n".write(to: exclude, atomically: true, encoding: .utf8)

    // Names and refs are validated before any git process runs.
    for bad in ["-b", "--upload-pack=x", "a..b", "a b", "feature/", "../escape", "feat\u{1b}", "refs/heads/x", ""] {
        _ = try wtRejects("branch name \(bad.debugDescription) was accepted") {
            _ = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: bad, baseRef: "main"))
        }
    }
    _ = try wtRejects("a base ref beginning with a dash was accepted") {
        _ = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/ok", baseRef: "-x"))
    }
    _ = try wtRejects("a symlinked .worktrees directory was accepted") {
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent(".worktrees"), withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".worktrees")) }
        _ = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/ok", baseRef: "main"))
    }

    let record = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/one", baseRef: "main"))
    let expectedPath = GitWorktreeResolver.canonicalPath(fixture.repo.appendingPathComponent(".worktrees/feat-one").path)
    try wtExpect(record.path == expectedPath && record.branch == "feat/one" && record.baseRef == "main" && record.baseCommit == base && record.parleyCreated,
        "the created record did not carry path, branch, base ref and resolved base commit: \(record)")
    try wtExpect(try fixture.git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: record.path)) == base
        && (try fixture.git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: record.path))) == "feat/one",
        "the new worktree is not on the new branch at the base commit")
    try wtExpect(try fixture.store.records().map(\.id) == [record.id], "the record was not persisted")
    let excluded = try String(contentsOf: exclude, encoding: .utf8)
    try wtExpect(excluded.hasPrefix("# keep me\nlocal-notes/\n") && excluded.components(separatedBy: "\n").filter { $0 == ".worktrees/" }.count == 1,
        "the local exclude was clobbered or the entry duplicated: \(excluded.debugDescription)")
    _ = try wtRejects("an existing branch was reused for a new worktree") {
        _ = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/one", baseRef: "main"))
    }
    // The preview captures the exact base commit; a ref that moved afterwards is refused, not followed.
    let preview = try fixture.service.createPreview(repositoryFolder: fixture.repo.path, branch: "feat/two", baseRef: "main")
    try wtExpect(preview.baseCommit == base && preview.path.hasSuffix("/.worktrees/feat-two") && preview.excludeEntryPresent, "the create preview did not capture base, path and exclude state: \(preview)")
    let moved = try fixture.commit("main moved", in: fixture.repo, contents: "print(9)\n")
    let stale = try wtRejects("a moved base ref was followed silently") {
        _ = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/two", baseRef: "main", expectedBaseCommit: preview.baseCommit))
    }
    try wtExpect(stale.contains("previewed"), "the moved-ref refusal did not explain itself: \(stale)")
    let second = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/two", baseRef: base, expectedBaseCommit: base))
    try wtExpect(second.baseCommit == base && moved != base && (try String(contentsOf: exclude, encoding: .utf8)).components(separatedBy: "\n").filter { $0 == ".worktrees/" }.count == 1,
        "a second creation duplicated the exclude entry or lost the base")
    try wtExpect(second.creationToken.map { !$0.isEmpty } == true && fixture.service.creationTokenMatches(second), "the creation marker was not written or does not match")
    // Selecting an existing registered tree records no ownership and no base unless one is given.
    let userTree = fixture.root.appendingPathComponent("user-tree")
    try fixture.git(["worktree", "add", "-q", "-b", "user/own", userTree.path, base], in: fixture.repo)
    let attached = try fixture.service.attach(existingPath: userTree.path, in: fixture.repo.path, baseRef: nil)
    try wtExpect(!attached.parleyCreated && attached.baseCommit == nil && attached.creationToken == nil, "attaching an existing tree claimed ownership or a base")
    _ = try wtRejects("an unregistered folder was attached") { _ = try fixture.service.attach(existingPath: fixture.root.path, in: fixture.repo.path, baseRef: nil) }
    // Ownership never transfers by path: a tree removed and recreated outside Parley is not ours any more.
    try fixture.git(["worktree", "remove", second.path], in: fixture.repo)
    try fixture.git(["worktree", "add", "-q", "--detach", second.path, base], in: fixture.repo)
    _ = try wtRejects("reattaching a recreated tree replaced its broken creation record") {
        _ = try fixture.service.attach(existingPath: second.path, in: fixture.repo.path, baseRef: nil)
    }
    try wtExpect(try fixture.store.record(path: second.path) == second && !fixture.service.creationTokenMatches(second),
        "a recreated tree at the same path replaced the original ownership evidence")
    let recreatedRefusals = try fixture.service.cleanupPreview(second, livePaneFolders: [], otherRuntimeStateFiles: []).refusals
    try wtExpect(recreatedRefusals.contains { $0.contains("creation marker") }, "cleanup of a recreated tree was not refused on identity: \(recreatedRefusals)")
    // A successful add whose record cannot be saved is reported as created-but-unrecorded, never as a retryable failure.
    let blocked = ManagedWorktreeStore(file: fixture.root.appendingPathComponent("blocked/store.json"))
    try "not a directory".write(to: fixture.root.appendingPathComponent("blocked"), atomically: true, encoding: .utf8)
    let blockedService = ManagedWorktreeService(store: blocked, environment: fixture.service.scrubbedEnvironment())
    do {
        _ = try blockedService.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/three", baseRef: base))
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "an unsaved record was reported as success"])
    } catch let error as ManagedWorktreeError {
        guard case let .createdButUnrecorded(path, _) = error else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsaved record raised \(error)"]) }
        try wtExpect(FileManager.default.fileExists(atPath: path) && error.localizedDescription.contains("Do not create it again"), "created-but-unrecorded lost the tree or the warning")
    }
}

func managedWorktreeHookOutcomeChecks() throws {
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    // A repository post-checkout hook runs during `worktree add`; a failing one must
    // be reported, the created tree must still be recorded, and nothing is retried.
    let hooks = fixture.repo.appendingPathComponent(".git/hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let marker = fixture.root.appendingPathComponent("hook-ran")
    try "#!/bin/sh\necho ran > '\(marker.path)'\nexit 1\n".write(to: hooks.appendingPathComponent("post-checkout"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent("post-checkout").path)
    let request = ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/hooked", baseRef: "main")
    // Only a successful add is a creation receipt: the tree the hook failure
    // left behind is registered, usable and described, but never owned.
    do {
        _ = try fixture.service.create(request)
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a tree left by a failing hook was adopted"])
    } catch let error as ManagedWorktreeError {
        guard case let .unmanaged(path, detail) = error else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "hook failure raised \(error)"]) }
        try wtExpect(detail.contains("exit status 1") && error.localizedDescription.contains("did not take ownership") && error.localizedDescription.contains("Do not create it again"),
            "the unmanaged outcome was not described honestly: \(error.localizedDescription)")
        let treePath = GitWorktreeResolver.canonicalPath(path)
        try wtExpect(try fixture.service.registeredWorktrees(of: fixture.service.identity(of: fixture.repo.path)).contains { $0.path == treePath },
            "the tree left by the hook failure was not registered")
        let admin = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: URL(fileURLWithPath: treePath))
        try wtExpect(!FileManager.default.fileExists(atPath: admin + "/parley-worktree-owner"), "a creation marker was written after a failed add")
    }
    try wtExpect(FileManager.default.fileExists(atPath: marker.path), "the fixture hook did not run (check is not exercising hook execution)")
    try wtExpect(try fixture.store.records().isEmpty, "a failed add was recorded, or was retried")
    let calls = try fixture.git(["worktree", "list", "--porcelain"], in: fixture.repo).components(separatedBy: "worktree ").count - 1
    try wtExpect(calls == 2, "the failed add was retried or duplicated: \(calls) trees")
}

func managedWorktreeCleanupChecks() throws {
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let record = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/clean", baseRef: "main"))
    let tree = URL(fileURLWithPath: record.path)
    let noPanes: [String] = []
    func preview(panes: [String] = noPanes, states: [URL] = []) throws -> WorktreeCleanupPreview {
        try fixture.service.cleanupPreview(record, livePaneFolders: panes, otherRuntimeStateFiles: states)
    }
    func removal(panes: [String] = noPanes, states: [URL] = [], acknowledged: [String] = []) -> String {
        do { _ = try fixture.service.remove(record, confirmed: .removeTree, acknowledgedIgnoredPaths: acknowledged, livePaneFolders: panes, otherRuntimeStateFiles: states); return "" }
        catch { return error.localizedDescription }
    }

    // A branch with a commit the primary does not have and no upstream: push state is unknown, so refused.
    _ = try fixture.commit("feature work", in: tree, contents: "print(2)\n")
    try wtExpect(try preview().refusals.contains { $0.contains("not merged") }, "an unpushed, unmerged branch was cleanable: \(try preview().refusals)")
    // A live pane whose cwd is nested inside the tree blocks removal.
    try wtExpect(try preview(panes: [tree.appendingPathComponent("src").path]).refusals.contains { $0.contains("pane") }, "a nested live pane cwd did not refuse")
    // Another runtime's state listing the path blocks removal; an unreadable state file also refuses.
    let otherState = fixture.root.appendingPathComponent("other-workbench-state.json")
    try #"{"panes":[{"id":"p","cwd":"\#(record.path)/src"}]}"#.write(to: otherState, atomically: true, encoding: .utf8)
    try wtExpect(try preview(states: [otherState]).refusals.contains { $0.contains("other Parley runtime") }, "another runtime's pane in the tree did not refuse")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: otherState.path)
    try wtExpect(try preview(states: [otherState]).refusals.contains { $0.contains("could not be read") }, "an unreadable other-runtime state did not refuse")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otherState.path)

    // Make the branch merged into the primary worktree so push/merge state is satisfied.
    try fixture.git(["merge", "-q", "--ff-only", "feat/clean"], in: fixture.repo)
    try wtExpect(try preview().refusals.isEmpty && preview().ignoredPaths.isEmpty, "a merged, clean tree was refused: \(try preview().refusals)")
    // An upstream that is configured but cannot be counted is never "nothing
    // unpushed". This tree is merged into the primary, which keeps every
    // commit, so it is removable on that evidence alone, and the preview must
    // say so rather than claim the upstream (2 October 2026: this used to
    // refuse, and blocked every merged team worktree). Unmerged, it refuses:
    // worktreeRemovalAfterMergeChecks.
    try fixture.git(["config", "branch.feat/clean.remote", "origin"], in: tree)
    try fixture.git(["config", "branch.feat/clean.merge", "refs/heads/feat/clean"], in: tree)
    let unknownUpstream = try preview()
    try wtExpect((unknownUpstream.facts.upstreamGone || unknownUpstream.facts.upstreamUnknown) && !unknownUpstream.facts.statusUncertain
                 && unknownUpstream.refusals.isEmpty && !unknownUpstream.preservationSummary.contains("no commits ahead")
                 && unknownUpstream.preservationSummary.contains("contained in the primary worktree's HEAD"),
        "a broken upstream on a merged tree was refused, or read as pushed: \(unknownUpstream.refusals) \(unknownUpstream.preservationSummary)")
    try fixture.git(["config", "--unset", "branch.feat/clean.remote"], in: tree)
    try fixture.git(["config", "--unset", "branch.feat/clean.merge"], in: tree)
    try wtExpect(try preview().refusals.isEmpty, "unsetting the broken upstream did not restore a clean preview")

    // Tracked modification and untracked file each refuse; ignored files need explicit acknowledgement.
    try "print(3)\n".write(to: tree.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
    try wtExpect(try preview().refusals.contains { $0.contains("modified") }, "a modified tracked file did not refuse")
    try fixture.git(["checkout", "--", "src/main.swift"], in: tree)
    try "x".write(to: tree.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try wtExpect(try preview().refusals.contains { $0.contains("untracked") }, "an untracked file did not refuse")
    try FileManager.default.removeItem(at: tree.appendingPathComponent("notes.txt"))
    try ".env\nbuild/\n".write(to: tree.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    _ = try fixture.commit("ignore rules", in: tree, file: ".gitignore", contents: ".env\nbuild/\n")
    try fixture.git(["merge", "-q", "--ff-only", "feat/clean"], in: fixture.repo)
    try "SECRET=1\n".write(to: tree.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("build"), withIntermediateDirectories: true)
    try "o".write(to: tree.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)
    let withIgnored = try preview()
    try wtExpect(withIgnored.refusals.isEmpty && Set(withIgnored.ignoredPaths) == [".env", "build/"], "ignored files were not listed for review: \(withIgnored)")
    try wtExpect(removal().contains("ignored"), "ignored files were deleted without acknowledgement")
    try wtExpect(removal(acknowledged: [".env"]).contains("ignored"), "a partial acknowledgement was accepted")

    // Locks and user ownership refuse; revalidation catches a change after the preview.
    try fixture.git(["worktree", "lock", "--reason", "keep", record.path], in: fixture.repo)
    try wtExpect(try preview().refusals.contains { $0.contains("locked") }, "a locked tree did not refuse")
    try fixture.git(["worktree", "unlock", record.path], in: fixture.repo)
    let attached = try fixture.service.attach(existingPath: fixture.repo.path, in: fixture.repo.path, baseRef: nil)
    try wtExpect(try fixture.service.cleanupPreview(attached, livePaneFolders: [], otherRuntimeStateFiles: []).refusals.contains { $0.contains("primary checkout") },
        "the tracked primary checkout was cleanable")
    try "late".write(to: tree.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
    try wtExpect(removal(acknowledged: [".env", "build/"]).contains("untracked"), "removal did not revalidate before mutating")
    try FileManager.default.removeItem(at: tree.appendingPathComponent("late.txt"))

    // Success: tree gone, record gone, branch retained, nothing forced.
    let outcome = try fixture.service.remove(record, confirmed: .removeTree, acknowledgedIgnoredPaths: [".env", "build/"], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcome.removedPath == record.path && outcome.recordRemoved && !FileManager.default.fileExists(atPath: record.path), "removal did not remove the tree: \(outcome)")
    try wtExpect(try fixture.git(["rev-parse", "--verify", "refs/heads/feat/clean"], in: fixture.repo).count == 40, "the branch was deleted with the worktree")
    try wtExpect(!(try fixture.store.records().contains { $0.id == record.id }), "the record survived removal")
    try wtExpect(!(try fixture.service.registeredWorktrees(of: fixture.service.identity(of: fixture.repo.path)).contains { $0.path == record.path }),
        "git still registers the removed tree")
}

func managedWorktreeEvidenceChecks() throws {
    // Delegation Git facts copy the managed record at capture time; a later
    // lookup never rewrites them, and records without the field still decode.
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let record = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/evidence", baseRef: "main"))
    let store = fixture.store
    let capture = DelegationGitSnapshotCapture(environment: fixture.service.scrubbedEnvironment(), managedWorktreeLookup: { root in store.evidence(forWorktreeRoot: root) })
    guard let inside = capture.snapshot(in: record.path + "/src") else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "no snapshot for a folder inside the worktree"]) }
    try wtExpect(inside.managedWorktree == ManagedWorktreeEvidence(record: record) && inside.summary.contains("recorded base \(record.baseCommit!.prefix(12))"),
        "the snapshot did not carry the managed worktree evidence: \(inside.summary)")
    guard let primary = capture.snapshot(in: fixture.repo.path) else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "no snapshot for the primary tree"]) }
    try wtExpect(primary.managedWorktree == nil, "the primary checkout was reported as a managed worktree")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let roundTrip = try decoder.decode(DelegationGitSnapshot.self, from: encoder.encode(inside))
    let evidenceMatches = roundTrip.managedWorktree == inside.managedWorktree
    let folderMatches = roundTrip.folder == inside.folder
    let headMatches = roundTrip.headRevision == inside.headRevision
    try wtExpect(evidenceMatches && folderMatches && headMatches, "the evidence did not round-trip")
    var legacy = try JSONSerialization.jsonObject(with: encoder.encode(inside)) as! [String: Any]
    legacy.removeValue(forKey: "managedWorktree")
    let decoded = try decoder.decode(DelegationGitSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    try wtExpect(decoded.managedWorktree == nil && decoded.folder == inside.folder, "a snapshot without the field failed to decode")
    // Nested managed trees attribute to the actual Git worktree root, and an
    // unmanaged repository nested in a managed tree is never attributed to it.
    let inner = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: record.path, branch: "feat/inner-evidence", baseRef: "HEAD"))
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: inner.path).appendingPathComponent("deep"), withIntermediateDirectories: true)
    try wtExpect(capture.snapshot(in: inner.path + "/deep")?.managedWorktree == ManagedWorktreeEvidence(record: inner), "a folder inside the nested tree was attributed to the outer tree")
    try wtExpect(capture.snapshot(in: record.path + "/src")?.managedWorktree == ManagedWorktreeEvidence(record: record), "a folder in the outer tree lost its own evidence")
    let foreign = URL(fileURLWithPath: record.path).appendingPathComponent("vendor")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    try fixture.git(["init", "-q", "-b", "main"], in: foreign)
    try wtExpect(capture.snapshot(in: foreign.path)?.managedWorktree == nil, "an unmanaged nested repository was attributed to its managed parent")
    // Removing the record afterwards leaves the captured evidence untouched.
    try store.remove(id: record.id)
    try wtExpect(inside.managedWorktree != nil && store.evidence(forWorktreeRoot: record.path) == nil, "captured evidence depended on the live record")
}

/// The first team-session worktree (feat/pane-stop, 2 October 2026) could not
/// be removed after its merge request was merged. GitLab deleted the source
/// branch and a pruning fetch removed its remote-tracking ref, so the
/// upstream count failed and was reported as "Git status could not be read";
/// and SwiftPM's .build held its own package clones, reported as "another
/// registered worktree". Both refused a tree whose every commit was on main.
func worktreeRemovalAfterMergeChecks() throws {
    // The table: a gone or unreadable upstream is settled by the primary.
    var facts = WorktreeCleanupFacts(parleyCreated: true, creationTokenVerified: true, registered: true, registryReadable: true, pathInspectable: true,
        pathExists: true, pathIsDirectory: true, recordInventoryReadable: true, recordPresentInInventory: true, recordUnchangedInInventory: true,
        locked: false, prunable: false, nestedWorktreePaths: [], livePaneFolders: [], otherRuntimePaneFolders: [], otherRuntimeStateUnreadable: false,
        modifiedPaths: [], untrackedPaths: [], ignoredPaths: [], ignoredListTruncated: false, upstreamAheadCount: 0, hasUpstream: true,
        mergedIntoPrimary: true, statusUncertain: false, path: "/r/.worktrees/x", upstreamGone: true)
    try wtExpect(WorktreeCleanupPolicy.refusals(for: facts).isEmpty, "a merged tree whose upstream was deleted was refused: \(WorktreeCleanupPolicy.refusals(for: facts))")
    facts.mergedIntoPrimary = false
    try wtExpect(WorktreeCleanupPolicy.refusals(for: facts).contains { $0.contains("upstream branch no longer exists") },
                 "an unmerged tree with a deleted upstream did not say why: \(WorktreeCleanupPolicy.refusals(for: facts))")
    facts.upstreamGone = false; facts.upstreamUnknown = true; facts.mergedIntoPrimary = true
    try wtExpect(WorktreeCleanupPolicy.refusals(for: facts).isEmpty, "a merged tree with an unreadable upstream was refused")
    facts.mergedIntoPrimary = false
    let unknown = WorktreeCleanupPolicy.refusals(for: facts)
    try wtExpect(unknown.contains { $0.contains("upstream could not be read") } && !unknown.contains { $0.contains("Git status") },
                 "an unreadable upstream was not named as such: \(unknown)")
    facts = WorktreeCleanupFacts(parleyCreated: true, creationTokenVerified: true, registered: true, registryReadable: true, pathInspectable: true,
        pathExists: true, pathIsDirectory: true, recordInventoryReadable: true, recordPresentInInventory: true, recordUnchangedInInventory: true,
        locked: false, prunable: false, nestedWorktreePaths: [], livePaneFolders: [], otherRuntimePaneFolders: [], otherRuntimeStateUnreadable: false,
        modifiedPaths: [], untrackedPaths: [], ignoredPaths: [], ignoredListTruncated: false, upstreamAheadCount: 0, hasUpstream: false,
        mergedIntoPrimary: true, statusUncertain: false, path: "/r/.worktrees/x", nestedRepositoryPaths: ["/r/.worktrees/x/ignored/clone"])
    let repository = WorktreeCleanupPolicy.refusals(for: facts)
    try wtExpect(repository.contains { $0.contains("independent Git repository") && $0.contains("ignored/clone") } && !repository.contains { $0.contains("registered worktree") },
                 "an independent repository was not named as one: \(repository)")

    // Real Git, as GitLab and a pruning pull leave a merged branch.
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    try ".build/\n".write(to: f.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try f.git(["add", ".gitignore"], in: f.repo)
    try f.git(["commit", "-q", "-m", "ignore build"], in: f.repo)
    let remote = f.root.appendingPathComponent("merge-remote.git")
    try f.git(["init", "-q", "--bare", remote.path], in: f.root)
    try f.git(["remote", "add", "origin", remote.path], in: f.repo)
    try f.git(["push", "-q", "-u", "origin", "main"], in: f.repo)
    func pushedTree(_ branch: String, merge: Bool) throws -> ManagedWorktreeRecord {
        let record = try f.service.create(.init(repositoryFolder: f.repo.path, branch: branch, baseRef: "main"))
        let folder = URL(fileURLWithPath: record.path)
        _ = try f.commit("\(branch) work", in: folder, file: "src/\(branch.replacingOccurrences(of: "/", with: "-")).swift", contents: "print(\"\(branch)\")\n")
        try f.git(["push", "-q", "-u", "origin", branch], in: folder)
        if merge { try f.git(["merge", "-q", "--no-ff", "--no-edit", branch], in: f.repo) }
        try f.git(["push", "-q", "origin", "--delete", branch], in: f.repo)
        try f.git(["fetch", "-q", "--prune", "origin"], in: f.repo)
        return record
    }
    let merged = try pushedTree("feat/merged", merge: true)
    let mergedPreview = try f.service.cleanupPreview(merged, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(mergedPreview.facts.upstreamGone && !mergedPreview.facts.statusUncertain, "a deleted upstream was not read as gone: \(mergedPreview.facts)")
    try wtExpect(mergedPreview.decision == .removeTree, "a merged tree whose upstream was deleted was refused: \(mergedPreview.refusals)")
    try wtExpect(mergedPreview.preservationSummary.contains("no longer exists"), "the preview did not say what the removal relies on: \(mergedPreview.preservationSummary)")
    try wtExpect(f.service.facts(for: merged).upstreamGone == true, "the board's facts did not read the upstream as gone")
    let lost = try pushedTree("feat/lost", merge: false)
    let lostRefusals = try f.service.cleanupPreview(lost, livePaneFolders: [], otherRuntimeStateFiles: []).refusals
    try wtExpect(lostRefusals.contains { $0.contains("upstream branch no longer exists") } && !lostRefusals.contains { $0.contains("Git status") },
                 "an unmerged tree with a deleted upstream was refused for the wrong reason: \(lostRefusals)")

    // A SwiftPM-style build cache: its own package clones, tagged as a cache.
    let built = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/built", baseRef: "main"))
    let cache = URL(fileURLWithPath: built.path).appendingPathComponent(".build")
    let clone = cache.appendingPathComponent("checkouts/Package")
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    try f.git(["init", "-q", "-b", "main"], in: clone)
    let tag = cache.appendingPathComponent("CACHEDIR.TAG")
    func preview() throws -> WorktreeCleanupPreview { try f.service.cleanupPreview(built, livePaneFolders: [], otherRuntimeStateFiles: []) }
    let untagged = try preview()
    try wtExpect(untagged.facts.nestedRepositoryPaths.contains { GitWorktreeResolver.canonicalPath($0) == GitWorktreeResolver.canonicalPath(clone.path) }
                 && untagged.facts.nestedWorktreePaths.isEmpty && untagged.refusals.contains { $0.contains("independent Git repository") },
                 "an untagged clone was not refused as an independent repository: \(untagged.refusals)")
    try "Signature: 0000000000000000000000000000000\n".write(to: tag, atomically: true, encoding: .utf8)
    try wtExpect(try preview().decision != .removeTree, "a wrongly signed cache tag was trusted")
    try FileManager.default.removeItem(at: tag)
    let elsewhere = f.root.appendingPathComponent("real-tag")
    try "Signature: 8a477f597d28d172789f06886806bc55\n".write(to: elsewhere, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: tag, withDestinationURL: elsewhere)
    try wtExpect(try preview().decision != .removeTree, "a cache tag that is a symbolic link was trusted")
    try FileManager.default.removeItem(at: tag)
    try "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag.\n".write(to: tag, atomically: true, encoding: .utf8)
    let tagged = try preview()
    try wtExpect(tagged.decision == .removeTree && tagged.facts.cacheDirectories == [".build/"], "a tagged build cache still refused removal: \(tagged.refusals) \(tagged.facts.cacheDirectories)")
    try wtExpect(tagged.preservationSummary.contains("CACHEDIR.TAG") && tagged.ignoredPaths.contains(".build/"),
                 "the preview did not disclose the unsearched cache: \(tagged.preservationSummary)")
    let outcome = try f.service.remove(built, confirmed: .removeTree, acknowledgedIgnoredPaths: tagged.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcome.state == .removed && !FileManager.default.fileExists(atPath: built.path), "the tagged tree was not removed: \(outcome)")
}

func worktreeCleanupPolicyChecks() throws {
    // The pure decision table the native preview and removal both use.
    let facts = WorktreeCleanupFacts(parleyCreated: true, creationTokenVerified: true, registered: true, registryReadable: true, pathInspectable: true, pathExists: true, pathIsDirectory: true,
        recordInventoryReadable: true, recordPresentInInventory: true, recordUnchangedInInventory: true, locked: false, prunable: false,
        nestedWorktreePaths: [], livePaneFolders: [], otherRuntimePaneFolders: [], otherRuntimeStateUnreadable: false, modifiedPaths: [], untrackedPaths: [],
        ignoredPaths: [], ignoredListTruncated: false, upstreamAheadCount: 0, hasUpstream: true, mergedIntoPrimary: false, statusUncertain: false,
        path: "/r/.worktrees/x")
    try wtExpect(WorktreeCleanupPolicy.refusals(for: facts).isEmpty, "a clean pushed tree was refused")
    var f = facts; f.hasUpstream = false; f.mergedIntoPrimary = true
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).isEmpty, "a locally merged tree without upstream was refused")
    f.mergedIntoPrimary = false
    try wtExpect(!WorktreeCleanupPolicy.refusals(for: f).isEmpty, "no upstream and unmerged was allowed")
    f = facts; f.upstreamAheadCount = 2
    try wtExpect(!WorktreeCleanupPolicy.refusals(for: f).isEmpty, "unpushed commits were allowed")
    f = facts; f.livePaneFolders = ["/r/.worktrees/x/src"]
    try wtExpect(!WorktreeCleanupPolicy.refusals(for: f).isEmpty, "a nested pane cwd was allowed")
    f = facts; f.livePaneFolders = ["/r/.worktrees/xy"]
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).isEmpty, "a sibling path with a shared prefix was treated as nested")
    f = facts; f.ignoredListTruncated = true
    try wtExpect(!WorktreeCleanupPolicy.refusals(for: f).isEmpty, "a truncated ignored listing was allowed")
    f = facts; f.statusUncertain = true
    try wtExpect(!WorktreeCleanupPolicy.refusals(for: f).isEmpty, "uncertain git status was allowed")
    f = facts; f.nestedWorktreePaths = ["/r/.worktrees/x/.worktrees/inner"]
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("another registered worktree") }, "a nested registered worktree was allowed")
    f = facts; f.registered = false; f.pathExists = false
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) == .clearRecordOnly, "an absent, unregistered tree did not become record-only cleanup")
    f = facts; f.registered = false; f.pathExists = true
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) != .clearRecordOnly && !WorktreeCleanupPolicy.refusals(for: f).isEmpty, "an unregistered folder that still exists was treated as absent")
    f = facts; f.registered = false; f.pathInspectable = false; f.pathExists = false
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) != .clearRecordOnly && WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("could not be inspected") },
        "an uninspectable path was treated as absent")
    f = facts; f.registered = false; f.pathExists = true; f.pathIsDirectory = false
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) != .clearRecordOnly && WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("not a directory") },
        "a non-directory item at the recorded path was treated as absent")
    f = facts; f.registered = false; f.pathExists = false; f.recordInventoryReadable = false
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) != .clearRecordOnly && WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("records could not be read") },
        "an unreadable record inventory allowed record-only cleanup")
    f = facts; f.registered = false; f.pathExists = false; f.recordPresentInInventory = false; f.recordUnchangedInInventory = false
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) != .clearRecordOnly && WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("missing") },
        "a record missing from the fresh inventory allowed record-only cleanup")
    f = facts; f.recordUnchangedInInventory = false
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("changed since") }, "a changed record was accepted")
    f = facts; f.registered = false; f.registryReadable = false; f.pathExists = false
    try wtExpect(WorktreeCleanupPolicy.decision(for: f) != .clearRecordOnly && WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("could not be read") },
        "an unreadable registry with a missing folder became record-only cleanup")
    // A tracked tree (not Parley-created, no marker) is removable on the same
    // facts; only a Parley-created tree that lost its marker is refused.
    f = facts; f.parleyCreated = false; f.creationTokenVerified = false
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).isEmpty, "a clean tracked tree was refused for not being Parley-created")
    f = facts; f.parleyCreated = false; f.creationTokenVerified = false; f.registered = false
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("identity is uncertain") }, "a tracked tree Git does not register was allowed")
    f = facts; f.parleyCreated = false; f.creationTokenVerified = false; f.untrackedPaths = ["notes.txt"]
    try wtExpect(!WorktreeCleanupPolicy.refusals(for: f).isEmpty, "a dirty tracked tree was allowed")
    f = facts; f.parleyCreated = false; f.creationTokenVerified = false; f.isPrimary = true
    try wtExpect(WorktreeCleanupPolicy.refusals(for: f).contains { $0.contains("primary checkout") }, "a tracked primary checkout was allowed")
    for mutate in [{ (x: inout WorktreeCleanupFacts) in x.creationTokenVerified = false }, { $0.registered = false }, { $0.locked = true }, { $0.prunable = true },
                   { $0.otherRuntimeStateUnreadable = true }, { $0.otherRuntimePaneFolders = ["/r/.worktrees/x"] }, { $0.modifiedPaths = ["a"] }, { $0.untrackedPaths = ["b"] }] {
        var g = facts; mutate(&g)
        try wtExpect(!WorktreeCleanupPolicy.refusals(for: g).isEmpty, "a refusal condition was ignored")
    }
}

func managedWorktreeNestedCleanupChecks() throws {
    // Codex's reproduced data loss: an outer tree's removal must never take a
    // nested, independently registered worktree with it, whatever ignored
    // entries the person acknowledged and whether or not a pane is open.
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let outer = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/outer", baseRef: "main"))
    let inner = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: outer.path, branch: "feat/inner", baseRef: "HEAD"))
    let valuable = URL(fileURLWithPath: inner.path).appendingPathComponent("uncommitted-notes.txt")
    try "Uncommitted inner-worktree work must survive parent cleanup.\n".write(to: valuable, atomically: true, encoding: .utf8)
    let preview = try fixture.service.cleanupPreview(outer, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(preview.refusals.contains { $0.contains("another registered worktree") && $0.contains(inner.path) }, "outer cleanup did not refuse the nested worktree: \(preview.refusals)")
    try wtExpect(preview.facts.nestedWorktreePaths == [inner.path], "nested worktree facts were not reported: \(preview.facts.nestedWorktreePaths)")
    let refusal = try wtRejects("outer removal proceeded over a nested worktree") {
        _ = try fixture.service.remove(outer, confirmed: .removeTree, acknowledgedIgnoredPaths: preview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try wtExpect(refusal.contains("another registered worktree"), "the removal refusal did not name the nested tree: \(refusal)")
    try wtExpect(FileManager.default.fileExists(atPath: valuable.path), "the nested uncommitted file was deleted")
    let identity = try fixture.service.identity(of: fixture.repo.path)
    try wtExpect(try fixture.service.registeredWorktrees(of: identity).contains { $0.path == inner.path && !$0.isPrunable }, "the nested worktree lost its registration")
    try wtExpect(FileManager.default.fileExists(atPath: outer.path), "the outer tree was removed despite the refusal")
    // A nested tree Parley only knows by record (another repository) also refuses.
    let foreignRepo = fixture.root.appendingPathComponent("foreign")
    try FileManager.default.createDirectory(at: foreignRepo, withIntermediateDirectories: true)
    try fixture.git(["init", "-q", "-b", "main"], in: foreignRepo)
    try fixture.git(["config", "user.email", "check@example.invalid"], in: foreignRepo)
    try fixture.git(["config", "user.name", "Check"], in: foreignRepo)
    _ = try fixture.commit("foreign", in: foreignRepo, file: "f.txt", contents: "f\n")
    let second = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/second", baseRef: "main"))
    let foreignTreePath = second.path + "/vendor-tree"
    try fixture.git(["worktree", "add", "-q", "-b", "foreign/one", foreignTreePath, "main"], in: foreignRepo)
    _ = try fixture.service.attach(existingPath: foreignTreePath, in: foreignRepo.path, baseRef: nil)
    let secondPreview = try fixture.service.cleanupPreview(second, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(secondPreview.refusals.contains { $0.contains("another registered worktree") }, "a nested tree known only by record did not refuse: \(secondPreview.refusals)")
    // The record inventory is part of the safety evidence: a corrupt store must
    // refuse destructive cleanup rather than silently forgetting the foreign tree.
    let foreignNotes = URL(fileURLWithPath: foreignTreePath).appendingPathComponent("notes.txt")
    try "foreign uncommitted work\n".write(to: foreignNotes, atomically: true, encoding: .utf8)
    let storeFile = fixture.root.appendingPathComponent("app/managed-worktrees.json")
    let intactStore = try Data(contentsOf: storeFile)
    try Data("{ not json".utf8).write(to: storeFile)
    let corruptPreview = try fixture.service.cleanupPreview(second, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(corruptPreview.refusals.contains { $0.contains("records could not be read") }, "a corrupt record store did not refuse cleanup: \(corruptPreview.refusals)")
    let corruptRefusal = try wtRejects("removal proceeded with an unreadable record store") {
        _ = try fixture.service.remove(second, confirmed: .removeTree, acknowledgedIgnoredPaths: corruptPreview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try wtExpect(corruptRefusal.contains("records could not be read"), "the corrupt-store refusal did not explain itself: \(corruptRefusal)")
    try wtExpect(FileManager.default.fileExists(atPath: foreignNotes.path) && FileManager.default.fileExists(atPath: second.path), "the foreign nested tree or its parent was deleted despite the unreadable store")
    // A deleted store reads as empty, which would forget both the nested tree
    // and the target itself: the target record must be present and unchanged
    // in the fresh inventory, never taken from the caller's copy.
    try FileManager.default.removeItem(at: storeFile)
    let deletedPreview = try fixture.service.cleanupPreview(second, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(deletedPreview.refusals.contains { $0.contains("record of this worktree is missing") }, "a deleted record store did not refuse cleanup: \(deletedPreview.refusals)")
    let deletedRefusal = try wtRejects("removal proceeded after the record store was deleted") {
        _ = try fixture.service.remove(second, confirmed: .removeTree, acknowledgedIgnoredPaths: deletedPreview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try wtExpect(deletedRefusal.contains("missing"), "the deleted-store refusal did not explain itself: \(deletedRefusal)")
    try wtExpect(FileManager.default.fileExists(atPath: foreignNotes.path) && FileManager.default.fileExists(atPath: second.path), "the foreign nested tree or its parent was deleted despite the missing record")
    try intactStore.write(to: storeFile)
    // A record that changed since the preview (same id, different content) is stale.
    var stale = second
    stale.warning = "edited elsewhere"
    let stalePreview = try fixture.service.cleanupPreview(stale, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(stalePreview.refusals.contains { $0.contains("changed since") }, "a stale target record was accepted: \(stalePreview.refusals)")
}

func managedWorktreeBoundCreationChecks() throws {
    // The approved preview binds the repository and the exact path. If the
    // folder now resolves elsewhere (alias re-pointed to a clone with the same
    // commits), nothing is written anywhere before the refusal.
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repo)
    let preview = try fixture.service.createPreview(repositoryFolder: alias.path, branch: "feat/bound", baseRef: "main")
    let clone = fixture.root.appendingPathComponent("clone")
    try fixture.git(["clone", "-q", fixture.repo.path, clone.path], in: fixture.root)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: clone)
    let sameBase = try fixture.git(["rev-parse", "HEAD"], in: clone)
    try wtExpect(sameBase == preview.baseCommit, "the clone did not share the previewed base commit")
    let refusal = try wtRejects("creation followed a re-pointed alias into another repository") {
        _ = try fixture.service.create(ManagedWorktreeService.CreateRequest(preview: preview, repositoryFolder: alias.path))
    }
    try wtExpect(refusal.contains("different repository") || refusal.contains("previewed"), "the redirected creation was not explained: \(refusal)")
    try wtExpect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent(".worktrees").path), "a .worktrees directory was created in the redirected repository")
    let cloneExclude = clone.appendingPathComponent(".git/info/exclude")
    try wtExpect(!((try? String(contentsOf: cloneExclude, encoding: .utf8))?.contains(".worktrees/") ?? false), "the redirected repository's exclude file was written")
    try wtExpect((try? fixture.git(["rev-parse", "--verify", "--quiet", "refs/heads/feat/bound"], in: clone)) == nil, "a branch was created in the redirected repository")
    try wtExpect(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".worktrees/feat-bound").path), "the original repository was mutated by a refused creation")
    try wtExpect(try fixture.store.records().isEmpty, "a refused creation left a record")
    // The same preview against the original repository still creates exactly the previewed tree.
    let record = try fixture.service.create(ManagedWorktreeService.CreateRequest(preview: preview, repositoryFolder: fixture.repo.path))
    try wtExpect(record.path == preview.path && record.commonDirectory == preview.commonDirectory && record.baseCommit == preview.baseCommit, "the bound creation drifted from its preview")
}

func managedWorktreeCompetingCreatorChecks() throws {
    // A path that appears after a failed add is not Parley's just because it
    // exists: another creator's marker is preserved and the outcome is ambiguous.
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let base = try fixture.git(["rev-parse", "HEAD"], in: fixture.repo)
    // A nonzero add never adopts, whatever the tree looks like afterwards.
    let marked = try fixture.wrappedService(mode: "competitor-marker")
    do {
        _ = try marked.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/race-a", baseRef: base))
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a competitor's tree was adopted"])
    } catch let error as ManagedWorktreeError {
        guard case .unmanaged = error else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "competitor with marker raised \(error)"]) }
    }
    let adminDirectory = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: fixture.repo.appendingPathComponent(".worktrees/feat-race-a"))
    let marker = try String(contentsOf: URL(fileURLWithPath: adminDirectory).appendingPathComponent("parley-worktree-owner"), encoding: .utf8)
    try wtExpect(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "competitor", "the competitor's creation marker was overwritten: \(marker)")
    try wtExpect(try fixture.store.records().isEmpty, "an ambiguous creation was recorded as Parley's")

    let plain = try fixture.wrappedService(mode: "competitor-plain")
    do {
        _ = try plain.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/race-b", baseRef: base))
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a competitor's unmarked tree was adopted"])
    } catch let error as ManagedWorktreeError {
        guard case .unmanaged = error else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "plain competitor raised \(error)"]) }
    }
    let plainAdmin = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: fixture.repo.appendingPathComponent(".worktrees/feat-race-b"))
    try wtExpect(!FileManager.default.fileExists(atPath: plainAdmin + "/parley-worktree-owner"), "a marker was written into a tree Parley did not verifiably create")
    try wtExpect(try fixture.store.records().isEmpty, "an unmarked competitor tree was recorded")
    // Even a successful add does not adopt a tree that already carries a marker.
    let markedSuccess = try fixture.wrappedService(mode: "competitor-marker-success")
    do {
        _ = try markedSuccess.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/race-c", baseRef: base))
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a marked tree was adopted after a successful add"])
    } catch let error as ManagedWorktreeError {
        guard case .ambiguous = error else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "marked success raised \(error)"]) }
    }
    let successAdmin = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: fixture.repo.appendingPathComponent(".worktrees/feat-race-c"))
    try wtExpect((try String(contentsOf: URL(fileURLWithPath: successAdmin + "/parley-worktree-owner"), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines) == "competitor"
        && (try fixture.store.records().isEmpty), "the existing marker was overwritten or the tree recorded after a successful add")

    // A timed-out add is reconciled, not skipped: the tree Git registered on
    // our branch at our base is kept with a warning that names the timeout.
    let slow = try fixture.wrappedService(mode: "add-timeout", mutationTimeout: 1)
    do {
        _ = try slow.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/slow", baseRef: base))
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a timed-out add was adopted"])
    } catch let error as ManagedWorktreeError {
        guard case let .unmanaged(_, detail) = error, detail.contains("timed out") else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed-out add raised \(error)"]) }
    }
    let slowAdmin = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: fixture.repo.appendingPathComponent(".worktrees/feat-slow"))
    try wtExpect(!FileManager.default.fileExists(atPath: slowAdmin + "/parley-worktree-owner") && (try fixture.store.records().isEmpty),
        "a timed-out add wrote a marker or a record")
}

func managedWorktreeRemovalOutcomeChecks() throws {
    // Removal reports what was observed afterwards, never what Git's exit
    // status implied, and clearing a stale record never reruns Git.
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    func mergedTree(_ branch: String) throws -> ManagedWorktreeRecord {
        let record = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: branch, baseRef: "main"))
        return record
    }
    let hookError = try fixture.wrappedService(mode: "remove-hook-error")
    let first = try mergedTree("feat/rm-a")
    let outcomeA = try hookError.service.remove(first, confirmed: .removeTree, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeA.state == .removed && outcomeA.recordRemoved && !FileManager.default.fileExists(atPath: first.path) && outcomeA.detail.contains("exit status 1"),
        "a nonzero exit with the tree gone was not reported as removed: \(outcomeA)")

    let noop = try fixture.wrappedService(mode: "remove-noop")
    let second = try mergedTree("feat/rm-b")
    let outcomeB = try noop.service.remove(second, confirmed: .removeTree, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeB.state == .retained && !outcomeB.recordRemoved && FileManager.default.fileExists(atPath: second.path)
        && (try fixture.store.records().contains { $0.id == second.id }), "a success status with the tree still registered was not reported as retained: \(outcomeB)")

    let slow = try fixture.wrappedService(mode: "remove-timeout", mutationTimeout: 1)
    let third = try mergedTree("feat/rm-c")
    let outcomeC = try slow.service.remove(third, confirmed: .removeTree, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeC.state == .removed && outcomeC.recordRemoved && outcomeC.detail.contains("timed out"), "a timed-out removal was not reconciled: \(outcomeC)")

    // Record-only cleanup: the tree vanished outside Parley; the preview says
    // so, removal clears the record and the fake git logs no removal call.
    let stale = try mergedTree("feat/rm-d")
    try fixture.git(["worktree", "remove", stale.path], in: fixture.repo)
    let logged = try fixture.wrappedService(mode: "remove-unlisted")
    let stalePreview = try logged.service.cleanupPreview(stale, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(stalePreview.refusals.isEmpty && stalePreview.decision == .clearRecordOnly, "an already-removed tree was not offered as record-only cleanup: \(stalePreview.refusals)")
    let outcomeD = try logged.service.remove(stale, confirmed: .clearRecordOnly, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeD.state == .removed && outcomeD.recordRemoved && outcomeD.detail.contains("already"), "record-only cleanup did not clear the record: \(outcomeD)")
    let calls = (try? String(contentsOf: logged.log, encoding: .utf8)) ?? ""
    try wtExpect(!calls.contains("worktree remove"), "record-only cleanup reran git worktree remove")
    try wtExpect(!(try fixture.store.records().contains { $0.id == stale.id }), "the stale record survived")
    // Any filesystem item at the recorded path is presence with uncertain
    // identity, never a confirmed absence: no record-only cleanup, no Git.
    let occupied = try mergedTree("feat/rm-f")
    try fixture.git(["worktree", "remove", occupied.path], in: fixture.repo)
    try "not a worktree\n".write(to: URL(fileURLWithPath: occupied.path), atomically: true, encoding: .utf8)
    let occupiedPreview = try fixture.service.cleanupPreview(occupied, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(occupiedPreview.decision != .clearRecordOnly && occupiedPreview.refusals.contains { $0.contains("not a directory") },
        "a file occupying the recorded path was treated as an absent folder: \(occupiedPreview.refusals)")
    _ = try wtRejects("record-only cleanup ran over a file at the recorded path") {
        _ = try fixture.service.remove(occupied, confirmed: .clearRecordOnly, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try wtExpect((try fixture.store.records().contains { $0.id == occupied.id }) && FileManager.default.fileExists(atPath: occupied.path),
        "the record or the occupying file was removed")
    try FileManager.default.removeItem(atPath: occupied.path)
    // A path that cannot be inspected (EACCES on the parent) is unknown, never
    // absent: no record-only cleanup, record kept.
    let hidden = try mergedTree("feat/rm-g")
    try fixture.git(["worktree", "remove", hidden.path], in: fixture.repo)
    let parent = URL(fileURLWithPath: hidden.path).deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
    let hiddenPreview = try fixture.service.cleanupPreview(hidden, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(hiddenPreview.decision != .clearRecordOnly && hiddenPreview.refusals.contains { $0.contains("could not be inspected") },
        "an uninspectable path was treated as absent: \(hiddenPreview.refusals)")
    _ = try wtRejects("record-only cleanup ran over an uninspectable path") {
        _ = try fixture.service.remove(hidden, confirmed: .clearRecordOnly, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try wtExpect(try fixture.store.records().contains { $0.id == hidden.id }, "the record was cleared without a confirmed absence")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
    // With the registry unreadable, an absent folder is not a confirmed absence.
    let vanished = try mergedTree("feat/rm-e")
    try fixture.git(["worktree", "remove", vanished.path], in: fixture.repo)
    let blind = try fixture.wrappedService(mode: "list-broken")
    let blindPreview = try blind.service.cleanupPreview(vanished, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(blindPreview.decision != .clearRecordOnly && blindPreview.refusals.contains { $0.contains("could not be read") },
        "an unreadable registry allowed record-only cleanup: \(blindPreview.refusals)")
    try wtExpect(try fixture.store.records().contains { $0.id == vanished.id }, "a record was cleared without a confirmed absence")
}

func managedWorktreeFactsUncertaintyChecks() throws {
    // A read failure is unknown, never "Git no longer registers this path".
    let fixture = try WorktreeFixture()
    defer { fixture.cleanup() }
    let record = try fixture.service.create(ManagedWorktreeService.CreateRequest(repositoryFolder: fixture.repo.path, branch: "feat/facts", baseRef: "main"))
    try wtExpect(fixture.service.facts(for: record).registered == true, "a live tree was not reported as registered")
    let broken = try fixture.wrappedService(mode: "list-broken")
    try wtExpect(broken.service.facts(for: record).registered == nil, "a registry read failure was reported as a verified absence")
    try fixture.git(["worktree", "remove", record.path], in: fixture.repo)
    try wtExpect(fixture.service.facts(for: record).registered == false, "a removed tree was not reported as unregistered")
}

func workbenchFolderReservationChecks() throws {
    // The shared launch boundary refuses every creation, start and restart
    // inside a folder reserved for removal, whatever route asked.
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-reserve-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let tree = project.appendingPathComponent(".worktrees/feat-x")
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("src"), withIntermediateDirectories: true)
    let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    _ = try controller.createWorkspace(folder: project.path)
    let agent = try controller.createPane(kind: .claude, cwd: tree.path)
    // createPane starts panes; startPane ignores an already started pane, so the
    // stopped-placeholder route needs a genuinely stopped pane.
    try controller.stopPaneProcess(agent.id, expectedGeneration: nil)
    try wtExpect(try controller.listPanes().first { $0.id == agent.id }?.isStarted == false, "the agent pane did not stop before the start test")
    try controller.reserveFolderForRemoval(tree.path)
    try wtExpect(controller.reservedFolders() == [GitWorktreeResolver.canonicalPath(tree.path)], "the reservation was not recorded")
    _ = try wtRejects("a pane was created inside a reserved folder") { _ = try controller.createPane(kind: .shell, cwd: tree.appendingPathComponent("src").path) }
    _ = try wtRejects("a workspace was created inside a reserved folder") { _ = try controller.createWorkspace(folder: tree.path) }
    _ = try wtRejects("a stopped agent pane started inside a reserved folder") { try controller.startPane(agent.id) }
    _ = try wtRejects("a pane restarted inside a reserved folder") { try controller.restartPane(agent.id) }
    _ = try wtRejects("a second reservation of the same folder was accepted") { try controller.reserveFolderForRemoval(tree.path) }
    // Routes that never touched the toolbar guards: the approved command
    // pane (refused before its worker ticket is staged) and layout restore.
    let source = try controller.createPane(kind: .codex, cwd: project.path)
    var eligible = source
    eligible.relayEnabled = true
    let runs = ReviewedCommandRunCoordinator(authenticate: { _ in source.id }, panes: { [eligible] }, record: { _ in })
    let request = try runs.request(token: "capability", argv: ["/usr/bin/true"], folder: tree.path)
    try runs.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: tree.path, autoApprove: false)
    var launched = false
    var launchError: String?
    runs.launchApproved { run in
        do { _ = try controller.createApprovedCommandPane(run: run, workerExecutable: URL(fileURLWithPath: "/usr/bin/true")); launched = true }
        catch { launchError = error.localizedDescription; throw error }
    }
    try wtExpect(!launched && launchError?.contains("being removed") == true, "an approved command pane was created inside a reserved folder: \(String(describing: launchError))")
    let ticketDirectory = root.appendingPathComponent("runtime/approved-command-runs")
    let tickets = (try? FileManager.default.contentsOfDirectory(atPath: ticketDirectory.path)) ?? []
    try wtExpect(tickets.isEmpty, "a worker ticket was staged for a refused run: \(tickets)")
    let layout = SavedWorkspaceLayout(name: "Reserved", defaultFolder: project.path,
        root: .split(direction: .horizontal, ratio: 0.5, first: .leaf(SavedLayoutLeaf(kind: .shell, name: "Outside", folder: project.path)),
                     second: .leaf(SavedLayoutLeaf(kind: .shell, name: "Inside", folder: tree.appendingPathComponent("src").path))))
    let workspacesBefore = try controller.listWorkspaces().count
    _ = try wtRejects("a layout restored a pane inside a reserved folder") { _ = try controller.restoreWorkspaceLayout(layout) }
    try wtExpect(try controller.listWorkspaces().count == workspacesBefore, "a refused layout restore left a workspace behind")
    _ = try controller.createPane(kind: .shell, cwd: project.path) // siblings are unaffected
    controller.releaseFolderReservation(tree.path)
    try wtExpect(controller.reservedFolders().isEmpty, "the reservation was not released")
    _ = try controller.createPane(kind: .shell, cwd: tree.appendingPathComponent("src").path)
    _ = try controller.restoreWorkspaceLayout(layout)
}

@MainActor
let managedWorktreeChecks: [(String, () throws -> Void)] = [
    ("worktree low findings of the 22 September review", worktreeLowFindingChecks),
    ("worktree cleanup closes the paths that lost unshown work", worktreeCleanupGapChecks),
    ("worktree lifecycle malformed runtime state is unknown", worktreeUnknownRuntimeChecks),
    ("worktree lifecycle permission guidance respects vendor boundaries", worktreePermissionGuidanceChecks),
    ("worktree lifecycle history scope follows the recorded target only", worktreeHistoryScopeChecks),
    ("worktree lifecycle merge ignores external drivers and refuses invalid output", worktreeMergeIsolationChecks),
    ("worktree lifecycle preview isolates merge objects and reports conflicts", worktreeMergePreviewChecks),
    ("worktree lifecycle disk scan is bounded and never follows symlinks", worktreeDiskUsageChecks),
    ("worktree lifecycle recovery binds a moved tree to its creation marker", worktreeRecoveryChecks),
    ("worktree lifecycle finish scope keeps unrelated panes and unknown usage", worktreeFinishScopeChecks),
    ("managed worktree cleanup refuses a tree containing another registered worktree", managedWorktreeNestedCleanupChecks),
    ("managed worktree creation is bound to the previewed repository and path", managedWorktreeBoundCreationChecks),
    ("managed worktree creation never adopts a competing creator's tree", managedWorktreeCompetingCreatorChecks),
    ("managed worktree removal reports observed outcomes and never reruns git for a stale record", managedWorktreeRemovalOutcomeChecks),
    ("managed worktree facts keep read failures unknown", managedWorktreeFactsUncertaintyChecks),
    ("managed worktree facts measure divergence from the primary checkout with real Git", managedWorktreeDivergenceFactsChecks),
    ("workbench folder reservation refuses creation, start and restart inside a tree under removal", workbenchFolderReservationChecks),
    ("managed worktree identity, NUL-safe listing and scrubbed git environment", managedWorktreeIdentityChecks),
    ("managed worktree creation validates names, refs, paths and records the base", managedWorktreeCreationChecks),
    ("managed worktree creation reports hook failures without retry", managedWorktreeHookOutcomeChecks),
    ("managed worktree cleanup refuses live, dirty, unpushed, locked, foreign and unreviewed ignored trees", managedWorktreeCleanupChecks),
    ("managed worktree removal of a tracked tree uses Git's registry as identity and the same refusals", managedWorktreeTrackedRemovalChecks),
    ("worktree manager prune forgets only prunable entries, after the acknowledged list matches", managedWorktreePruneChecks),
    ("worktree manager branch deletion uses -d only and shows Git's refusal", managedWorktreeBranchDeletionChecks),
    ("worktree manager bulk removal proposes only passing trees and stops at the first unconfirmed outcome", worktreeBulkRemovalPlanChecks),
    ("worktree cleanup policy decision table", worktreeCleanupPolicyChecks),
    ("a merged team worktree is removable: gone upstream, build cache, honest refusals", worktreeRemovalAfterMergeChecks),
    ("managed worktree evidence is captured with delegation git facts", managedWorktreeEvidenceChecks),
]

func worktreeMergePreviewChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let tree = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/merge", baseRef: "main"))
    let folder = URL(fileURLWithPath: tree.path)
    let feature = try f.commit("feature", in: folder, contents: "feature\n")
    let target = try f.commit("target", in: f.repo, contents: "target\n")
    let status = try f.git(["status", "--porcelain"], in: folder)
    let objectCount = try f.git(["count-objects", "-v"], in: f.repo)
    let result = try f.service.mergePreview(tree, targetRef: "main")
    try wtExpect(result.hasConflicts && result.conflictedPaths == ["src/main.swift"], "conflict preview did not report the conflicting file")
    try wtExpect(result.sourceCommit == feature && result.targetCommit == target, "preview lost its exact commits")
    try wtExpect(try f.git(["count-objects", "-v"], in: f.repo) == objectCount, "preview wrote into the source object store")
    try wtExpect(try f.git(["status", "--porcelain"], in: folder) == status, "preview changed the checkout or index")
    try wtExpect(try f.git(["rev-parse", "HEAD"], in: folder) == feature, "preview moved HEAD")
    let clean = try f.service.mergePreview(tree, targetRef: feature)
    try wtExpect(!clean.hasConflicts && clean.conflictedPaths.isEmpty, "identical commits were not clean")
    let untracked = f.root.appendingPathComponent("untracked")
    _ = try f.git(["worktree", "add", "-b", "untracked", untracked.path, "main"], in: f.repo)
    let recordsBefore = try f.store.records()
    _ = try f.service.mergePreview(path: untracked.path, repositoryFolder: f.repo.path, targetRef: "main")
    try wtExpect(try f.store.records() == recordsBefore, "Predict attached an unrecorded tree")
    _ = try wtRejects("option-shaped target accepted") { _ = try f.service.mergePreview(tree, targetRef: "--help") }
}

func worktreeDiskUsageChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let dir = f.root.appendingPathComponent("usage")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: dir.appendingPathComponent("file"))
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("outside"), withDestinationURL: f.repo)
    let usage = WorktreeDiskUsage.measure(path: dir.path)
    try wtExpect(usage.isComplete && usage.fileCount == 1 && usage.logicalBytes == 4096, "disk scan followed a symlink or miscounted regular files")
    try wtExpect(!WorktreeDiskUsage.measure(path: dir.path, maximumEntries: 1).isComplete, "bounded scan claimed a complete size")
    try wtExpect(!WorktreeDiskUsage.measure(path: f.root.appendingPathComponent("absent").path).isComplete, "missing folder claimed zero bytes")
}

func worktreeRecoveryChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let record = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/move", baseRef: "main"))
    let moved = f.repo.appendingPathComponent("moved").path
    try f.git(["worktree", "move", record.path, moved], in: f.repo)
    let candidates = try f.service.recoveryCandidates(record)
    try wtExpect(candidates == [moved], "moved worktree was not identified by its creation marker")
    let recovered = try f.service.relocateRecord(record, to: moved)
    try wtExpect(recovered.id == record.id && recovered.baseCommit == record.baseCommit && recovered.parleyCreated, "recovery lost original identity or ownership")
    try wtExpect(try f.store.record(path: moved) == recovered, "recovered record was not durable")
    _ = try wtRejects("stale recovery changed the record twice") { _ = try f.service.relocateRecord(record, to: moved) }
    let gitDir = try f.git(["rev-parse", "--absolute-git-dir"], in: URL(fileURLWithPath: moved))
    try "foreign".write(toFile: gitDir + "/parley-worktree-owner", atomically: true, encoding: .utf8)
    try wtExpect(try f.service.recoveryCandidates(recovered).isEmpty, "foreign marker was adopted")
}

func worktreeFinishScopeChecks() throws {
    let root = "/tmp/parley-finish-scope"
    let inTree = WorkbenchPane(id: "inside", kind: .shell, customName: nil, terminalTitle: "", cwd: root, currentCommand: "", isActive: false, workspaceID: "mixed", isStarted: false)
    var outside = inTree; outside.id = "outside"; outside.cwd = root + "-other"
    let workspace = WorkbenchWorkspace(id: "mixed", name: "Mixed", isActive: false)
    let usage = WorktreeUsage.project(path: root, panes: [inTree, outside], workspaces: [workspace], handoffs: [], otherPaneFolders: [], otherRuntimeUnknown: false, activeTeamPaths: [])
    try wtExpect(usage.paneIDs == ["inside"] && !usage.isInactive, "stopped pane was ignored or prefix sibling was included")
    try wtExpect(usage.workspaces.first?.canCloseWholeWorkspace == false, "finish would close an unrelated pane")
    try wtExpect(usage.lastRetainedActivity == nil, "invented activity timestamp")
    let unknown = WorktreeUsage.project(path: root, panes: [], workspaces: [], handoffs: [], otherPaneFolders: [], otherRuntimeUnknown: true, activeTeamPaths: [])
    try wtExpect(!unknown.isInactive, "unknown other runtime was called inactive")
}


func worktreePermissionGuidanceChecks() throws {
    for kind in PaneKind.allCases where kind != .shell {
        let text = WorktreePermissionGuide.guidance(for: kind)
        try wtExpect(text.contains(kind.label) && text.contains("own tool approvals"), "guidance lost the selected vendor")
        try wtExpect(!text.contains("Parley's outer folder boundary"), "guidance incorrectly attributes vendor Git restrictions to Parley's control-plane boundary")
    }
}

func worktreeHistoryScopeChecks() throws {
    let path = "/tmp/recorded-worktree"
    let date = Date(timeIntervalSinceReferenceDate: 6000)
    let snapshot = DelegationGitSnapshot(capturedAt: date, folder: path, headRevision: nil, branch: nil, isDetached: false,
        dirtyPaths: [], dirtyPathCount: 0, managedWorktree: .init(path: path, branch: "feat/check", baseCommit: nil, parleyCreated: true))
    let object: [String: Any] = [
        "id": "historical", "idempotencyKey": "k", "kind": "delegate", "sourcePaneID": "source", "sourceName": "Source",
        "sourceKind": "codex", "sourceWorkspaceID": "unrelated-source", "targetPaneID": "target", "targetName": "Target",
        "targetKind": "claude", "targetWorkspaceID": "closed-target", "targetWorkspaceName": "Closed project",
        "text": "Task", "submitted": true, "state": "completed", "updatedAt": 9000, "transitions": [],
        "gitFactsAtReturn": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))]
    let handoff = try JSONDecoder().decode(RelayHandoff.self, from: JSONSerialization.data(withJSONObject: object))
    let usage = WorktreeUsage.project(path: path, panes: [], workspaces: [], handoffs: [handoff],
        otherPaneFolders: [], otherRuntimeUnknown: false, activeTeamPaths: [])
    try wtExpect(usage.workspaces.map(\.id) == ["closed-target"] && usage.lastRetainedActivity == date,
                 "history scope included a delegating source or invented a last-use timestamp")
    let nested = WorktreeUsage.project(path: path + "/nested", panes: [], workspaces: [], handoffs: [handoff],
        otherPaneFolders: [], otherRuntimeUnknown: false, activeTeamPaths: [])
    try wtExpect(nested.workspaces.isEmpty && nested.lastRetainedActivity == nil, "historical evidence was attributed to a different tree")
}

func worktreeMergeIsolationChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let flag = f.root.appendingPathComponent("driver-ran")
    try f.git(["config", "merge.hostile.driver", "touch " + flag.path], in: f.repo)
    _ = try f.commit("attributes", in: f.repo, file: ".gitattributes", contents: "*.swift merge=hostile\n")
    let record = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/driver", baseRef: "main"))
    _ = try f.commit("ours", in: f.repo, contents: "ours\n")
    _ = try f.commit("theirs", in: URL(fileURLWithPath: record.path), contents: "theirs\n")
    _ = try f.service.mergePreview(record, targetRef: "main")
    try wtExpect(!FileManager.default.fileExists(atPath: flag.path), "preview ran the repository's external merge driver")
    // Distinguish Git errors from conflicts, and reject oversized output.
    for mode in ["failed", "oversized"] {
        let executable = f.root.appendingPathComponent("preview-" + mode)
        let script = """
        #!/bin/sh
        case " $* " in
          *" merge-tree "*)
            if [ "\(mode)" = "failed" ]; then exit 128; fi
            # A builtin: the read guard lets this wrapper run but not fork.
            printf '%0210000d' 0
            exit 0 ;;
        esac
        exec /usr/bin/git "$@"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = ManagedWorktreeService(store: f.store, gitExecutable: executable, environment: ["PATH": "/usr/bin:/bin"])
        _ = try wtRejects("merge preview accepted " + mode) { _ = try service.mergePreview(record, targetRef: "main") }
    }
}


func worktreeUnknownRuntimeChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let record = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/unknown-runtime", baseRef: "main"))
    let other = f.root.appendingPathComponent("other-state.json")
    try #"{"panes":[{"id":"broken"}]}"#.write(to: other, atomically: true, encoding: .utf8)
    let result = try f.service.inspectLifecycle(record, panes: [], workspaces: [], handoffs: [], activeTeamPaths: [], otherRuntimeStateFiles: [other])
    try wtExpect(result.usage.otherRuntimeUnknown && !result.usage.isInactive,
                 "malformed other-runtime pane folders were silently ignored")
}

/// Ahead, behind and containment come from Git, not from the record: a
/// commit on the tree is one ahead, a commit on the primary is one behind,
/// and only after the primary merges the tree does it read as contained.
func managedWorktreeDivergenceFactsChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let record = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/board", baseRef: "main"))
    let tree = URL(fileURLWithPath: record.path)
    let atBase = f.service.facts(for: record)
    try wtExpect(atBase.aheadOfPrimary == 0 && atBase.behindPrimary == 0 && atBase.containedInPrimary == true
        && atBase.primaryHead == record.baseCommit, "a fresh tree at the base was not level with the primary: \(atBase)")
    _ = try f.commit("tree work", in: tree, file: "src/board.swift", contents: "let board = 1\n")
    let ahead = f.service.facts(for: record)
    try wtExpect(ahead.aheadOfPrimary == 1 && ahead.behindPrimary == 0 && ahead.containedInPrimary == false, "one tree commit was not one ahead: \(ahead)")
    _ = try f.commit("primary work", in: f.repo, file: "src/other.swift", contents: "let other = 1\n")
    let diverged = f.service.facts(for: record)
    try wtExpect(diverged.aheadOfPrimary == 1 && diverged.behindPrimary == 1 && diverged.containedInPrimary == false, "a diverged tree was misread: \(diverged)")
    try f.git(["merge", "--no-ff", "--no-edit", "--end-of-options", "feat/board"], in: f.repo)
    let merged = f.service.facts(for: record)
    try wtExpect(merged.aheadOfPrimary == 0 && merged.behindPrimary == 2 && merged.containedInPrimary == true
        && merged.primaryHead == (try f.git(["rev-parse", "HEAD"], in: f.repo)), "a merged tree was not contained and behind by the merge: \(merged)")
    // A row built from these facts reads Integrated only once the merge happened and the tree is clean.
    let before = WorktreeBoardRow.derive(record: record, facts: diverged, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    let after = WorktreeBoardRow.derive(record: record, facts: merged, panesInside: [], requester: nil, teamObjective: nil, teamState: nil)
    try wtExpect(before.state == .idle && after.state == .integrated, "board state did not follow the merge: \(before.state) then \(after.state)")
    // Removal after integration passes the existing policy on its own: HEAD is contained in the primary.
    let preview = try f.service.cleanupPreview(record, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(preview.decision == .removeTree, "an integrated, clean tree was still refused removal: \(preview.decision)")
}

/// A tree the person made with Git and then tracked has no creation marker.
/// Removal identifies it by Git's registry entry at the recorded path and
/// applies every other refusal unchanged: a clean, merged tracked tree is
/// removed with its branch kept, a dirty one is refused, and a Parley-created
/// tree whose marker is gone stays refused.
func managedWorktreeTrackedRemovalChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let treePath = f.root.appendingPathComponent("tracked-one").path
    try f.git(["worktree", "add", "-q", "-b", "tracked/one", treePath, "main"], in: f.repo)
    let tracked = try f.service.attach(existingPath: treePath, in: f.repo.path, baseRef: nil)
    try wtExpect(!tracked.parleyCreated && tracked.creationToken == nil, "attach claimed creation")
    let preview = try f.service.cleanupPreview(tracked, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(preview.decision == .removeTree, "a clean tracked tree at the base was refused: \(preview.refusals)")
    try wtExpect(!preview.facts.creationTokenVerified && preview.facts.registered, "tracked facts misreported identity")
    // The same refusals still apply to a tracked tree.
    let notes = URL(fileURLWithPath: treePath).appendingPathComponent("notes.txt")
    try "uncommitted\n".write(to: notes, atomically: true, encoding: .utf8)
    let dirty = try f.service.cleanupPreview(tracked, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(dirty.refusals.contains { $0.contains("untracked files") }, "a dirty tracked tree was not refused: \(dirty.refusals)")
    _ = try wtRejects("a dirty tracked tree was removed") {
        _ = try f.service.remove(tracked, confirmed: .removeTree, acknowledgedIgnoredPaths: dirty.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try FileManager.default.removeItem(at: notes)
    let live = try f.service.cleanupPreview(tracked, livePaneFolders: [treePath + "/src"], otherRuntimeStateFiles: [])
    try wtExpect(live.refusals.contains { $0.contains("live pane") }, "a pane inside a tracked tree was not refused: \(live.refusals)")
    // Clean again: removed through Git, record cleared, branch kept.
    let outcome = try f.service.remove(tracked, confirmed: .removeTree, acknowledgedIgnoredPaths: preview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcome.state == .removed && outcome.recordRemoved, "tracked removal did not complete: \(outcome.detail)")
    try wtExpect(!FileManager.default.fileExists(atPath: treePath), "the tracked tree's folder remains")
    try wtExpect(try f.store.record(path: treePath) == nil, "the tracked record was not cleared")
    try wtExpect(try f.git(["branch", "--list", "tracked/one"], in: f.repo).contains("tracked/one"), "the tracked tree's branch was deleted")
    let identity = try f.service.identity(of: f.repo.path)
    try wtExpect(!(try f.service.registeredWorktrees(of: identity)).contains { $0.path == GitWorktreeResolver.canonicalPath(treePath) }, "Git still registers the removed tracked tree")
    // A Parley-created tree that lost its marker is still refused: someone else may own what is at that path now.
    let created = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/marked", baseRef: "main"))
    let marker = URL(fileURLWithPath: f.repo.appendingPathComponent(".git/worktrees").path).appendingPathComponent(URL(fileURLWithPath: created.path).lastPathComponent).appendingPathComponent(ManagedWorktreeService.creationMarkerName)
    try FileManager.default.removeItem(at: marker)
    let unmarked = try f.service.cleanupPreview(created, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(unmarked.refusals.contains { $0.contains("creation marker") }, "a Parley-created tree without its marker was not refused: \(unmarked.refusals)")
}

/// Prune is Git's global prune: the preview lists every prunable entry, the
/// acknowledged list must still match, folders and branches are untouched,
/// and an entry with a folder is never prunable so it never appears.
func managedWorktreePruneChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let gone = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/gone", baseRef: "main"))
    let kept = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/kept", baseRef: "main"))
    try wtExpect(try f.service.prunePreview(in: f.repo.path).entries.isEmpty, "a repository with folders present listed prunable entries")
    _ = try wtRejects("prune ran with nothing prunable") { _ = try f.service.prune(in: f.repo.path, acknowledgedNames: []) }
    try FileManager.default.removeItem(atPath: gone.path)
    // A gone folder cannot be realpath-resolved, so Git and the record may
    // disagree about the /private prefix; compare with it stripped.
    let strip: (String) -> String = { $0.hasPrefix("/private/") ? String($0.dropFirst("/private".count)) : $0 }
    let same: (String, String) -> Bool = { strip($0) == strip($1) }
    let preview = try f.service.prunePreview(in: f.repo.path)
    try wtExpect(preview.entries.count == 1 && same(preview.entries[0].folder ?? "", gone.path) && preview.refusals.isEmpty
                 && preview.entries[0].branch == "feat/gone", "the prunable list was wrong: \(preview.entries) vs record \(gone.path)")
    _ = try wtRejects("prune ran over a list that does not match Git's dry run") { _ = try f.service.prune(in: f.repo.path, acknowledgedNames: ["feat-kept"]) }
    let outcome = try f.service.prune(in: f.repo.path, acknowledgedNames: preview.adminNames)
    try wtExpect(outcome.forgottenFolders.count == 1 && same(outcome.forgottenFolders[0], gone.path) && outcome.remaining.isEmpty
                 && outcome.forgottenBranches == ["feat/gone"], "prune did not forget the entry: \(outcome)")
    let identity = try f.service.identity(of: f.repo.path)
    let registry = try f.service.registeredWorktrees(of: identity)
    try wtExpect(!registry.contains { same($0.path, gone.path) } && registry.contains { $0.path == kept.path && !$0.isPrunable }, "prune touched the wrong entry")
    try wtExpect(FileManager.default.fileExists(atPath: kept.path), "prune deleted a folder")
    try wtExpect(try f.git(["branch", "--list", "feat/gone"], in: f.repo).contains("feat/gone"), "prune deleted the branch")
}

/// Branch deletion: merged branches go, an unmerged one is refused by Git
/// in Git's own words, a checked-out one is reported before any command,
/// names are validated, and -D never appears.
func managedWorktreeBranchDeletionChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    try f.git(["branch", "merged/one"], in: f.repo)
    let merged = try f.service.branchDeletionPreview("merged/one", in: f.repo.path)
    try wtExpect(merged.mergedIntoPrimaryHead && merged.checkedOutAt == nil && merged.commit == (try f.git(["rev-parse", "HEAD"], in: f.repo)), "a merged branch was misread: \(merged)")
    guard case let .deleted(commit) = try f.service.deleteBranch("merged/one", expectedCommit: try f.service.branchDeletionPreview("merged/one", in: f.repo.path).commit, in: f.repo.path) else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a merged branch was not deleted"]) }
    try wtExpect(commit == merged.commit && !(try f.git(["branch", "--list", "merged/one"], in: f.repo)).contains("merged/one"), "the merged branch remains")
    let tree = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/unmerged", baseRef: "main"))
    _ = try f.commit("work", in: URL(fileURLWithPath: tree.path), file: "src/w.swift", contents: "let w = 1\n")
    let checkedOut = try f.service.branchDeletionPreview("feat/unmerged", in: f.repo.path)
    try wtExpect(!checkedOut.mergedIntoPrimaryHead && checkedOut.checkedOutAt == tree.path, "a checked-out unmerged branch was misread: \(checkedOut)")
    guard case let .refused(reason) = try f.service.deleteBranch("feat/unmerged", expectedCommit: try f.service.branchDeletionPreview("feat/unmerged", in: f.repo.path).commit, in: f.repo.path) else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a checked-out branch was deleted"]) }
    try wtExpect(reason.contains("feat/unmerged"), "Git's refusal was not shown: \(reason)")
    _ = try wtRejects("Parley removed a tree with an unmerged commit") {
        _ = try f.service.remove(tree, confirmed: .removeTree, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    // A stale entry still holds its branch for Git; the preview says so and Git refuses until it is pruned.
    let held = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "feat/held", baseRef: "main"))
    try FileManager.default.removeItem(atPath: held.path)
    let stale = try f.service.branchDeletionPreview("feat/held", in: f.repo.path)
    try wtExpect(stale.heldByStaleEntry && stale.checkedOutAt != nil && stale.mergedIntoPrimaryHead, "a stale holder was not reported: \(stale)")
    guard case .refused = try f.service.deleteBranch("feat/held", expectedCommit: try f.service.branchDeletionPreview("feat/held", in: f.repo.path).commit, in: f.repo.path) else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a branch held by a stale entry was deleted"]) }
    _ = try f.service.prune(in: f.repo.path, acknowledgedNames: try f.service.prunePreview(in: f.repo.path).adminNames)
    let released = try f.service.branchDeletionPreview("feat/held", in: f.repo.path)
    try wtExpect(!released.heldByStaleEntry && released.checkedOutAt == nil, "prune did not release the branch: \(released)")
    guard case .deleted = try f.service.deleteBranch("feat/held", expectedCommit: try f.service.branchDeletionPreview("feat/held", in: f.repo.path).commit, in: f.repo.path) else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a merged branch was refused after prune"]) }
    try f.git(["worktree", "remove", "--force", tree.path], in: f.repo) // the fixture's Git, never Parley's
    guard case let .refused(unmerged) = try f.service.deleteBranch("feat/unmerged", expectedCommit: try f.service.branchDeletionPreview("feat/unmerged", in: f.repo.path).commit, in: f.repo.path) else { throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "an unmerged branch was deleted"]) }
    try wtExpect(unmerged.contains("not fully merged"), "the unmerged refusal was not Git's: \(unmerged)")
    try wtExpect(try f.git(["branch", "--list", "feat/unmerged"], in: f.repo).contains("feat/unmerged"), "an unmerged branch was deleted despite the refusal")
    _ = try wtRejects("an option-shaped branch name reached git") { _ = try f.service.branchDeletionPreview("--delete=main", in: f.repo.path) }
    _ = try wtRejects("a missing branch produced a preview") { _ = try f.service.branchDeletionPreview("no/such", in: f.repo.path) }
}

/// The bulk plan is a pure decision over fresh previews: trees that pass
/// are proposed, trees with any refusal are listed and skipped, a
/// record-only cleanup is not a removal, and the run stops at the first
/// outcome that is not a confirmed removal.
func worktreeBulkRemovalPlanChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    let clean = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "bulk/clean", baseRef: "main"))
    let dirty = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "bulk/dirty", baseRef: "main"))
    try "notes\n".write(to: URL(fileURLWithPath: dirty.path).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let gone = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "bulk/gone", baseRef: "main"))
    try FileManager.default.removeItem(atPath: gone.path)
    let items = try [clean, dirty, gone].map { WorktreeBulkRemovalPlan.Item(record: $0, preview: try f.service.cleanupPreview($0, livePaneFolders: [], otherRuntimeStateFiles: [])) }
    let plan = WorktreeBulkRemovalPlan.plan(items: items)
    try wtExpect(plan.passing.map(\.record.branch) == ["bulk/clean"], "the wrong trees passed: \(plan.passing.map(\.record.branch))")
    try wtExpect(plan.skipped.map(\.record.branch) == ["bulk/dirty", "bulk/gone"], "the wrong trees were skipped: \(plan.skipped.map(\.record.branch))")
    try wtExpect(plan.skipped[0].refusals.contains { $0.contains("untracked") }, "the dirty tree's reason was lost")
    try wtExpect(plan.skipped[1].preview.decision == .clearRecordOnly, "a gone folder was not a record-only case")
    // An unused tree (clean, at its base) passes the same preview and keeps the state it was proposed for.
    let unused = WorktreeBulkRemovalPlan.Item(record: clean, preview: try f.service.cleanupPreview(clean, livePaneFolders: [], otherRuntimeStateFiles: []), state: .unused)
    try wtExpect(unused.passes && unused.state == .unused && items[0].state == .integrated, "an unused tree did not pass the bulk plan with its state")
    let removed = try f.service.remove(clean, confirmed: .removeTree, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(WorktreeBulkRemovalPlan.shouldContinue(after: removed.state), "a confirmed removal stopped the run")
    try wtExpect(!WorktreeBulkRemovalPlan.shouldContinue(after: .uncertain), "an uncertain outcome did not stop the run")
    try wtExpect(!WorktreeBulkRemovalPlan.shouldContinue(after: .retained), "a retained tree did not stop the run")
}

/// Review of 22 September 2026, ad160850: four cleanup paths that could lose
/// work the preview did not show, each reproduced here with real Git.
func worktreeCleanupGapChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }

    // (1) Edits to files Git is told not to check are invisible to status.
    for (branch, flag) in [("gap/skip", "--skip-worktree"), ("gap/assume", "--assume-unchanged")] {
        let tree = try f.service.create(.init(repositoryFolder: f.repo.path, branch: branch, baseRef: "main"))
        let folder = URL(fileURLWithPath: tree.path)
        try f.git(["update-index", flag, "src/main.swift"], in: folder)
        try "print(2) // local edit\n".write(to: folder.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try wtExpect(try f.git(["status", "--porcelain"], in: folder).isEmpty, "\(flag) did not hide the edit from status in this Git")
        let preview = try f.service.cleanupPreview(tree, livePaneFolders: [], otherRuntimeStateFiles: [])
        try wtExpect(preview.refusals.contains { $0.contains("not to check for changes") && $0.contains("src/main.swift") },
                     "an edit hidden by \(flag) did not refuse removal: \(preview.refusals)")
    }
    // A marked file whose name begins with a combining mark is still found.
    let marked = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "gap/mark", baseRef: "main"))
    let markedFolder = URL(fileURLWithPath: marked.path)
    let combining = "\u{301}accent.txt"
    try "x\n".write(to: markedFolder.appendingPathComponent(combining), atomically: true, encoding: .utf8)
    try f.git(["add", combining], in: markedFolder)
    try f.git(["commit", "-q", "-m", "accent"], in: markedFolder)
    try f.git(["update-index", "--skip-worktree", combining], in: markedFolder)
    try "edited\n".write(to: markedFolder.appendingPathComponent(combining), atomically: true, encoding: .utf8)
    let markedPreview = try f.service.cleanupPreview(marked, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(markedPreview.facts.uncheckedPaths == [combining], "a marked name beginning with a combining mark was missed: \(markedPreview.facts.uncheckedPaths.map { Array($0.unicodeScalars) })")
    // A tree with a submodule is refused in the preview, since Git would refuse removal.
    let withModule = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "gap/module", baseRef: "main"))
    let moduleFolder = URL(fileURLWithPath: withModule.path)
    let commit = try f.git(["rev-parse", "HEAD"], in: f.repo)
    try f.git(["update-index", "--add", "--cacheinfo", "160000,\(commit),vendor/lib"], in: moduleFolder)
    try f.git(["commit", "-q", "-m", "submodule"], in: moduleFolder)
    // An empty gitlink does not stop Git removing the tree, so it is no refusal.
    try wtExpect(!(try f.service.cleanupPreview(withModule, livePaneFolders: [], otherRuntimeStateFiles: []).refusals.contains { $0.contains("submodules") }),
                 "an unpopulated gitlink refused removal")
    let library = moduleFolder.appendingPathComponent("vendor/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try f.git(["init", "-q", "-b", "main"], in: library)
    let populated = try f.service.cleanupPreview(withModule, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(populated.refusals.contains { $0.contains("submodules") }, "a tree with a populated submodule was offered for removal: \(populated.refusals)")
    _ = try wtRejects("this Git removed a worktree with a populated submodule") { try f.git(["worktree", "remove", withModule.path], in: f.repo) }
    // A sparse checkout's skip-worktree file that is not on disk holds nothing to lose.
    let sparse = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "gap/sparse", baseRef: "main"))
    try f.git(["update-index", "--skip-worktree", "src/main.swift"], in: URL(fileURLWithPath: sparse.path))
    try FileManager.default.removeItem(atPath: sparse.path + "/src/main.swift")
    let sparsePreview = try f.service.cleanupPreview(sparse, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(!sparsePreview.refusals.contains { $0.contains("not to check for changes") },
                 "an absent skip-worktree file refused removal: \(sparsePreview.refusals)")

    // (2) branch -d follows the upstream when there is one, else HEAD.
    let remote = f.root.appendingPathComponent("remote.git")
    try f.git(["init", "-q", "--bare", remote.path], in: f.root)
    try f.git(["remote", "add", "origin", remote.path], in: f.repo)
    try f.git(["checkout", "-q", "-b", "gap/pushed"], in: f.repo)
    _ = try f.commit("pushed", in: f.repo, contents: "print(3)\n")
    try f.git(["push", "-q", "-u", "origin", "gap/pushed"], in: f.repo)
    try f.git(["checkout", "-q", "-b", "gap/local"], in: f.repo)
    let localCommit = try f.commit("local", in: f.repo, contents: "print(4)\n")
    try f.git(["checkout", "-q", "main"], in: f.repo)
    let pushed = try f.service.branchDeletionPreview("gap/pushed", in: f.repo.path)
    try wtExpect(!pushed.mergedIntoPrimaryHead && pushed.upstream == "refs/remotes/origin/gap/pushed" && pushed.mergedIntoUpstream == true
                 && pushed.gitWillDelete, "a branch on its upstream but not in HEAD was not predicted deletable: \(pushed)")
    let local = try f.service.branchDeletionPreview("gap/local", in: f.repo.path)
    try wtExpect(local.upstream == nil && !local.gitWillDelete, "an unmerged branch without upstream was predicted deletable: \(local)")
    // The deletion is bound to the commit the person saw.
    try f.git(["branch", "-f", "gap/local", "main"], in: f.repo)
    _ = try wtRejects("a branch that moved since its preview was deleted") {
        _ = try f.service.deleteBranch("gap/local", expectedCommit: localCommit, in: f.repo.path)
    }
    try wtExpect(!(try f.git(["rev-parse", "--verify", "refs/heads/gap/local"], in: f.repo)).isEmpty, "the moved branch is gone")
    if case let .deleted(commit) = try f.service.deleteBranch("gap/pushed", expectedCommit: pushed.commit, in: f.repo.path) {
        try wtExpect(commit == pushed.commit, "the deleted commit was not the previewed one")
    } else {
        throw NSError(domain: "ManagedWorktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "a branch Git deletes was not deleted"])
    }

    // (3) Prune forgets what `git worktree prune` removes, not only what
    // `worktree list` marks prunable, and never a tree whose folder remains.
    let gone = f.root.appendingPathComponent("gone-tree")
    try f.git(["worktree", "add", "-q", "--detach", gone.path, "main"], in: f.repo)
    try FileManager.default.removeItem(at: gone)
    let live = f.root.appendingPathComponent("live-tree")
    try f.git(["worktree", "add", "-q", "--detach", live.path, "main"], in: f.repo)
    try "unsaved\n".write(to: live.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let liveAdmin = try f.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: live)
    let liveGitdir = try String(contentsOfFile: liveAdmin + "/gitdir", encoding: .utf8)
    try FileManager.default.removeItem(atPath: liveAdmin + "/gitdir")
    try wtExpect(!(try f.git(["worktree", "list", "--porcelain"], in: f.repo)).contains(live.lastPathComponent),
                 "this Git lists an entry whose gitdir file is missing")
    let blocked = try f.service.prunePreview(in: f.repo.path)
    try wtExpect(blocked.entries.contains { $0.adminName == live.lastPathComponent } && !blocked.refusals.isEmpty,
                 "an entry worktree list omits was not in the prune preview, or did not refuse: \(blocked)")
    _ = try wtRejects("prune ran with an entry whose folder is unknown") {
        _ = try f.service.prune(in: f.repo.path, acknowledgedNames: blocked.adminNames)
    }
    try wtExpect(FileManager.default.fileExists(atPath: liveAdmin), "the refused prune removed the live tree's admin directory")
    // A tree whose .git link is gone but whose folder remains is refused too.
    try liveGitdir.write(toFile: liveAdmin + "/gitdir", atomically: true, encoding: .utf8)
    try FileManager.default.moveItem(atPath: live.path + "/.git", toPath: f.root.path + "/live-dot-git")
    let unlinked = try f.service.prunePreview(in: f.repo.path)
    try wtExpect(unlinked.refusals.contains { $0.contains("still exists") }, "a folder that still exists did not refuse prune: \(unlinked.refusals)")
    try FileManager.default.moveItem(atPath: f.root.path + "/live-dot-git", toPath: live.path + "/.git")
    // A tree linked by a relative pointer (worktree.useRelativePaths) is still found.
    let relativeTree = f.repo.appendingPathComponent(".worktrees/relative", isDirectory: true)
    try f.git(["worktree", "add", "-q", "--detach", relativeTree.path, "main"], in: f.repo)
    let relativeAdmin = try f.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: relativeTree)
    try "gitdir: ../../.git/worktrees/\(URL(fileURLWithPath: relativeAdmin).lastPathComponent)\n".write(to: relativeTree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "/nonexistent/elsewhere/.git\n".write(toFile: relativeAdmin + "/gitdir", atomically: true, encoding: .utf8)
    let relative = try f.service.prunePreview(in: f.repo.path)
    try wtExpect(relative.refusals.contains { $0.contains("still links") }, "a tree linked by a relative pointer was not protected: \(relative.refusals)")
    try "\(relativeTree.path)/.git\n".write(toFile: relativeAdmin + "/gitdir", atomically: true, encoding: .utf8)
    try f.git(["worktree", "remove", "--force", relativeTree.path], in: f.repo) // the fixture's Git, never Parley's
    let ready = try f.service.prunePreview(in: f.repo.path)
    try wtExpect(ready.refusals.isEmpty && ready.adminNames == [gone.lastPathComponent], "the stale entry alone was not ready to prune: \(ready)")
    let pruned = try f.service.prune(in: f.repo.path, acknowledgedNames: ready.adminNames)
    try wtExpect(pruned.forgottenNames == [gone.lastPathComponent], "prune did not forget the stale entry: \(pruned)")
    try wtExpect(try f.git(["status", "--porcelain"], in: live).contains("notes.txt"), "the live tree stopped being a worktree")

    // (4) The nested-repository walk counts directories, and running out of
    // budget is a refusal in the preview, never a failed preview.
    let heavy = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "gap/heavy", baseRef: "main"))
    try "deps/\n".write(to: URL(fileURLWithPath: heavy.path).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try f.git(["add", ".gitignore"], in: URL(fileURLWithPath: heavy.path))
    try f.git(["commit", "-q", "-m", "ignore deps"], in: URL(fileURLWithPath: heavy.path))
    let deps = URL(fileURLWithPath: heavy.path).appendingPathComponent("deps")
    try FileManager.default.createDirectory(at: deps, withIntermediateDirectories: true)
    for index in 0..<60 { FileManager.default.createFile(atPath: deps.appendingPathComponent("file-\(index)").path, contents: Data()) }
    let small = ManagedWorktreeService(store: f.store, environment: ["PATH": "/usr/bin:/bin", "HOME": f.root.path], nestedDirectoryBudget: 40)
    let manyFiles = try small.cleanupPreview(heavy, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(!manyFiles.refusals.contains { $0.contains("too large") }, "files counted against the directory budget: \(manyFiles.refusals)")
    for index in 0..<60 { try FileManager.default.createDirectory(at: deps.appendingPathComponent("dir-\(index)"), withIntermediateDirectories: true) }
    let manyDirectories = try small.cleanupPreview(heavy, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(manyDirectories.refusals.contains { $0.contains("too large") }, "an over-budget walk was not a refusal in the preview: \(manyDirectories.refusals)")
}

/// Review of 22 September 2026, b1cb3901: the worktree low findings.
func worktreeLowFindingChecks() throws {
    let f = try WorktreeFixture()
    defer { f.cleanup() }
    // (1) Integrate names the branch by its full ref: Git prefers a tag.
    let argv = try WorktreeIntegration.mergeArgv(branch: "v2")
    try wtExpect(argv.last == "refs/heads/v2" && argv.contains("--end-of-options"), "Integrate's argv does not name the branch's full ref: \(argv)")
    _ = try wtRejects("an option-shaped branch reached Integrate's argv") { _ = try WorktreeIntegration.mergeArgv(branch: "--upload-pack=x") }
    // (2) A tree on branch v2 beside a tag v2 still reads its branch and upstream.
    let tree = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "v2", baseRef: "main"))
    let folder = URL(fileURLWithPath: tree.path)
    let branchCommit = try f.commit("v2 work", in: folder, contents: "print(5)\n")
    try f.git(["tag", "v2", "main"], in: f.repo)
    try wtExpect(try f.git(["rev-parse", argv.last!], in: f.repo) == branchCommit
                 && (try f.git(["rev-parse", "v2"], in: f.repo)) != branchCommit, "the full ref did not resolve to the branch over the tag")
    let remote = f.root.appendingPathComponent("low-remote.git")
    try f.git(["init", "-q", "--bare", remote.path], in: f.root)
    try f.git(["remote", "add", "origin", remote.path], in: f.repo)
    try f.git(["push", "-q", "-u", "origin", "refs/heads/v2:refs/heads/v2"], in: folder)
    let facts = f.service.facts(for: tree)
    try wtExpect(facts.currentBranch == "v2" && facts.hasUpstream == true, "a branch sharing a tag's name lost its name or upstream: \(facts)")
    try wtExpect(try f.service.cleanupPreview(tree, livePaneFolders: [], otherRuntimeStateFiles: []).facts.hasUpstream, "cleanup read no upstream for v2")
    // (4) The bulk label comes from fresh facts.
    try wtExpect(WorktreeBulkRemovalPlan.freshState(record: tree, facts: facts) == nil, "a tree with its own unmerged commit was labelled for bulk removal")
    let unused = try f.service.create(.init(repositoryFolder: f.repo.path, branch: "low/unused", baseRef: "main"))
    try wtExpect(WorktreeBulkRemovalPlan.freshState(record: unused, facts: f.service.facts(for: unused)) == .unused, "a clean tree at its base did not read Unused")
    try "draft\n".write(to: URL(fileURLWithPath: unused.path).appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
    try wtExpect(WorktreeBulkRemovalPlan.freshState(record: unused, facts: f.service.facts(for: unused)) == nil, "a tree with an untracked file read Unused")
    // (6) A path that begins with a combining mark survives the status parse.
    let combining = "\u{301}accent.txt"
    try "x\n".write(to: URL(fileURLWithPath: unused.path).appendingPathComponent(combining), atomically: true, encoding: .utf8)
    let untracked = try f.service.cleanupPreview(unused, livePaneFolders: [], otherRuntimeStateFiles: []).facts.untrackedPaths
    try wtExpect(untracked.contains(combining), "a name beginning with a combining mark was cut: \(untracked.map { Array($0.unicodeScalars) })")
    // (7) A present tree needs no recovery scan.
    try wtExpect(try f.service.recoveryCandidates(tree).isEmpty, "a present tree was offered a relocation")
    // (3) A confirmed record-only clear never becomes a removal. A tracked
    // tree has no creation marker, so only this binding catches it.
    let trackedPath = f.root.appendingPathComponent("low-tracked")
    try f.git(["worktree", "add", "-q", "-b", "low/vanished", trackedPath.path, "main"], in: f.repo)
    let vanished = try f.service.attach(existingPath: trackedPath.path, in: f.repo.path, baseRef: nil)
    try f.git(["worktree", "remove", vanished.path], in: f.repo)
    try wtExpect(try f.service.cleanupPreview(vanished, livePaneFolders: [], otherRuntimeStateFiles: []).decision == .clearRecordOnly,
                 "the vanished tree was not a record-only case")
    try f.git(["worktree", "add", "-q", vanished.path, "low/vanished"], in: f.repo)
    let reappeared = try wtRejects("a confirmed record-only clear removed a tree that came back") {
        _ = try f.service.remove(vanished, confirmed: .clearRecordOnly, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    }
    try wtExpect(reappeared.contains("again") && FileManager.default.fileExists(atPath: vanished.path), "the reappeared tree was touched: \(reappeared)")
    // (5) A permission denial is unknown, never Missing.
    let parent = folder.deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent)
    let denied = f.service.facts(for: tree)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
    try wtExpect(denied.registered == nil, "a folder behind a permission denial read as \(String(describing: denied.registered)), not unknown")
    // (1) Last, because it changes main: run Integrate's exact argv in the
    // primary checkout. With the tag v2 beside the branch v2, the merge must
    // bring in the branch's commit (a short name would have merged the tag).
    try wtExpect(argv.first == "/usr/bin/git", "Integrate no longer runs the fixed Git: \(argv)")
    try f.git(Array(argv.dropFirst()), in: f.repo)
    // The tag points at main, so merging it would make no commit and no HEAD^2.
    let merged = try? f.git(["rev-parse", "--verify", "--quiet", "HEAD^2"], in: f.repo)
    try wtExpect(merged == branchCommit,
                 "Integrate's argv merged \(merged ?? "nothing (the tag v2, already in main)") rather than the branch v2")
}
