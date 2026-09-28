import Foundation
import ParleyCore

// Low findings in team sessions and container panes, from the review of
// 22 September 2026 (5d1519a9).

private func lowExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "TeamContainerLow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func nativeSource(_ file: String) throws -> SwiftSourceReader {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ParleyNative").appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
}

/// The image check ran in a Task holding a copy of the view, and compared the
/// view's `let` properties against copies of themselves: a Claude image check
/// still landed after the review switched to Codex, and `ContainerConfiguration`
/// has no vendor to catch it at launch. Every stored input of the view must be
/// part of `checkInputs`, a change to it must advance `checkRevision`, and a
/// result is applied only under the revision the check began with.
func checkContainerImageCheckDiscardsChangedInputs() throws {
    let reader = try nativeSource("ContainerPaneViews.swift")
    let text = reader.text
    guard let start = text.range(of: "struct ContainerLaunchOptionsView: View {") else {
        throw NSError(domain: "TeamContainerLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "ContainerLaunchOptionsView was not found"])
    }
    guard let body = reader.balanced(at: text.index(before: start.upperBound)) else {
        throw NSError(domain: "TeamContainerLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "ContainerLaunchOptionsView's body is unbalanced"])
    }
    func member(_ pattern: String) -> Substring? {
        guard let found = body.range(of: pattern) else { return nil }
        let open = body[found.upperBound...].firstIndex(of: "{") ?? found.upperBound
        return body[open...].first == "{" ? reader.balanced(at: open) : nil
    }
    guard let inputs = member("private var checkInputs: ") else {
        throw NSError(domain: "TeamContainerLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "the view has no checkInputs describing what a check's result depends on"])
    }
    // Stored properties at member level: a declaration with no accessor block.
    let declaration = try NSRegularExpression(pattern: "(?m)^    (?:@\\w+(?:\\([^)\\n]*\\))?\\s+)*(?:private\\s+|fileprivate\\s+)?(?:let|var) (\\w+)\\s*[:=][^\\n{]*$")
    let string = String(body)
    let stored = declaration.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
        Range($0.range(at: 1), in: string).map { String(string[$0]) }
    }
    try lowExpect(stored.contains("vendor") && stored.contains("image"), "the view's stored properties were not read: \(stored)")
    // Neither an input of a check nor part of its result: the model, the
    // result itself and its presentation, and fixed presentation choices.
    let notInputs: Set<String> = ["model", "configuration", "checking", "message", "checkRevision", "onBypassChange", "showsToggle"]
    let identifier = try NSRegularExpression(pattern: "(?<![.\\w])\\w+\\b")
    let inputsString = String(inputs)
    let named = Set(identifier.matches(in: inputsString, range: NSRange(inputsString.startIndex..., in: inputsString)).compactMap {
        Range($0.range, in: inputsString).map { String(inputsString[$0]) }
    })
    let missing = stored.filter { !notInputs.contains($0) && !named.contains($0) }
    try lowExpect(missing.isEmpty, "a change to \(missing.joined(separator: ", ")) would not discard an image check in flight")
    guard let change = body.range(of: ".onChange(of: checkInputs)"),
          let open = body[change.upperBound...].firstIndex(of: "{"), let handler = reader.balanced(at: open) else {
        throw NSError(domain: "TeamContainerLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "no onChange of checkInputs invalidates a check in flight"])
    }
    try lowExpect(handler.contains("checkRevision += 1") && handler.contains("configuration = nil"),
        "a change of inputs does not advance checkRevision and clear the result")
    guard let check = member("private func check()") else {
        throw NSError(domain: "TeamContainerLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "check() was not found"])
    }
    try lowExpect(check.contains("let revision = checkRevision") && check.contains("checkRevision == revision"),
        "check() does not apply its result under the revision it began with")
    try lowExpect(!check.contains("== selected"), "check() still compares the view's inputs with copies of themselves")
}

/// A container member is created as a stopped placeholder and started only
/// when its Docker preparation succeeds. When the preparation failed, the
/// placeholder still read as owned, so it was never offered for closing; a
/// Stop pressed while Docker prepared tried to clean up under the running
/// preparation, was refused, and reported the member as failed.
func checkTeamContainerPreparationEndsAsAStoppedPlaceholder() throws {
    let fixture = try TeamFixture(); defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let request = try coordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "fixture", folder: fixture.project, paneLimit: 3, hours: 1))
    try coordinator.approve(id: request.id, revision: request.revision, objective: "fixture", folder: fixture.project,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 3, hours: 1, containerConfigurations: ["codex": containerTeamConfiguration()])
    func placeholder(_ id: String) -> WorkbenchPane {
        var pane = fixture.lead
        pane.id = id; pane.kind = .codex; pane.isStarted = false; pane.launchGeneration = 0
        pane.containerConfiguration = containerTeamConfiguration()
        return pane
    }
    func member(_ id: String) -> TeamSessionMember? { coordinator.sessions().first?.members.first { $0.paneID == id } }

    let provision = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Container", role: nil)
    let preparing = placeholder("preparing")
    coordinator.fulfilProvisions(create: { _, _, _ in box.update { $0.append(preparing) }; return preparing })
    guard let pending = member("preparing") else { throw TeamSessionError.invalid("the placeholder was not owned") }
    try lowExpect(pending.ownership(of: preparing) == .owned, "a placeholder whose container is being prepared was not owned")
    try lowExpect(TeamStopPlanner.plan(members: [pending], live: box.current()).first?.action == .skip(.preparationCancelled),
        "Stop during preparation did not say the preparation was cancelled")
    try lowExpect(TeamStopPlanner.containerCleanup(members: [pending], live: box.current()).isEmpty,
        "Stop ran Docker cleanup under a preparation still in flight, which the controller refuses")
    try lowExpect(!TeamMemberStopResult.preparationCancelled.label.isEmpty, "the cancelled preparation has no label")
    let summary = TeamStopAttempt(reason: "fixture", outcomes: [TeamMemberStopOutcome(paneID: "preparing", launchGeneration: 0, name: "Container",
        result: .preparationCancelled, message: nil)]).summary
    try lowExpect(summary.hasPrefix("Skipped:") && !summary.contains("Could not confirm"), "a cancelled preparation read as a failed stop: \(summary)")

    // The preparation then fails (or is refused at activation) and cleans up.
    coordinator.failContainerProvision(id: provision.id, reason: "fixture Docker failure; its container was removed")
    guard let ended = member("preparing") else { throw TeamSessionError.invalid("the member was lost") }
    try lowExpect(ended.ownership(of: preparing) == .stopped, "a placeholder whose preparation ended still read as owned")
    try lowExpect(coordinator.sessions().first?.stoppedPlaceholders(in: box.current()).map(\.id) == ["preparing"],
        "a placeholder whose preparation ended was not offered for closing")
    try lowExpect(TeamStopPlanner.plan(members: [ended], live: box.current()).first?.action == .skip(.alreadyStopped),
        "an ended preparation was still reported as being cancelled")
    try lowExpect(TeamStopPlanner.containerCleanup(members: [ended], live: box.current()).map(\.id) == ["preparing"],
        "Stop no longer retries the container cleanup of a placeholder whose preparation ended")

    // A preparation that could not even begin ends the same way.
    _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Unmounted", role: nil)
    let unmounted = placeholder("unmounted")
    coordinator.fulfilProvisions(create: { _, _, _ in box.update { $0.append(unmounted) }; return unmounted },
        mount: { _, _ in throw TeamSessionError.invalid("fixture: preparation could not begin") })
    try lowExpect(member("unmounted")?.ownership(of: unmounted) == .stopped, "a preparation that never began left the placeholder owned")

    // A host member, and a started container generation, are unchanged.
    var started = placeholder("started"); started.isStarted = true; started.launchGeneration = 1
    let host = TeamSessionMember(paneID: "started", launchGeneration: 1, workspaceID: "workspace", kind: .codex, name: "Host",
        role: nil, requestedByPaneID: "lead", grantID: "grant", createdAt: Date())
    try lowExpect(host.ownership(of: started) == .owned, "a started owned generation changed ownership")
    var unstartedHost = started; unstartedHost.isStarted = false
    try lowExpect(host.ownership(of: unstartedHost) == .owned, "a member without a container preparation changed its ownership rule")
}

/// Every failed team add stayed in memory for the life of the app, and the
/// app scans every provision each second, so a requester retrying a refused
/// creation grew both without limit.
func checkFailedTeamProvisionsAreBounded() throws {
    let fixture = try TeamFixture(); defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let request = try coordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "fixture", folder: fixture.project, paneLimit: 2, hours: 1))
    try coordinator.approve(id: request.id, revision: request.revision, objective: "fixture", folder: fixture.project,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 1)
    let bound = TeamSessionCoordinator.retainedFailedProvisions
    var ids: [String] = []
    for attempt in 0..<(bound * 3) {
        let provision = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Attempt \(attempt)", role: nil)
        ids.append(provision.id)
        coordinator.fulfilProvisions(create: { _, _, _ in throw TeamSessionError.invalid("fixture creation failure \(attempt)") })
        try lowExpect(coordinator.provision(id: provision.id)?.failure != nil, "attempt \(attempt) did not fail as arranged")
    }
    let kept = ids.filter { coordinator.provision(id: $0) != nil }
    try lowExpect(kept.count <= bound, "\(kept.count) failed requests were kept for one session; the bound is \(bound)")
    try lowExpect(kept == Array(ids.suffix(kept.count)) && kept.count == bound, "pruning did not keep the newest failed requests")
    // A failure the requester is still waiting on stays recoverable.
    let last = coordinator.wait(token: "lead-token", id: ids.last!, until: .now() + 1)
    try lowExpect(last.status == 409 && last.text.contains("fixture creation failure"), "the newest failure could not be recovered: \(last.status) \(last.text)")
    // A created pane's request is never pruned: its identity guards against a second pane.
    let created = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Created", role: nil, idempotencyKey: "created-key")
    var pane = fixture.lead; pane.id = "created"; pane.kind = .codex
    coordinator.fulfilProvisions(create: { _, _, _ in box.update { $0.append(pane) }; return pane })
    for attempt in 0..<(bound + 2) {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Later \(attempt)", role: nil)
        coordinator.fulfilProvisions(create: { _, _, _ in throw TeamSessionError.invalid("fixture later failure") })
    }
    try lowExpect(coordinator.provision(id: created.id)?.paneID == "created", "a created pane's request was pruned")
    let repeated = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Created", role: nil, idempotencyKey: "created-key")
    try lowExpect(repeated.id == created.id, "a repeated request identity did not return the created pane's request")
}

