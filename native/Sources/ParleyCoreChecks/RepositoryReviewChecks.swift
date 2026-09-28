import Darwin
import Foundation
import ParleyCore

private func repoReviewExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "RepositoryReview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func repoReviewRefuses(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "RepositoryReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsafe operation was accepted"])
}

private func repoReviewRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp/pr-review-" + String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

private func repoReviewPane(_ id: String, kind: PaneKind = .codex) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/tmp", currentCommand: kind.rawValue,
        isActive: false, workspaceID: "fixture", relayEnabled: true, protocolVersion: AgentProtocol.version, inputAvailable: true)
}

@MainActor let repositoryReviewChecks: [(String, () throws -> Void)] = [
    ("low review host launch clears inherited runtime and preserves its own", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vendor = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '%s' \"${PARLEY_RUNTIME-unset}\"\n".utf8).write(to: vendor)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path)
        for marker: String? in [nil, "DEV"] {
            let app = root.appendingPathComponent(marker ?? "production")
            var environment = ["PATH": bin.path + ":/usr/bin:/bin", "SHELL": "/bin/zsh", "PARLEY_RUNTIME": "DEV"]
            let controller = try WorkbenchController(applicationDirectory: app, environment: environment)
            try controller.bootstrap(cwd: root.path)
            controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("info"), shimDirectory: app.appendingPathComponent("bin"),
                transportDirectory: app.appendingPathComponent("transport"), credentials: try RelayCredentials(file: app.appendingPathComponent("tokens")), runtimeMarker: marker))
            let pane = try controller.createPane(kind: .claude, cwd: root.path)
            let launch = try controller.launchConfiguration(for: pane.id)
            environment.merge(launch.environment) { _, value in value }
            let result = try ProcessCommandRunner(timeout: 5).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", launch.command], environment: environment)
            try repoReviewExpect(result.status == 0 && result.stdoutText == (marker ?? "unset"), "launch used an inherited or missing runtime: \(result.stdoutText)")
        }
    }),
    ("low review socket creation is private before chmod and restores umask", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = umask(0o022); defer { umask(original) }
        try LocalSocketCreation.withOwnerOnlyPermissions {
            let path = root.appendingPathComponent("probe").path
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o666)
            try repoReviewExpect(descriptor >= 0, "fixture creation failed")
            defer { close(descriptor) }
            var metadata = stat()
            try repoReviewExpect(fstat(descriptor, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600, "creation exposed permissions before chmod")
        }
        let restored = umask(0o022)
        try repoReviewExpect(restored == 0o022, "socket creation changed the caller's umask")
    }),
    ("low review repaired journal writes each snapshot once", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let source = repoReviewPane("source"), target = repoReviewPane("target", kind: .claude)
        let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in })
        _ = broker.handle(token: try credentials.token(for: source.id), target: target.id, text: "fixture")
        let handoff = broker.handoffs().first!
        let failure = LowReviewSyncFailure()
        let file = root.appendingPathComponent("journal")
        let journal = try RelayHandoffJournal(file: file, io: .init(
            write: { Darwin.write($0, $1, $2) },
            fsync: { failure.consume() ? -1 : Darwin.fsync($0) },
            truncate: { _, _ in -1 }))
        journal.record(handoff)
        try repoReviewExpect(journal.hasUncertainTail, "fixture did not leave an uncertain tail")
        journal.record(handoff)
        let lines = try Data(contentsOf: file).split(separator: 10)
        try repoReviewExpect(!journal.hasUncertainTail && journal.lastError == nil && lines.count == 1, "repair appended its snapshot twice")
    }),
    ("low review worker owner identity includes the kernel start time", {
        let pid = getpid(), stamp = ApprovedCommandWorker.processStartTime(getpid())!
        let command = try ReviewedCommand(argv: ["/usr/bin/true"], folder: "/tmp", sourceFolder: "/tmp")
        func ticket(_ start: UInt64?) -> ApprovedCommandTicket {
            ApprovedCommandTicket(resultKey: Data(repeating: 1, count: 32), runID: UUID().uuidString, command: command,
                sourceFolder: "/tmp", shellExecutable: "/bin/sh", ownerPID: pid, expiresAt: .distantFuture,
                exitInsteadOfShellWhenClean: false, ownerStartTime: start)
        }
        try repoReviewExpect(ApprovedCommandWorker.ownerIsCurrent(ticket(stamp)), "live owner rejected")
        try repoReviewExpect(!ApprovedCommandWorker.ownerIsCurrent(ticket(stamp + 1)), "recycled PID accepted")
        try repoReviewExpect(!ApprovedCommandWorker.ownerIsCurrent(ticket(nil)), "legacy ticket guessed the owner identity")
    }),
    ("low review rejects unapproved Docker executable paths", {
        let configuration = ContainerConfiguration(dockerExecutable: "/bin/sh", daemonEndpoint: "unix:///tmp/docker.sock",
            daemonID: "fixture", imageID: "sha256:" + String(repeating: "a", count: 64), imageName: "fixture", legacyCodexSandbox: false)
        try repoReviewRefuses { try ContainerLaunchProjection.validate(configuration) }
    }),
    ("low review bare repositories never become primary checkouts", {
        let listing = "worktree /tmp/bare.git\0bare\0\0worktree /tmp/linked\0HEAD abc\0branch refs/heads/main\0\0"
        try repoReviewExpect(!RegisteredWorktree.parse(Data(listing.utf8)).contains(where: \.isPrimary), "bare directory was treated as a primary checkout")
        try repoReviewExpect(!GitWorktreeResolver.parsePorcelain(listing).contains(where: \.isPrimary), "discovery relabelled a bare directory as a checkout")
    }),
    ("low review plain context drafts cannot be rejected as waiting Asks", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let source = repoReviewPane("source", kind: .claude)
        let token = try credentials.token(for: source.id)
        let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in },
            contextReviewStore: try AgentContextReviewStore(file: root.appendingPathComponent("reviews.json")))
        let staged = broker.handleContextDraft(token: token, name: "fixture", path: "note.txt", text: "original")
        let draft = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))
        let revision = broker.contextReviews().first { $0.id == draft.id }!.updatedAt
        try repoReviewExpect(broker.rejectContextReview(reviewID: draft.id, expectedUpdatedAt: revision).status == 409, "reject accepted a plain draft")
    }),
    ("repository review OSC folders cannot widen command team or context authority", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("reviewed"), outside = root.appendingPathComponent("outside")
        for path in [folder, outside] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("reviewed capture bytes".utf8).write(to: folder.appendingPathComponent("marker.txt"))
        var source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: folder.path,
            currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        source.cwd = "/"
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let token = try credentials.token(for: source.id)
        let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in },
            contextReviewStore: try AgentContextReviewStore(file: root.appendingPathComponent("reviews.json")))
        broker.enableReviewedCommandRuns(); broker.enableTeamSessions(profiles: { PermissionProfileDefinition.builtIns })
        let runs = broker.commandRuns!, teams = broker.teamSessions!
        runs.setAutomaticApproval(true)
        try repoReviewRefuses { _ = try runs.request(token: token, argv: ["/usr/bin/true"], folder: outside.path) }
        let run = try runs.request(token: token, argv: ["/usr/bin/true"], folder: folder.path)
        let grant = ReviewedCommandGrant(source: source, command: run.command)
        source.cwd = outside.path
        runs.reconcile()
        try repoReviewExpect(run.sourceFolder == GitWorktreeResolver.canonicalPath(folder.path)
            && runs.runs().first?.state == .approved && grant.matches(source: source, command: run.command),
            "an OSC report changed command containment or its reviewed grant")
        try repoReviewRefuses { _ = try teams.request(token: token, proposal: .init(objective: "fixture", folder: outside.path, paneLimit: 1, hours: 1)) }
        let team = try teams.request(token: token, proposal: .init(objective: "fixture", folder: folder.path, paneLimit: 1, hours: 1))
        source.cwd = "/"
        try teams.approve(id: team.id, revision: team.revision, objective: "fixture", folder: folder.path,
            allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
        try repoReviewExpect(teams.sessions().first?.state == .active, "an OSC report changed a reviewed team folder")
        let refused = broker.handleContextDraft(token: token, name: "outside", path: outside.appendingPathComponent("claim.txt").path, text: "claim")
        try repoReviewExpect(refused.status == 403, "OSC widened agent context staging")
        let result = broker.handleDelegationFileResult(token: token, handoffID: "missing", path: outside.appendingPathComponent("result.txt").path, text: "claim")
        try repoReviewExpect(result.status == 403, "OSC widened delegation-file staging")
        let staged = broker.handleContextDraft(token: token, name: "inside", path: "claim.txt", text: "claim")
        try repoReviewExpect(staged.status == 201, "reviewed-folder context staging failed")
        let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))
        try repoReviewExpect(broker.contextReviews().first { $0.id == summary.id }?.sourceFolder == folder.path,
            "trusted capture inherited an OSC folder")
        let captured = broker.captureTrustedContext(.init(reviewID: summary.id, kind: .commandResult,
            executablePath: "/bin/cat", arguments: ["marker.txt"]))
        try repoReviewExpect(captured.status == 200 && captured.text.contains("reviewed capture bytes"),
            "trusted command capture did not run in the reviewed folder")
        source.launchFolder = outside.path
        runs.reconcile(); teams.reconcile()
        try repoReviewExpect(runs.runs().first?.state != .approved && teams.sessions().first?.state == .interrupted,
            "an explicit launch-folder change retained authority")
    }),
    ("repository review ignored nested repositories and broken creation markers block removal", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo")
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let runner = ProcessCommandRunner(timeout: 5)
        func git(_ args: [String]) throws -> String {
            let result = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, environment: environment)
            try repoReviewExpect(result.status == 0, "Git fixture failed: \(result.stderrText)")
            return result.stdoutText
        }
        _ = try git(["init", "-q", repository.path])
        try Data("ignored/\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        _ = try git(["-C", repository.path, "add", ".gitignore"])
        _ = try git(["-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"])
        let store = ManagedWorktreeStore(file: root.appendingPathComponent("managed.json"))
        let service = ManagedWorktreeService(store: store, environment: environment)
        let record = try service.create(.init(repositoryFolder: repository.path, branch: "fixture", baseRef: "HEAD"))
        let nested = URL(fileURLWithPath: record.path).appendingPathComponent("ignored/nested")
        _ = try git(["init", "-q", nested.path])
        let preview = try service.cleanupPreview(record, livePaneFolders: [], otherRuntimeStateFiles: [])
        try repoReviewExpect(preview.facts.nestedWorktreePaths.contains { GitWorktreeResolver.canonicalPath($0) == GitWorktreeResolver.canonicalPath(nested.path) }, "ignored directory concealed an independent repository: ignored=\(preview.ignoredPaths), nested=\(preview.facts.nestedWorktreePaths), expected=\(nested.path)")
        if case .refuse = preview.decision {} else { throw NSError(domain: "RepositoryReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "nested repository was removable"]) }
        var pane = WorkbenchPane(id: "inside", kind: .codex, customName: nil, terminalTitle: "", cwd: record.path,
            currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
        pane.cwd = root.path
        let usage = WorktreeUsage.project(path: record.path, panes: [pane], workspaces: [], handoffs: [],
            otherPaneFolders: [], otherRuntimeUnknown: false, activeTeamPaths: [])
        try repoReviewExpect(usage.paneIDs == [pane.id] && pane.worktreeSafetyFolders.contains(record.path),
            "OSC concealed a pane from worktree usage or cleanup")
        let stateFile = root.appendingPathComponent("other-runtime.json")
        try JSONSerialization.data(withJSONObject: ["panes": [
            ["kind": "codex", "cwd": root.path, "launchFolder": record.path],
            ["kind": "shell", "cwd": root.path, "launchFolder": record.path]
        ]]).write(to: stateFile)
        let otherRuntime = try service.cleanupPreview(record, livePaneFolders: [], otherRuntimeStateFiles: [stateFile])
        try repoReviewExpect(otherRuntime.facts.otherRuntimePaneFolders.filter { WorktreeCleanupPolicy.isNested($0, in: record.path) }.count == 1,
            "another runtime lost the agent root or retained a Shell's obsolete launch folder")
        let admin = try git(["-C", record.path, "rev-parse", "--path-format=absolute", "--git-dir"])
        let markerFile = URL(fileURLWithPath: String(admin.dropLast())).appendingPathComponent(ManagedWorktreeService.creationMarkerName)
        try Data("replacement-marker\n".utf8).write(to: markerFile)
        try repoReviewRefuses { _ = try service.attach(existingPath: record.path, in: repository.path, baseRef: nil) }
        try repoReviewExpect(try store.record(path: record.path) == record, "attach erased a broken creation record")
    }),
    ("repository review context command deadline survives inherited output pipes", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) { _ = kill(pid, SIGKILL) }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try ContextProcessCommandRunner(timeout: 2).run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 20 & printf '%s' \"$!\" > \"$1\"; exit 7", "fixture", pidFile.path],
            workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"])
        try repoReviewExpect(result.status == 7 && DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000,
            "a descendant held context capture open after its command exited")
    }),
    ("repository review relaunch ignores terminal-reported permission folders", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("app"), folder = root.appendingPathComponent("reviewed"), other = root.appendingPathComponent("reported")
        for (directory, enabled) in [(folder, false), (other, true)] {
            let settings = directory.appendingPathComponent(".claude/settings.local.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"sandbox\":{\"enabled\":\(enabled)}}".utf8).write(to: settings)
        }
        let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh", "PARLEY_RUNTIME": "DEV"]
        let controller = try WorkbenchController(applicationDirectory: app, environment: environment)
        try controller.bootstrap(cwd: folder.path)
        let credentials = try RelayCredentials(file: app.appendingPathComponent("tokens.json"))
        let runtime = RelayRuntime(infoFile: app.appendingPathComponent("info"), shimDirectory: app.appendingPathComponent("bin"), transportDirectory: root.appendingPathComponent("transport"), credentials: credentials)
        controller.configureRelay(runtime)
        let pane = try controller.createPane(kind: .claude, cwd: folder.path)
        let launch = try controller.launchConfiguration(for: pane.id)
        try repoReviewExpect(launch.command.contains("'-u' 'PARLEY_RUNTIME'"), "host launch inherited the other runtime marker")
        try controller.terminalDidChangeWorkingDirectory(paneID: pane.id, path: other.path)
        try repoReviewExpect(try controller.listPanes().first { $0.id == pane.id }?.cwd == other.path, "terminal cwd was not retained for display")
        try controller.restartPane(pane.id)
        var current = try controller.listPanes().first { $0.id == pane.id }!
        try repoReviewExpect(controller.hostClaudeSandbox(for: current)?.enabled == false, "OSC changed the restarted sandbox policy")
        try repoReviewExpect(try controller.launchConfiguration(for: pane.id).workingDirectory == folder.path, "restart followed an OSC folder")
        try controller.terminalDidChangeWorkingDirectory(paneID: pane.id, path: other.path)
        try controller.stopPaneProcess(pane.id, expectedGeneration: nil)
        try controller.startPane(pane.id)
        current = try controller.listPanes().first { $0.id == pane.id }!
        try repoReviewExpect(current.launchFolder == folder.path && current.permissionSelection?.approvedRoots == [folder.path] && controller.hostClaudeSandbox(for: current)?.enabled == false, "stop/start widened the launch folder")
        try controller.terminalDidChangeWorkingDirectory(paneID: pane.id, path: other.path)
        try controller.shutdown()
        let reopened = try WorkbenchController(applicationDirectory: app, environment: environment)
        try reopened.bootstrap(cwd: folder.path); reopened.configureRelay(runtime)
        try reopened.startPane(pane.id)
        try repoReviewExpect(try reopened.launchConfiguration(for: pane.id).workingDirectory == folder.path, "reload forgot the reviewed launch folder")
        try reopened.stopPaneProcess(pane.id, expectedGeneration: nil)
        try reopened.setStoppedPaneFolder(pane.id, folder: other.path)
        try reopened.startPane(pane.id)
        let changed = try reopened.listPanes().first { $0.id == pane.id }!
        try repoReviewExpect(reopened.hostClaudeSandbox(for: changed)?.enabled == true, "an explicit native folder selection was ignored")
    }),
    ("repository review tracked waits authenticate before coordinator dispatch", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let token = try credentials.token(for: "source")
        var source = repoReviewPane("source")
        source.cwd = root.path
        let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in })
        broker.enableReviewedCommandRuns()
        broker.enableTeamSessions(profiles: { PermissionProfileDefinition.builtIns })
        let run = try broker.commandRuns!.request(token: token, argv: ["/usr/bin/true"], folder: root.path)
        try broker.commandRuns!.reject(id: run.id, revision: run.revision)
        let team = try broker.teamSessions!.request(token: token, proposal: TeamSessionProposal(objective: "fixture", folder: root.path, paneLimit: 1, hours: 1))
        try broker.teamSessions!.reject(id: team.id, revision: team.revision)
        for id in [run.id, team.id] {
            source.relayEnabled = false
            let response = broker.waitForTrackedWork(token: token, handoffID: id)
            try repoReviewExpect(response.status == 403 && response.text.contains("relay is disabled"), "inactive wait reached a coordinator")
            source.relayEnabled = true
            try repoReviewExpect(broker.waitForTrackedWork(token: token, handoffID: id).status == 409, "a live source could not recover its refusal")
        }
    }),
    ("repository review terminal context persistence retries without reopening approval", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("reviews"), backup = root.appendingPathComponent("backup")
        let store = try AgentContextReviewStore(file: directory.appendingPathComponent("store.json"))
        let review = AgentContextReview(sourcePaneID: "source", sourcePaneName: "source", sourcePaneKind: .codex, sourceFolder: root.path, pack: ContextPack(), state: .awaitingReview)
        try store.record(review)
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("obstruction".utf8).write(to: directory)
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in }, contextReviewStore: store)
        try repoReviewExpect(broker.contextReviews().first?.state == .interrupted && broker.contextPersistenceError != nil, "failed terminal persistence was hidden or reopened approval")
        try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: backup, to: directory)
        _ = broker.contextReviews()
        try repoReviewExpect(broker.contextPersistenceError == nil && store.reviews().first?.state == .interrupted, "terminal reality did not retry after storage recovered")
    }),
    ("repository review permission disclosures match session lifetime and vendor argv", {
        for text in [ReviewedCommandRunCoordinator.automaticApprovalDisclosure, ReviewedCommandRunPaneClosePolicy.disclosure] {
            try repoReviewExpect(text.contains("only to this app session") && text.contains("resets to off when Parley quits"), "permission choice disclosure implies persistence")
        }
        for kind in PaneKind.allCases where kind.isAgent {
            let text = ContainerLaunchProjection.bypassDisclosure(for: kind)
            let arguments = ContainerLaunchProjection.bypassArguments(for: kind)
            try repoReviewExpect(!arguments.isEmpty && text.contains(kind.label) && arguments.allSatisfy(text.contains), "bypass review names a different vendor or flag")
        }
    }),
    ("repository review overlapping pane deliveries are refused before input", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("app"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
        try controller.bootstrap(cwd: root.path)
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        controller.configureRelay(RelayRuntime(infoFile: root.appendingPathComponent("info"), shimDirectory: root.appendingPathComponent("bin"), transportDirectory: root.appendingPathComponent("transport"), credentials: credentials))
        let pane = try controller.createPane(kind: .claude, cwd: root.path)
        try controller.terminalDidAttach(paneID: pane.id)
        var entries: [String] = []
        controller.configureTerminalTransport(PaneTerminalTransport(paste: { id, text, _ in
            entries.append(text)
            if text == "outer" { try repoReviewRefuses { try controller.paste("nested", into: id, submit: true) } }
        }, interrupt: { _ in }, captureSelectedText: { _ in "" }, terminate: { _ in }, terminateAll: {}))
        try controller.paste("outer", into: pane.id, submit: true)
        try controller.paste("later", into: pane.id, submit: true)
        try repoReviewExpect(entries == ["outer", "later"], "delivery guard allowed overlap or blocked subsequent input")
    }),
    ("repository review approved command cancellation bounds an unreapable child", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let command = try ReviewedCommand(argv: ["/bin/sleep", "30"], folder: root.path, sourceFolder: root.path)
        var clock: UInt64 = 0
        var child: pid_t = 0
        var cancelChecks = 0
        defer {
            if child > 0 {
                _ = kill(child, SIGKILL)
                var status: Int32 = 0
                _ = BoundedReap.run(child, status: &status)
            }
        }
        let result = try ApprovedCommandProcess.run(command, environment: ["PATH": "/usr/bin:/bin"],
            shouldCancel: { cancelChecks += 1; return cancelChecks > 1 }, now: { clock },
            pause: { _ in clock += 10_000_000 },
            observe: { pid, _ in child = pid_t(pid); return 0 },
            wait: { pid, _, options in
                child = pid
                precondition(options == WNOHANG, "cleanup must never block")
                return 0
            })
        try repoReviewExpect(result.cancelled && result.exitStatus == nil && result.terminationSignal == nil,
            "an unobserved command exit was reported as success")
        try repoReviewExpect(clock <= 2_600_000_000 && result.detail?.contains("completion is unknown") == true,
            "cancellation waited beyond bounded cleanup or concealed the unknown exit")
    }),
    ("repository review Codex config deadline survives a descendant holding stdout", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture-codex")
        let pidFile = root.appendingPathComponent("descendant.pid")
        let script = """
        #!/bin/sh
        IFS= read -r request
        /bin/sleep 20 &
        printf '%s' "$!" > "$FIXTURE_PID_FILE"
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) { _ = kill(pid, SIGKILL) }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try CodexHostConfiguration.read(executable: executable, arguments: [],
                environment: ["PATH": "/usr/bin:/bin", "FIXTURE_PID_FILE": pidFile.path], folder: root.path, timeout: 0.2)
            throw NSError(domain: "RepositoryReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "a silent config query succeeded"])
        } catch let error as PermissionProfileError {
            try repoReviewExpect(error.localizedDescription.contains("timed out"), "config query failed for an unexpected reason")
        }
        try repoReviewExpect(DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000,
            "a descendant retained the configuration pipe past the deadline")
        let success = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        printf '%s\\n' '{"id":2,"result":{"config":{"approvals_reviewer":"fixture"}}}'
        """
        try Data(success.utf8).write(to: executable)
        let config = try CodexHostConfiguration.read(executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"], folder: root.path, timeout: 2)
        try repoReviewExpect(config["approvals_reviewer"] as? String == "fixture", "bounded I/O broke config request/response sequencing")
    }),
    ("repository review control socket refuses every legacy pane route", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let token = try credentials.token(for: "source")
        let broker = RelayBroker(credentials: credentials, panes: { [repoReviewPane("source"), repoReviewPane("target", kind: .claude)] },
            paste: { _, _ in throw NSError(domain: "unexpected delivery", code: 1) },
            submit: { _, _ in throw NSError(domain: "unexpected delivery", code: 1) })
        broker.hostNetworkAllowed = { _ in true }
        let server = RelayHTTPServer(broker: broker, infoFile: root.appendingPathComponent("info"), controlToken: "native-only")
        try server.start(); defer { server.stop() }
        for route in ["relay", "paste", "ask", "ask-many", "delegate", "status", "wait/id", "progress/id", "done/id", "fail/id", "cancel/id", "answer/id"] {
            let result = try ProcessCommandRunner(timeout: 3).run(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["--disable", "--silent", "--max-time", "2", "--unix-socket", root.appendingPathComponent("relay.sock").path,
                    "--header", "Authorization: Bearer " + token, "--header", "X-Parley-To: target", "--data-binary", "fixture", "--write-out", "%{http_code}", "http://localhost/" + route],
                environment: ["PATH": "/usr/bin:/bin"])
            try repoReviewExpect(result.status == 0 && result.stdoutText.hasSuffix("404"), "legacy route \(route) remained accessible")
        }
        try repoReviewExpect(broker.handoffs().isEmpty, "a legacy socket route created a handoff")
    }),
    ("repository review inactive source capabilities cannot coordinate", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let token = try credentials.token(for: "source")
        for state in 0..<3 {
            var source = repoReviewPane("source")
            if state == 0 { source.isStarted = false }
            if state == 1 { source.isDead = true }
            if state == 2 { source.relayEnabled = false }
            let broker = RelayBroker(credentials: credentials, panes: { [source, repoReviewPane("target", kind: .claude)] }, paste: { _, _ in }, submit: { _, _ in })
            try repoReviewExpect(broker.ticketPolicy(token: token, socketListening: true) == nil, "inactive pane retained an accepting policy")
            try repoReviewExpect(broker.agentIdentity(token: token).status == 403, "inactive source could authenticate")
            try repoReviewExpect(broker.handle(token: token, target: "target", text: "fixture").status == 403, "inactive source could relay")
            try repoReviewExpect(broker.handleDelegate(token: token, target: "target", text: "fixture").status == 403, "inactive source could delegate")
            try repoReviewExpect(broker.delegationStatus(token: token).status == 403, "inactive source could read tracked work")
            try repoReviewExpect(broker.handleAnswer(token: token, consultationID: "current", text: "fixture").status == 403, "inactive source could answer")
            try repoReviewExpect(broker.handleDelegationProgress(token: token, handoffID: "current", text: "fixture").status == 403, "inactive source could report progress")
            try repoReviewExpect(broker.handleDelegationResult(token: token, handoffID: "current", text: "fixture", succeeded: true).status == 403, "inactive source could complete work")
            try repoReviewExpect(broker.cancelHandoff(token: token, handoffID: "current").status == 403, "inactive source could cancel work")
        }
    }),
    ("repository review launch snapshots retain reviewed permissions and Claude facts", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("app")
        let settings = root.appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"sandbox":{"enabled":false}}"#.utf8).write(to: settings)
        let controller = try WorkbenchController(applicationDirectory: app, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
        try controller.bootstrap(cwd: root.path)
        let credentials = try RelayCredentials(file: app.appendingPathComponent("tokens.json"))
        controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("info"), shimDirectory: app.appendingPathComponent("bin"), transportDirectory: root.appendingPathComponent("transport"), credentials: credentials))
        let store = PermissionProfileStore(file: app.appendingPathComponent("permission-profiles.json"))
        let original = PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }!.clone(id: "custom-review", name: "Reviewed")
        try store.saveCustom(original)
        let profile = try PermissionProfileResolver.resolve(definition: original, paneFolder: root.path)
        let first = try controller.createPane(kind: .codex, cwd: root.path, permissionProfile: profile)
        let second = try controller.createPane(kind: .claude, cwd: root.path, permissionProfile: profile)
        let snapshot = controller.hostClaudeSandbox(for: second)
        try repoReviewExpect(snapshot?.enabled == false, "Claude launch configuration was not captured")
        let edited = PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!.clone(id: original.id, name: "Edited")
        try store.saveCustom(edited)
        try Data(#"{"sandbox":{"enabled":true}}"#.utf8).write(to: settings)
        try controller.terminalDidChangeWorkingDirectory(paneID: second.id, path: root.appendingPathComponent("other").path)
        _ = try controller.launchConfiguration(for: first.id)
        try repoReviewExpect(controller.runningPermissionDefinitions()[first.id] == original, "an edit between review and surface creation changed launch permissions")
        let currentClaude = try controller.listPanes().first { $0.id == second.id }!
        try repoReviewExpect(controller.hostClaudeSandbox(for: currentClaude) == snapshot, "settings or terminal cwd changed the running sandbox fact")
        try store.deleteCustom(id: original.id)
        let tree = GitWorktreeRecord(path: root.path, head: "fixture", branch: "main", isDetached: false, lockReason: nil, pruneReason: nil, isPrimary: true)
        let collisions = WorktreeWriterCollisionProjection.collisions(panes: [first, second], launchProfiles: controller.runningPermissionDefinitions(), worktrees: [tree], paneWorktreePaths: [first.id: root.path, second.id: root.path])
        try repoReviewExpect(collisions.count == 1 && collisions[0].writers.count == 2, "profile deletion hid existing writers")
    }),
    ("repository review container bypass is included in writer warnings", {
        var first = repoReviewPane("one"), second = repoReviewPane("two")
        let config = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///synthetic.sock", daemonID: "synthetic", imageID: "sha256:" + String(repeating: "a", count: 64), imageName: "fixture", legacyCodexSandbox: false, bypassVendorPermissions: true)
        first.containerConfiguration = config; second.containerConfiguration = config
        let tree = GitWorktreeRecord(path: "/repo", head: "fixture", branch: "main", isDetached: false, lockReason: nil, pruneReason: nil, isPrimary: true)
        let readOnly = PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!
        let collisions = WorktreeWriterCollisionProjection.collisions(panes: [first, second], launchProfiles: [first.id: readOnly, second.id: readOnly], worktrees: [tree], paneWorktreePaths: [first.id: tree.path, second.id: tree.path])
        try repoReviewExpect(collisions.count == 1 && collisions[0].writers.count == 2, "bypass containers were treated as read-only")
    }),
    ("repository review failed context save publishes nothing", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("reviews"), backup = root.appendingPathComponent("backup")
        let file = directory.appendingPathComponent("store.json")
        let store = try AgentContextReviewStore(file: file)
        var review = AgentContextReview(sourcePaneID: "source", sourcePaneName: "source", sourcePaneKind: .codex, sourceFolder: root.path,
            pack: ContextPack(name: "fixture", origin: .agentProposed), state: .awaitingReview)
        try store.record(review)
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("obstruction".utf8).write(to: directory)
        review.state = .approved
        try repoReviewRefuses { try store.record(review) }
        try repoReviewExpect(store.reviews().first?.state == .awaitingReview, "a failed save published approval")
        try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: backup, to: directory)
        try store.record(AgentContextReview(sourcePaneID: "source", sourcePaneName: "source", sourcePaneKind: .codex, sourceFolder: root.path, pack: ContextPack()))
        try repoReviewExpect(try AgentContextReviewStore(file: file).reviews().first { $0.id == review.id }?.state == .awaitingReview, "an unrelated save persisted the failed approval")
    }),
    ("repository review handoff retention never resurrects pruned history", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let token = try credentials.token(for: "source")
        let file = root.appendingPathComponent("handoffs.jsonl")
        let journal = try RelayHandoffJournal(file: file, maximumHandoffs: 1)
        let broker = RelayBroker(credentials: credentials, panes: { [repoReviewPane("source"), repoReviewPane("target", kind: .claude)] }, paste: { _, _ in }, submit: { _, _ in })
        for text in ["first", "second"] {
            try repoReviewExpect(broker.handle(token: token, target: "target", text: text).status == 200, "fixture delivery failed")
            journal.record(broker.handoffs().first { $0.text == text }!)
        }
        try repoReviewExpect(journal.handoffs().count == 1, "fixture did not prune")
        try journal.updateMaximumHandoffs(2)
        try repoReviewExpect(try RelayHandoffJournal(file: file, maximumHandoffs: 2).handoffs().count == 1, "increasing retention resurrected a record")
    }),
    ("repository review partial retention failure reconciles and retries", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let token = try credentials.token(for: "source")
        let handoffs = try RelayHandoffJournal(file: root.appendingPathComponent("handoffs.jsonl"))
        let activityDirectory = root.appendingPathComponent("activity"), backup = root.appendingPathComponent("saved-activity")
        let activity = try RelayActivityJournal(file: activityDirectory.appendingPathComponent("events.jsonl"))
        let policyStore = CollaborationHistoryRetentionStore(file: root.appendingPathComponent("retention.json"))
        let broker = RelayBroker(credentials: credentials, panes: { [repoReviewPane("source"), repoReviewPane("target", kind: .claude)] }, paste: { _, _ in }, submit: { _, _ in }, handoffJournal: handoffs, activityJournal: activity, historyRetentionStore: policyStore)
        for index in 0..<101 {
            try repoReviewExpect(broker.handle(token: token, target: "target", text: "fixture \(index)").status == 200, "fixture delivery failed")
            _ = try broker.recordActivity(RelayActivityEventRequest(kind: .workspaceCreated, workspaceID: "fixture", workspaceName: "fixture"))
        }
        try FileManager.default.moveItem(at: activityDirectory, to: backup)
        try Data("obstruction".utf8).write(to: activityDirectory)
        var partial: CollaborationHistoryRetentionPartialFailure?
        do { _ = try broker.updateCollaborationHistoryRetention(maximumRecords: 100) }
        catch let error as CollaborationHistoryRetentionPartialFailure { partial = error }
        try repoReviewExpect(partial?.change.removedHandoffs == 1 && partial?.failures.count == 1, "partial completion was not disclosed")
        try repoReviewExpect(broker.handoffs().count == 100 && broker.activityEvents().count == 101, "broker did not reconcile the committed journal")
        try repoReviewExpect(try policyStore.policy().maximumRecords == 100 && broker.collaborationHistoryRetentionPolicy().maximumRecords == 100, "saved and in-memory policy diverged")
        try FileManager.default.removeItem(at: activityDirectory); try FileManager.default.moveItem(at: backup, to: activityDirectory)
        let retried = try broker.updateCollaborationHistoryRetention(maximumRecords: 100)
        try repoReviewExpect(retried.removedHandoffs == 0 && retried.removedActivityEvents == 1 && broker.activityEvents().count == 100, "reapplying the policy did not finish maintenance")
    }),
    ("repository review Git identity preserves whitespace and newline paths", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let runner = ProcessCommandRunner(timeout: 5)
        for name in ["trailing ", "embedded\nline", "trailing\n", "trailing\r", "trailing\t"] {
            let folder = root.appendingPathComponent(name)
            for arguments in [["init", "-q", folder.path], ["-C", folder.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture", "--allow-empty"]] {
                let result = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, environment: environment)
                try repoReviewExpect(result.status == 0, "git fixture failed: \(result.stderrText)")
            }
            let expected = GitWorktreeResolver.canonicalPath(folder.path)
            try repoReviewExpect(GitWorktreeResolver(environment: environment).repository(in: folder.path)?.currentWorktreePath == expected, "discovery corrupted \(name.debugDescription)")
            let service = ManagedWorktreeService(store: ManagedWorktreeStore(file: root.appendingPathComponent("managed.json")), environment: environment)
            try repoReviewExpect(try service.identity(of: folder.path).toplevel == expected, "managed identity corrupted \(name.debugDescription)")
            let facts = DelegationGitSnapshotCapture(environment: environment, managedWorktreeLookup: { path in
                path == expected ? ManagedWorktreeEvidence(path: path, branch: "fixture", baseCommit: nil, parleyCreated: false) : nil
            }).snapshot(in: folder.path)
            try repoReviewExpect(facts?.managedWorktree?.path == expected, "delegation attributed the wrong worktree root")
            try Data("fixture".utf8).write(to: folder.appendingPathComponent("change.txt"))
            _ = try ContextPackBuilder(environment: environment).gitDiff(in: folder.path)
            _ = try ReviewDraftBuilder(environment: environment).changes(in: folder.path)
        }
    }),
    ("repository review request fields pin directories and reject symlinks and special files", {
        let root = try repoReviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("endpoint/processing/request")
        for path in ["endpoint", "endpoint/processing", "endpoint/processing/request"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let body = directory.appendingPathComponent("body")
        try Data("fixture".utf8).write(to: body)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: body.path)
        let fields = try RelayRequestFields(runtimeDirectory: root, components: ["endpoint", "processing", "request"])
        try repoReviewExpect(try fields.read("body", maximumBytes: 7) == "fixture", "valid request field was refused")
        try repoReviewExpect(try fields.read("missing", maximumBytes: 7, optional: true) == nil, "optional absent field was not absent")
        try repoReviewRefuses { _ = try fields.read("body", maximumBytes: 6) }
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        try repoReviewExpect(try fields.read("body", maximumBytes: 7) == "fixture", "renaming the request directory redirected its descriptor")
        try repoReviewRefuses { _ = try RelayRequestFields(runtimeDirectory: root, components: ["endpoint", "processing", "request"]) }
        let pinnedBody = moved.appendingPathComponent("body")
        try FileManager.default.removeItem(at: pinnedBody)
        let external = root.appendingPathComponent("outside-endpoint")
        try Data("outside".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: pinnedBody, withDestinationURL: external)
        try repoReviewRefuses { _ = try fields.read("body", maximumBytes: 100) }
        try FileManager.default.removeItem(at: pinnedBody)
        try repoReviewExpect(mkfifo(pinnedBody.path, 0o600) == 0, "could not create FIFO fixture")
        try repoReviewRefuses { _ = try fields.read("body", maximumBytes: 100) }
    }),
]

private final class LowReviewSyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = true
    func consume() -> Bool { lock.withLock { let value = fail; fail = false; return value } }
}
