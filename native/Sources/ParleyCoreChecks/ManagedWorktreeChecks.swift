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
    let reattached = try fixture.service.attach(existingPath: second.path, in: fixture.repo.path, baseRef: nil)
    try wtExpect(!reattached.parleyCreated && !fixture.service.creationTokenMatches(second), "a recreated tree at the same path inherited Parley ownership")
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
        do { _ = try fixture.service.remove(record, acknowledgedIgnoredPaths: acknowledged, livePaneFolders: panes, otherRuntimeStateFiles: states); return "" }
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
    // An upstream that is configured but cannot be counted is unknown, never "nothing unpushed".
    try fixture.git(["config", "branch.feat/clean.remote", "origin"], in: tree)
    try fixture.git(["config", "branch.feat/clean.merge", "refs/heads/feat/clean"], in: tree)
    let unknownUpstream = try preview()
    try wtExpect(unknownUpstream.facts.statusUncertain && unknownUpstream.refusals.contains { $0.contains("could not be read") },
        "a broken upstream was treated as pushed: \(unknownUpstream.refusals)")
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
    try wtExpect(try fixture.service.cleanupPreview(attached, livePaneFolders: [], otherRuntimeStateFiles: []).refusals.contains { $0.contains("not created by Parley") },
        "a user-owned tree was cleanable")
    try "late".write(to: tree.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
    try wtExpect(removal(acknowledged: [".env", "build/"]).contains("untracked"), "removal did not revalidate before mutating")
    try FileManager.default.removeItem(at: tree.appendingPathComponent("late.txt"))

    // Success: tree gone, record gone, branch retained, nothing forced.
    let outcome = try fixture.service.remove(record, acknowledgedIgnoredPaths: [".env", "build/"], livePaneFolders: [], otherRuntimeStateFiles: [])
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
    for mutate in [{ (x: inout WorktreeCleanupFacts) in x.parleyCreated = false }, { $0.creationTokenVerified = false }, { $0.registered = false }, { $0.locked = true }, { $0.prunable = true },
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
        _ = try fixture.service.remove(outer, acknowledgedIgnoredPaths: preview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
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
        _ = try fixture.service.remove(second, acknowledgedIgnoredPaths: corruptPreview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
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
        _ = try fixture.service.remove(second, acknowledgedIgnoredPaths: deletedPreview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
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
    let outcomeA = try hookError.service.remove(first, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeA.state == .removed && outcomeA.recordRemoved && !FileManager.default.fileExists(atPath: first.path) && outcomeA.detail.contains("exit status 1"),
        "a nonzero exit with the tree gone was not reported as removed: \(outcomeA)")

    let noop = try fixture.wrappedService(mode: "remove-noop")
    let second = try mergedTree("feat/rm-b")
    let outcomeB = try noop.service.remove(second, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeB.state == .retained && !outcomeB.recordRemoved && FileManager.default.fileExists(atPath: second.path)
        && (try fixture.store.records().contains { $0.id == second.id }), "a success status with the tree still registered was not reported as retained: \(outcomeB)")

    let slow = try fixture.wrappedService(mode: "remove-timeout", mutationTimeout: 1)
    let third = try mergedTree("feat/rm-c")
    let outcomeC = try slow.service.remove(third, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(outcomeC.state == .removed && outcomeC.recordRemoved && outcomeC.detail.contains("timed out"), "a timed-out removal was not reconciled: \(outcomeC)")

    // Record-only cleanup: the tree vanished outside Parley; the preview says
    // so, removal clears the record and the fake git logs no removal call.
    let stale = try mergedTree("feat/rm-d")
    try fixture.git(["worktree", "remove", stale.path], in: fixture.repo)
    let logged = try fixture.wrappedService(mode: "remove-unlisted")
    let stalePreview = try logged.service.cleanupPreview(stale, livePaneFolders: [], otherRuntimeStateFiles: [])
    try wtExpect(stalePreview.refusals.isEmpty && stalePreview.decision == .clearRecordOnly, "an already-removed tree was not offered as record-only cleanup: \(stalePreview.refusals)")
    let outcomeD = try logged.service.remove(stale, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
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
        _ = try fixture.service.remove(occupied, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
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
        _ = try fixture.service.remove(hidden, acknowledgedIgnoredPaths: [], livePaneFolders: [], otherRuntimeStateFiles: [])
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
    try controller.stopPaneProcess(agent.id)
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
    ("managed worktree cleanup refuses a tree containing another registered worktree", managedWorktreeNestedCleanupChecks),
    ("managed worktree creation is bound to the previewed repository and path", managedWorktreeBoundCreationChecks),
    ("managed worktree creation never adopts a competing creator's tree", managedWorktreeCompetingCreatorChecks),
    ("managed worktree removal reports observed outcomes and never reruns git for a stale record", managedWorktreeRemovalOutcomeChecks),
    ("managed worktree facts keep read failures unknown", managedWorktreeFactsUncertaintyChecks),
    ("workbench folder reservation refuses creation, start and restart inside a tree under removal", workbenchFolderReservationChecks),
    ("managed worktree identity, NUL-safe listing and scrubbed git environment", managedWorktreeIdentityChecks),
    ("managed worktree creation validates names, refs, paths and records the base", managedWorktreeCreationChecks),
    ("managed worktree creation reports hook failures without retry", managedWorktreeHookOutcomeChecks),
    ("managed worktree cleanup refuses live, dirty, unpushed, locked, foreign and unreviewed ignored trees", managedWorktreeCleanupChecks),
    ("worktree cleanup policy decision table", worktreeCleanupPolicyChecks),
    ("managed worktree evidence is captured with delegation git facts", managedWorktreeEvidenceChecks),
]