/// A lead whose working folder is `/` was approved (the coordinator treats
/// the root specially) and then refused at every creation, because the
/// controller's own check built `//` as the prefix. One helper decides.
func checkTeamFolderContainmentAtTheRoot() throws {
    try lowExpect(WorkspaceFolderIdentity.contains("/private/tmp/project", within: "/"), "the root did not contain a folder")
    try lowExpect(WorkspaceFolderIdentity.contains("/", within: "/"), "the root did not contain itself")
    try lowExpect(WorkspaceFolderIdentity.contains("/a/b", within: "/a") && WorkspaceFolderIdentity.contains("/a/b", within: "/a/"),
        "a folder was not inside its parent")
    try lowExpect(!WorkspaceFolderIdentity.contains("/ab", within: "/a") && !WorkspaceFolderIdentity.contains("/a", within: "/a/b"),
        "a sibling sharing a name prefix, or a parent, counted as inside")

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-team-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    let shimDirectory = runtime.appendingPathComponent("bin", isDirectory: true)
    let transportDirectory = runtime.appendingPathComponent("relay", isDirectory: true)
    try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: transportDirectory, withIntermediateDirectories: true)
    controller.configureRelay(RelayRuntime(infoFile: runtime.appendingPathComponent("relay-url"), shimDirectory: shimDirectory,
        transportDirectory: transportDirectory, credentials: try RelayCredentials(file: runtime.appendingPathComponent("relay-tokens.json")), runtimeMarker: "DEV"))
    _ = try controller.createWorkspace(folder: project.path)
    let lead = try controller.createPane(kind: .claude, cwd: "/")
    try lowExpect(lead.launchWorkingDirectory == "/", "the fixture lead does not work at the root: \(lead.launchWorkingDirectory)")
    var eligible = lead; eligible.relayEnabled = true
    let box = PaneBox([eligible])
    let coordinator = TeamSessionCoordinator(authenticate: { _ in lead.id }, panes: { box.current() },
        profiles: { PermissionProfileDefinition.builtIns }, record: { _, _, _ in })
    let session = try coordinator.request(token: "t", proposal: TeamSessionProposal(objective: "fixture", folder: project.path, paneLimit: 1, hours: 1))
    try coordinator.approve(id: session.id, revision: session.revision, objective: "fixture", folder: project.path,
        allowedVendors: [.codex], permissionProfileID: "review-only", paneLimit: 1, hours: 1)
    let provision = try coordinator.requestPane(token: "t", kind: .codex, name: "Member", role: nil)
    coordinator.fulfilProvisions { session, grant, provision in
        let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots)
        let pane = try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
        box.update { $0.append(pane) }
        return pane
    }
    let result = coordinator.provision(id: provision.id)
    try lowExpect(result?.paneID != nil, "a lead at the root was approved but its pane was refused: \(result?.failure ?? "no failure recorded")")
}

