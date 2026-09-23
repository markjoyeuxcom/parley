import Foundation
import ParleyCore

private func grExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "GitReadBoundary", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func grRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "GitReadBoundary", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// A repository whose own configuration names programs for Git to start,
/// the way a container pane or an agent could leave it: clean filters from
/// `.git/info/attributes` (one run through the shell, one executed directly,
/// one whose name contains `=` and is marked required, one long-running
/// `process` filter), a textconv driver,
/// an external diff, an fsmonitor hook and a filter inside a populated
/// submodule. Every program only creates a marker file, so a Parley read
/// that ran one leaves the marker behind.
private struct PlantedRepository {
    let root: URL
    let repo: URL
    let linked: URL
    let markers: URL
    let environment: [String: String]
    let store: ManagedWorktreeStore
    let service: ManagedWorktreeService
    let record: ManagedWorktreeRecord

    init() throws {
        let root = URL(fileURLWithPath: "/tmp/parley-gr-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        self.root = root
        repo = root.appendingPathComponent("repo", isDirectory: true)
        markers = root.appendingPathComponent("markers", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let submoduleSource = root.appendingPathComponent("sub", isDirectory: true)
        for folder in [repo, markers, home, submoduleSource] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // HOME is private so the person's own ~/.gitconfig never takes part.
        environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        store = ManagedWorktreeStore(file: root.appendingPathComponent("app/managed-worktrees.json"))
        service = ManagedWorktreeService(store: store, environment: environment)

        try Self.git(["init", "-q", "-b", "main"], in: submoduleSource, home: home)
        try "s\n".write(to: submoduleSource.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "s.txt"], in: submoduleSource, home: home)
        try Self.git(["commit", "-q", "-m", "submodule"], in: submoduleSource, home: home)

        try Self.git(["init", "-q", "-b", "main"], in: repo, home: home)
        for (name, contents) in [("a.txt", "hello\n"), ("b.txt", "b\n"), ("c.txt", "direct\n"), ("d.txt", "proc\n")] {
            try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try Self.git(["add", "a.txt", "b.txt", "c.txt", "d.txt"], in: repo, home: home)
        try Self.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleSource.path, "sub"], in: repo, home: home)
        try Self.git(["commit", "-q", "-m", "initial"], in: repo, home: home)
        // The linked tree is created before anything is planted, so its own
        // checkout runs nothing.
        record = try service.create(.init(repositoryFolder: repo.path, branch: "feat/planted", baseRef: "main"))
        linked = URL(fileURLWithPath: record.path, isDirectory: true)

        func script(_ name: String) throws -> String {
            let file = root.appendingPathComponent(name)
            try "#!/bin/sh\n/usr/bin/touch \(markers.path)/\(name)\n/bin/cat\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        let shellFilter = "/usr/bin/touch \(markers.path)/shell-filter; /bin/cat"
        for (key, value) in [
            ("filter.evil.clean", shellFilter),
            ("filter.evil.smudge", shellFilter),
            ("filter.a=b.clean", "/usr/bin/touch \(markers.path)/equals-filter; /bin/cat"),
            ("filter.a=b.required", "true"),
            ("filter.direct.clean", try script("direct-filter")),
            ("filter.proc.process", "/usr/bin/touch \(markers.path)/process-filter; /bin/cat"),
            ("diff.evil.textconv", "/usr/bin/touch \(markers.path)/textconv; /bin/cat"),
            ("diff.external", try script("external-diff")),
            ("core.fsmonitor", try script("fsmonitor")),
        ] {
            try Self.git(["config", key, value], in: repo, home: home)
        }
        let info = repo.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try "a.txt filter=evil diff=evil\nb.txt filter=a=b\nc.txt filter=direct\nd.txt filter=proc\n"
            .write(to: info.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)
        let submodule = repo.appendingPathComponent("sub", isDirectory: true)
        try Self.git(["config", "filter.subevil.clean", "/usr/bin/touch \(markers.path)/submodule-filter; /bin/cat"], in: submodule, home: home)
        let submoduleInfo = repo.appendingPathComponent(".git/modules/sub/info", isDirectory: true)
        try FileManager.default.createDirectory(at: submoduleInfo, withIntermediateDirectories: true)
        try "* filter=subevil\n".write(to: submoduleInfo.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)

        // Same-size edits with a later modification time: Git must compare
        // content, which is exactly when it runs a clean filter.
        let later = Date().addingTimeInterval(30)
        for (file, contents) in [
            (repo.appendingPathComponent("a.txt"), "jello\n"),
            (repo.appendingPathComponent("b.txt"), "c\n"),
            (repo.appendingPathComponent("c.txt"), "dir3ct\n"),
            (repo.appendingPathComponent("d.txt"), "prok\n"),
            (submodule.appendingPathComponent("s.txt"), "t\n"),
        ] {
            try contents.write(to: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
        }
        // The linked tree keeps its content but not its recorded stat data,
        // so its status (and git worktree remove's own status) compares
        // content too.
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: linked.appendingPathComponent(name).path)
        }
        try clearMarkers()
    }