/// Every lifecycle stop the app makes after an await names the generation it
/// reviewed. The registry's lost-client cleanup did not, so a pane restarted
/// while Docker cleanup ran had its new session stopped.
func checkAppLifecycleStopsNameTheirGeneration() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var unbound: [String] = []
    for folder in ["ParleyNative", "ParleyUI"] {
        let directory = sources.appendingPathComponent(folder)
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where file.hasSuffix(".swift") {
            let reader = SwiftSourceReader(try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8))
            var search = reader.text.startIndex..<reader.text.endIndex
            while let call = reader.text.range(of: "stopPaneProcess(", range: search) {
                search = call.upperBound..<reader.text.endIndex
                guard let arguments = reader.balanced(at: reader.text.index(before: call.upperBound)) else { continue }
                if !arguments.contains("expectedGeneration:") || arguments.contains("expectedGeneration: nil") {
                    unbound.append("\(file): stopPaneProcess(\(arguments))")
                }
            }
        }
    }
    try lowExpect(unbound.isEmpty, "a lifecycle stop is not bound to the generation it reviewed:\n" + unbound.joined(separator: "\n"))
}

private final class ContainerRemovalRunner: CommandRunning, @unchecked Sendable {
    let lock = NSLock()
    var calls: [[String]] = []
    var present: [String: String] = [:]
    var running: Set<String> = []
    func run(executable: URL, arguments a: [String], environment: [String: String], input: Data?) throws -> CommandOutput {
        try lock.withLock {
            calls.append(a)
            var text = ""
            let id = a.last ?? ""
            if a.contains("info") { text = "daemon-one" }
            else if a.contains("ls") {
                if let filter = a.first(where: { $0.hasPrefix("id=") }), present[String(filter.dropFirst(3))] != nil { text = String(filter.dropFirst(3)) }
            } else if a.contains("inspect") {
                text = a.contains("{{.State.Running}}") ? (running.contains(id) ? "true" : "false") : (present[id] ?? "")
            } else if a.contains("stop") { running.remove(id) }
            else if a.contains("rm") { present[id] = nil }
            else { throw NSError(domain: "unexpected fake Docker argv", code: 1) }
            return CommandOutput(stdout: Data(text.utf8))
        }
    }
}