    func clearMarkers() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: markers.path) {
            try FileManager.default.removeItem(at: markers.appendingPathComponent(name))
        }
    }

    func ranPrograms() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []).sorted()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func git(_ arguments: [String], in folder: URL, home: URL) throws {
        let output = try ProcessCommandRunner(timeout: 20).run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", folder.path, "-c", "user.name=Check", "-c", "user.email=check@example.invalid"] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"]
        )
        guard output.status == 0 else {
            throw NSError(domain: "GitReadBoundary", code: 2, userInfo: [NSLocalizedDescriptionKey: "setup git \(arguments.joined(separator: " ")) failed: \(output.stderrText)"])
        }
    }
}

/// H1 of the 22 September 2026 review: Parley's own Git reads ran whatever
/// a repository's configuration named. Every read Parley starts on this Mac
/// is exercised against planted programs; none may run, and each read must
/// still report the repository correctly.
func checkHostGitReadsNeverRunPlantedRepositoryCommands() throws {
    let fixture = try PlantedRepository()
    defer { fixture.cleanup() }
    var ran: [String] = []
    func read(_ name: String, _ body: () throws -> Void) throws {
        try fixture.clearMarkers()
        try body()
        let programs = fixture.ranPrograms()
        if !programs.isEmpty { ran.append("\(name) ran \(programs.joined(separator: ", "))") }
    }

    try read("delegation Git facts") {
        let facts = try grRequire(DelegationGitSnapshotCapture(environment: fixture.environment).snapshot(in: fixture.repo.path),
                                  "delegation facts produced no snapshot for a repository")
        try grExpect(facts.isAvailable, "delegation facts were unavailable: \(facts.summary)")
        try grExpect(["a.txt", "b.txt", "c.txt", "d.txt"].allSatisfy(facts.dirtyPaths.contains), "delegation facts missed an edited path: \(facts.dirtyPaths)")
    }
    try read("pane Git context") {
        let context = try grRequire(GitProjectContextResolver(environment: fixture.environment).context(in: fixture.repo.path),
                                    "the pane Git context could not read the repository")
        try grExpect(context.branch == "main" && context.isDirty, "the pane Git context misread the repository: \(context)")
    }
    try read("worktree discovery") {
        _ = try grRequire(GitWorktreeResolver(environment: fixture.environment).repository(in: fixture.repo.path),
                          "worktree discovery could not read the repository")
    }
    try read("worktree board facts") {
        let facts = fixture.service.facts(forTreeAt: GitWorktreeResolver.canonicalPath(fixture.repo.path), id: "primary", expectedCommonDirectory: nil)
        try grExpect(facts.changedPathCount != nil, "the worktree board could not count changed paths")
    }
    try read("context Git Diff") {
        let part = try ContextPackBuilder(environment: fixture.environment).gitDiff(in: fixture.repo.path)
        try grExpect(part.text.contains("+jello") && part.text.contains("+dir3ct"), "context Git Diff lost the edits:\n\(part.text)")
    }
    try read("review draft") {
        let draft = try ReviewDraftBuilder(environment: fixture.environment).changes(in: fixture.repo.path)
        try grExpect(draft.text.contains("+jello"), "the review draft lost the edits:\n\(draft.text)")
    }
    try read("container Git access") {
        _ = try grRequire(ContainerGitAccess.inspect(folder: fixture.linked.path), "container Git access did not recognise the linked tree")
    }
    try read("merge preview") {
        let preview = try fixture.service.mergePreview(fixture.record, targetRef: "main")
        try grExpect(!preview.hasConflicts, "an unchanged tree predicted conflicts")
    }
    try read("worktree cleanup preview and removal") {
        let preview = try fixture.service.cleanupPreview(fixture.record, livePaneFolders: [], otherRuntimeStateFiles: [])
        guard case .removeTree = preview.decision else {
            throw NSError(domain: "GitReadBoundary", code: 1, userInfo: [NSLocalizedDescriptionKey: "a clean linked tree was not removable: \(preview.decision)"])
        }
        let outcome = try fixture.service.remove(fixture.record, confirmed: .removeTree, acknowledgedIgnoredPaths: preview.ignoredPaths, livePaneFolders: [], otherRuntimeStateFiles: [])
        try grExpect(outcome.state == .removed, "the linked tree was not removed: \(outcome.detail)")
    }
    try grExpect(ran.isEmpty, "Parley's host Git reads ran repository-planted programs:\n" + ran.joined(separator: "\n"))
}