/// Removing one running container ran Docker eleven times, three of them to
/// ask the same daemon for its identity. The daemon is verified once per
/// operation, and a cleanup of several records on one daemon asks once.
func checkContainerRemovalVerifiesTheDaemonOnce() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-removal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ContainerRemovalRunner()
    let service = try ContainerPaneService(directory: directory, environment: [:], runner: runner)
    func record(_ owner: String, id: String) -> [String: Any] {
        ["id": owner, "paneID": "pane-fixture", "generation": 1,
         "configuration": ["dockerExecutable": "/usr/local/bin/docker", "daemonEndpoint": "unix:///tmp/docker.sock", "daemonID": "daemon-one",
             "imageID": "sha256:" + String(repeating: "b", count: 64), "imageName": "fixture", "legacyCodexSandbox": false],
         "volume": "home-fixture", "runtime": "DEV", "containerID": id, "removed": false, "createdAt": 0]
    }
    let first = String(repeating: "a", count: 64), second = String(repeating: "d", count: 64)
    let file = directory.appendingPathComponent("container-panes.json")
    func seed() throws {
        runner.present = [first: "owner-a", second: "owner-b"]
        runner.running = [first, second]
        runner.calls = []
        try JSONSerialization.data(withJSONObject: ["owner": "runtime-owner", "records": [record("owner-a", id: first), record("owner-b", id: second)]]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    try seed()

    let one = try service.records().first { $0.id == "owner-a" }!
    try service.remove(one)
    let single = runner.calls
    try lowExpect(runner.present[first] == nil && runner.present[second] != nil, "the reviewed container was not removed, or another was")
    try lowExpect(single.filter { $0.contains("info") }.count == 1, "one removal asked the daemon for its identity \(single.filter { $0.contains("info") }.count) times")
    try lowExpect(single.first?.contains("info") == true, "the daemon was not verified before anything else")
    try lowExpect(single.count <= 9, "one removal ran Docker \(single.count) times")

    // Both records live, on one daemon: one cleanup asks it once.
    try seed()
    try service.stop(paneID: "pane-fixture")
    try lowExpect(runner.present.isEmpty && (try service.records()).allSatisfy(\.removed), "the records were not cleaned up")
    try lowExpect(runner.calls.filter { $0.contains("rm") }.count == 2, "the cleanup did not remove both containers")
    try lowExpect(runner.calls.filter { $0.contains("info") }.count == 1, "one cleanup of two records asked the same daemon more than once")
}

@MainActor let teamContainerLowChecks: [(String, () throws -> Void)] = [
    ("a container image check discards a result for changed inputs", checkContainerImageCheckDiscardsChangedInputs),
    ("a team container preparation ends as a stopped placeholder", checkTeamContainerPreparationEndsAsAStoppedPlaceholder),
    ("failed team pane requests are bounded per session", checkFailedTeamProvisionsAreBounded),
    ("team folder containment holds at the root", checkTeamFolderContainmentAtTheRoot),
    ("app lifecycle stops name their generation", checkAppLifecycleStopsNameTheirGeneration),
    ("container removal verifies the daemon once", checkContainerRemovalVerifiesTheDaemonOnce),
]