/// The listing of filter drivers and the read are two processes, and a
/// container keeps running between them. A driver planted after the listing,
/// or one the overrides never named, must still not run: the guard refuses
/// every fork whatever the configuration says by then.
func checkGitReadGuardStopsDriversAddedAfterTheListing() throws {
    let fixture = try PlantedRepository()
    defer { fixture.cleanup() }
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let environment = GitReadBoundary.environment(fixture.environment)
    let runner = ProcessCommandRunner(timeout: 10)
    let listed = GitReadBoundary.neutralizingFilters(in: fixture.repo.path, git: git, environment: environment, runner: runner)
    try grExpect(listed["GIT_CONFIG_COUNT"] != nil, "the planted drivers were not listed for neutralisation")

    // The race: a new driver and attribute appear after the listing.
    let late = fixture.root.appendingPathComponent("late-filter")
    try "#!/bin/sh\n/usr/bin/touch \(fixture.markers.path)/late-filter\n/bin/cat\n".write(to: late, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: late.path)
    let config = fixture.repo.appendingPathComponent(".git/config")
    let original = try String(contentsOf: config, encoding: .utf8)
    try (original + "[filter \"late\"]\n\tclean = \(late.path)\n\trequired = false\n").write(to: config, atomically: true, encoding: .utf8)
    let attributes = fixture.repo.appendingPathComponent(".git/info/attributes")
    try "a.txt filter=late\nc.txt filter=late\n".write(to: attributes, atomically: true, encoding: .utf8)
    try fixture.clearMarkers()

    let status = try GitReadBoundary.run(git: git,
        arguments: ["-C", fixture.repo.path, "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "-z"] + GitReadBoundary.statusArguments,
        environment: listed, runner: runner)
    try grExpect(fixture.ranPrograms().isEmpty, "a driver added after the listing ran: \(fixture.ranPrograms())")
    try grExpect(status.status == 0, "a status whose late filter could not fork failed outright: \(status.stderrText)")
    // With no overrides at all, the guard alone still stops every program.
    for arguments in [["status", "--porcelain=v2", "-z"], ["diff", "--no-ext-diff"]] {
        _ = try GitReadBoundary.run(git: git, arguments: ["-C", fixture.repo.path] + arguments, environment: environment, runner: runner)
    }
    try grExpect(fixture.ranPrograms().isEmpty, "the guard alone let a planted program run: \(fixture.ranPrograms())")
}

/// The boundary's own pieces: a fixed script with Git as a positional
/// parameter, an environment with nothing inherited that could steer Git or
/// the guard's shell, and driver names written back exactly.
func checkGitReadBoundaryInvocationEnvironmentAndDriverNames() throws {
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let hostile = "/tmp/it's $(touch x); `y`"
    let invocation = GitReadBoundary.invocation(git: git, arguments: ["-C", hostile, "status"])
    try grExpect(invocation.executable.path == "/bin/bash", "the guard is not the fixed /bin/bash")
    try grExpect(invocation.arguments == ["-c", #"ulimit -H -S -u 1 && exec "$@""#, "parley-git-read", "/usr/bin/git", "-C", hostile, "status"],
                 "the guard's argv changed: \(invocation.arguments)")
    try grExpect(!GitReadBoundary.script.contains("/usr/bin/git") && !GitReadBoundary.script.contains(hostile),
                 "Git's path or an argument reached the guard's script text")
    try grExpect(GitReadBoundary.gitArguments(inInvocation: invocation.arguments) == ["-C", hostile, "status"],
                 "the Git arguments could not be read back from a guarded invocation")
    try grExpect(GitReadBoundary.gitArguments(inInvocation: ["-C", "/x", "status"]) == nil, "an unguarded argv was read as guarded")

    let environment = GitReadBoundary.environment([
        "PATH": "/usr/bin:/bin", "HOME": "/Users/someone",
        "GIT_DIR": "/elsewhere", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "/tmp/hook",
        "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='/tmp/hook'", "GIT_EXTERNAL_DIFF": "/tmp/diff",
        "BASH_ENV": "/tmp/startup", "BASH_FUNC_ulimit%%": "() { :; }", "ENV": "/tmp/env", "SHELLOPTS": "noexec", "BASHOPTS": "x", "CDPATH": "/tmp",
    ])
    try grExpect(environment["PATH"] == "/usr/bin:/bin" && environment["HOME"] == "/Users/someone", "the read environment lost PATH or HOME")
    for removed in ["GIT_DIR", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS", "GIT_EXTERNAL_DIFF",
                    "BASH_ENV", "BASH_FUNC_ulimit%%", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH"] {
        try grExpect(environment[removed] == nil, "the read environment kept \(removed)")
    }
    for (key, value) in ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_PAGER": "cat", "PAGER": "cat", "LC_ALL": "C"] {
        try grExpect(environment[key] == value, "the read environment did not set \(key)=\(value)")
    }

    let names = Data((["core.bare", "filter.lfs.clean", "filter.lfs.process", "filter.lfs.required", "filter.a=b.clean", "filter.Mixed Case.smudge",
                       "filter.dotted.name.clean", "filter.nosub", "diff.evil.textconv", "filter.bad\u{7}.clean"].joined(separator: "\u{0}") + "\u{0}").utf8)
        + Data("filter.".utf8) + Data([0xff]) + Data(".clean\u{0}".utf8)
    let drivers = GitReadBoundary.filterDrivers(inConfigNames: names)
    try grExpect(drivers == ["lfs", "a=b", "Mixed Case", "dotted.name"], "driver names were not read back exactly: \(drivers)")
    let many = Data((0..<100).map { "filter.d\($0).clean" }.joined(separator: "\u{0}").utf8)
    try grExpect(GitReadBoundary.filterDrivers(inConfigNames: many).count == GitReadBoundary.maximumNeutralizedDrivers, "the driver cap did not hold")

    let overrides = GitReadBoundary.overrides(disabling: ["lfs", "a=b"])
    try grExpect(overrides["GIT_CONFIG_COUNT"] == "8", "two drivers did not produce eight overrides")
    try grExpect(overrides["GIT_CONFIG_KEY_4"] == "filter.a=b.clean" && overrides["GIT_CONFIG_VALUE_4"] == ""
                 && overrides["GIT_CONFIG_KEY_7"] == "filter.a=b.required" && overrides["GIT_CONFIG_VALUE_7"] == "false",
                 "a driver containing '=' was not overridden exactly: \(overrides)")
    try grExpect(GitReadBoundary.overrides(disabling: []).isEmpty, "no drivers still produced overrides")
}

/// A container pane's delegations record that Parley ran no Git, instead of
/// running it on the agent's cue; host panes keep their facts.
func checkContainerPaneDelegationsRecordGitFactsNotCaptured() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-gr-broker-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind, cwd: String, container: Bool) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: cwd, currentCommand: "x", isActive: false,
                      workspaceID: "@git", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Git",
                      inputAvailable: true,
                      containerConfiguration: container ? ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
                          daemonID: "daemon", imageID: "sha256:" + String(repeating: "a", count: 64), imageName: "image", legacyCodexSandbox: false) : nil)
    }
    let lead = pane("%lead", .claude, cwd: "/private/lead", container: false)
    let boxed = pane("%boxed", .codex, cwd: "/private/boxed", container: true)
    let host = pane("%host", .agy, cwd: "/private/host", container: false)
    let leadToken = try credentials.token(for: lead.id)
    let boxedToken = try credentials.token(for: boxed.id)
    let hostToken = try credentials.token(for: host.id)
    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        func append(_ folder: String) { lock.withLock { recorded.append(folder) } }
        var folders: [String] { lock.withLock { recorded } }
    }
    let captured = Captured()
    let reference = Date(timeIntervalSinceReferenceDate: 9_000)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [lead, boxed, host] },
        paste: { _, _ in },
        submit: { _, _ in },
        gitFacts: { folder in
            captured.append(folder)
            return DelegationGitSnapshot(capturedAt: reference, folder: folder, headRevision: nil, branch: "main", isDetached: false, dirtyPaths: [], dirtyPathCount: 0)
        },
        clock: { reference },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
    )

    let toContainer = broker.handleDelegate(token: leadToken, target: boxed.id, text: "Work in the container.", idempotencyKey: "container-git-1")
    let containerID = try grRequire(toContainer.body.handoffID, "the delegation to a container pane returned no id")
    try grExpect(broker.handleDelegationResult(token: boxedToken, handoffID: containerID, text: "Done.", succeeded: true).status == 200,
                 "a container pane's done was refused")
    let containerHandoff = try grRequire(broker.handoffs().first(where: { $0.id == containerID }), "the container delegation disappeared")
    for (moment, facts) in [("delegation", containerHandoff.gitFactsAtDelegation), ("return", containerHandoff.gitFactsAtReturn)] {
        let snapshot = try grRequire(facts, "no Git facts record at \(moment) for a container pane")
        try grExpect(snapshot.notCapturedReason == DelegationGitSnapshot.containerPaneReason && !snapshot.isAvailable
                     && snapshot.dirtyPaths.isEmpty && snapshot.headRevision == nil && snapshot.folder == "/private/boxed",
                     "the container pane's \(moment) record was not an honest not-captured record: \(snapshot)")
        try grExpect(snapshot.summary == "Git facts not captured: Parley does not run Git on this Mac in a container pane's folder",
                     "the not-captured summary changed: \(snapshot.summary)")
    }
    try grExpect(DelegationGitFacts.compare(delegation: containerHandoff.gitFactsAtDelegation, returned: containerHandoff.gitFactsAtReturn) == nil,
                 "two not-captured records produced a path comparison")
    try grExpect(captured.folders.isEmpty, "Git ran for a container pane's folder: \(captured.folders)")

    let toHost = broker.handleDelegate(token: leadToken, target: host.id, text: "Work on the host.", idempotencyKey: "container-git-2")
    let hostID = try grRequire(toHost.body.handoffID, "the delegation to a host pane returned no id")
    _ = broker.handleDelegationResult(token: hostToken, handoffID: hostID, text: "Done.", succeeded: true)
    let hostHandoff = try grRequire(broker.handoffs().first(where: { $0.id == hostID }), "the host delegation disappeared")
    try grExpect(hostHandoff.gitFactsAtDelegation?.isAvailable == true && hostHandoff.gitFactsAtReturn?.isAvailable == true,
                 "a host pane lost its Git facts")
    try grExpect(captured.folders == ["/private/host", "/private/host"], "host capture did not read the host pane's folder twice")

    // Older records decode without the field.
    var legacy = try grRequire(try JSONSerialization.jsonObject(with: JSONEncoder().encode(containerHandoff.gitFactsAtReturn)) as? [String: Any],
                               "could not build a legacy snapshot")
    try grExpect(legacy["notCapturedReason"] as? String == DelegationGitSnapshot.containerPaneReason, "the not-captured reason was not stored")
    legacy.removeValue(forKey: "notCapturedReason")
    let decoded = try JSONDecoder().decode(DelegationGitSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
    try grExpect(decoded.notCapturedReason == nil, "a snapshot without the field did not decode as captured")
}

/// The person sees what a container can change and what Parley's own Git
/// does about it, in the container review, the Worktrees window and Help.
func checkGitReadDisclosuresNameTheContainerExposure() throws {
    for phrase in ["the container can change that repository's Git configuration, hooks and attributes",
                   "Parley records no Git facts for this pane's delegations", "cannot start another program",
                   "Git that you or a host pane run there later, and Parley's worktree actions, use whatever configuration the container left"] {
        try grExpect(GitReadBoundary.containerDisclosure.contains(phrase), "the container review disclosure lost: \(phrase)")
    }
    for phrase in ["filters and diff drivers off", "cannot start another program", "container panes using this repository",
                   "New Worktree, Remove, Prune, Delete branch and Integrate run Git itself"] {
        try grExpect(GitReadBoundary.worktreesDisclosure.contains(phrase), "the Worktrees window disclosure lost: \(phrase)")
    }
    try grExpect(!ParleyHelpGuide.matching("Git facts not captured container").isEmpty, "Help does not explain a container pane's missing Git facts")
    try grExpect(!ParleyHelpGuide.matching("filters diff drivers cannot start another program").isEmpty, "Help does not describe Parley's guarded Git reads")
}

@MainActor let gitReadBoundaryChecks: [(String, () throws -> Void)] = [
    ("host git reads never run planted repository commands", checkHostGitReadsNeverRunPlantedRepositoryCommands),
    ("git read guard stops drivers added after the listing", checkGitReadGuardStopsDriversAddedAfterTheListing),
    ("git read boundary invocation, environment and driver names", checkGitReadBoundaryInvocationEnvironmentAndDriverNames),
    ("container pane delegations record git facts not captured", checkContainerPaneDelegationsRecordGitFactsNotCaptured),
    ("git read disclosures name the container exposure", checkGitReadDisclosuresNameTheContainerExposure),
]
