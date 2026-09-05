import Foundation
import ParleyCore

private func runExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ReviewedCommandRun", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func runRejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "ReviewedCommandRun", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsafe request was accepted"])
}

@MainActor
let reviewedCommandRunChecks: [(String, () throws -> Void)] = [
    ("reviewed command run approval attention presents once and respects dismissal", reviewedRunApprovalAttentionChecks),
    ("reviewed command run approval attention defers without losing requests", reviewedRunDeferredAttentionChecks),
    ("reviewed command run cleanup cannot disable coordination", reviewedRunCleanupIsolationChecks),
    ("reviewed command run kernel lease, cancel grace and history clearing", reviewedRunLeaseRecoveryChecks),
    ("history management never resurrects a cleared command run", reviewedRunClearedLateResultChecks),
    ("reviewed command run expired workers return a terminal failure", reviewedRunExpiredWorkerChecks),
    ("reviewed command run cancellation atomically prevents unclaimed launch", reviewedRunCancelUnclaimedChecks),
    ("reviewed command run grant revocation retains one-run human approval", reviewedRunGrantRevocationChecks),
    ("reviewed command run permanent shutdown cannot be reopened", reviewedRunStopChecks),
    ("reviewed command run noisy output and descendant cleanup remain bounded", reviewedRunNoisyCancellationChecks),
    ("reviewed command run worker captures and returns to Shell", reviewedRunWorkerProcessChecks),
    ("reviewed command run shim round trip and owned recovery", reviewedRunShimChecks),
    ("reviewed command run creates one new Shell without replay", reviewedRunNewPaneChecks),
    ("reviewed command run journal attribution", reviewedRunBrokerChecks),
    ("reviewed command run worker tickets require approval and are single-use", reviewedRunTicketChecks),
    ("reviewed command run bounded capture preserves whitespace", reviewedRunCaptureChecks),
    ("reviewed command run direct argv streams exit and cancellation", reviewedRunProcessChecks),
    ("reviewed command run approvals, exact grants and restart revocation", reviewedRunLifecycleChecks),
    ("reviewed command run approval fails closed on persistence failure", reviewedRunDurabilityChecks),
    ("reviewed command run preserves literal argv and validates contained folders", {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-run-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("project/subfolder")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let project = inside.deletingLastPathComponent()
        let link = project.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try runRejects { _ = try ReviewedCommand(argv: ["/usr/bin/printf", String(repeating: "\u{1}", count: 8_000)], folder: inside.path, sourceFolder: project.path) }
        let arguments = ["/usr/bin/printf", "%s", "", "literal;$(do-not-run)\nnext", "a b"]
        let command = try ReviewedCommand(argv: arguments, folder: inside.path, sourceFolder: project.path)
        try runExpect(command.argv == arguments, "argv changed or was shell-parsed")
        try runExpect(command.folder == inside.resolvingSymlinksInPath().path, "folder was not canonical")
        try runRejects { _ = try ReviewedCommand(argv: arguments, folder: outside.path, sourceFolder: project.path) }
        try runRejects { _ = try ReviewedCommand(argv: arguments, folder: link.path, sourceFolder: project.path) }
        try runRejects { _ = try ReviewedCommand(argv: ["printf"], folder: inside.path, sourceFolder: project.path) }
        try runRejects { _ = try ReviewedCommand(argv: ["/usr/bin/printf", "nul\0inside"], folder: inside.path, sourceFolder: project.path) }
        try runRejects { _ = try ReviewedCommand(argv: Array(repeating: "x", count: 129), folder: inside.path, sourceFolder: project.path) }
        try runRejects { _ = try ReviewedCommand(argv: ["/usr/bin/printf", String(repeating: "x", count: 20_000)], folder: inside.path, sourceFolder: project.path) }
    }),
    ("reviewed command run transport preserves empty and multiline arguments", {
        let expected = ["/usr/bin/printf", "", "a\nb", "'\\$()"]
        try runExpect(try ReviewedCommand.decodeArguments(expected.joined(separator: "\0") + "\0") == expected, "wire argv was changed")
        try runRejects { _ = try ReviewedCommand.decodeArguments("/usr/bin/printf") }
        try runRejects { _ = try ReviewedCommand.decodeArguments("") }
    }),
]

func reviewedRunLifecycleChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-run-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "",
        cwd: root.path, currentCommand: "codex", isActive: true, workspaceID: "workspace",
        relayEnabled: true, inputAvailable: true, launchGeneration: 7)
    var recorded: [ReviewedCommandRun] = []
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { $0 == "capability" ? "source" : nil },
        panes: { [source] }, record: { recorded.append($0) })
    let argv = ["/usr/bin/true"]
    try runRejects { _ = try coordinator.request(token: "wrong", argv: argv, folder: root.path) }
    let first = try coordinator.request(token: "capability", argv: argv, folder: root.path)
    try runExpect(first.state == .pending && coordinator.grants().isEmpty, "request acquired implicit approval")
    try runRejects { _ = try coordinator.request(token: "capability", argv: argv, folder: root.path) }
    try runRejects { try coordinator.approve(id: first.id, revision: "stale", argv: argv, folder: root.path, autoApprove: true) }
    try runExpect(coordinator.grants().isEmpty, "stale approval granted authority")
    try coordinator.approve(id: first.id, revision: first.revision, argv: argv, folder: root.path, autoApprove: true)
    try runExpect(coordinator.runs().first?.state == .approved && coordinator.grants().count == 1, "native approval was not recorded")
    try coordinator.cancel(id: first.id)
    let second = try coordinator.request(token: "capability", argv: argv, folder: root.path)
    try runExpect(second.state == .approved && second.autoApprovalGrantID != nil, "exact session grant was not reused")
    try coordinator.cancel(id: second.id)
    let changed = try coordinator.request(token: "capability", argv: ["/usr/bin/true", "different"], folder: root.path)
    try runExpect(changed.state == .pending, "different argv inherited approval")
    try coordinator.cancel(id: changed.id)
    if let grant = coordinator.grants().first { coordinator.revoke(grantID: grant.id) }
    let revoked = try coordinator.request(token: "capability", argv: argv, folder: root.path)
    try runExpect(revoked.state == .pending, "revoked grant remained active")
    try coordinator.approve(id: revoked.id, revision: revoked.revision, argv: argv, folder: root.path, autoApprove: true)
    source.launchGeneration += 1
    coordinator.reconcile()
    try runExpect(coordinator.grants().isEmpty, "grant survived source restart")
    try runExpect(coordinator.runs().first(where: { $0.id == revoked.id })?.state == .interrupted, "approval survived source restart")
    try runExpect(!recorded.isEmpty, "run lacked a durable handoff transition")
}

func reviewedRunDurabilityChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    var refuse = false
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] },
        record: { _ in if refuse { throw ReviewedCommandRunError.invalid("disk unavailable") } })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: root.path)
    refuse = true
    try runRejects { try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: true) }
    try runExpect(coordinator.runs().first?.state == .pending, "failed durable approval changed state")
    try runExpect(coordinator.grants().isEmpty, "failed durable approval created a grant")
}

func reviewedRunCaptureChecks() throws {
    let source = Data("  leading\n\n\nbox: ─ │\ntrailing  \n".utf8)
    let result = ReviewedCommandRunResult(exitStatus: 7, stdout: source, stderr: Data())
    try runExpect(result.stdout == String(decoding: source, as: UTF8.self), "capture changed whitespace or graphical content")

    let decorated = Data("\u{1B}[31mFAIL\u{1B}[0m \u{1B}]0;private title\u{7}plain".utf8)
    let clean = ReviewedCommandRunResult(exitStatus: 1, stdout: decorated, stderr: Data())
    try runExpect(clean.stdout == "FAIL plain", "capture retained terminal colour or title escape sequences")
    let huge = Data(String(repeating: "\"\\\0🙂", count: 40_000).utf8)
    let bounded = ReviewedCommandRunResult(exitStatus: 0, stdout: huge, stderr: huge)
    try runExpect(bounded.outputTruncated && bounded.text.utf8.count <= 90_000, "rendered result is unbounded")
    try runExpect(try JSONEncoder().encode(bounded).count <= 200_000, "escaped control response exceeds its transport cap")
    try runExpect(!bounded.stdout.contains("\0"), "unsafe control bytes survived result sanitization")
}

func reviewedRunProcessChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let literal = "literal;$(do-not-execute)\n'quoted' spaces"
    let command = try ReviewedCommand(argv: ["/usr/bin/printf", "%s", literal], folder: folder, sourceFolder: folder)
    let captured = try ApprovedCommandProcess.run(command, environment: ["PATH": "/usr/bin:/bin"])
    try runExpect(captured.exitStatus == 0 && captured.stdout == literal && captured.stderr.isEmpty, "argv was parsed or output was changed")
    let both = try ReviewedCommand(argv: ["/bin/sh", "-c", "printf out; printf err >&2; exit 7"], folder: folder, sourceFolder: folder)
    let output = try ApprovedCommandProcess.run(both, environment: ["PATH": "/usr/bin:/bin"])
    try runExpect(output.exitStatus == 7 && output.stdout == "out" && output.stderr == "err", "streams or nonzero exit were lost")
    let sleeper = try ReviewedCommand(argv: ["/bin/sleep", "30"], folder: folder, sourceFolder: folder)
    let started = Date()
    let cancelled = try ApprovedCommandProcess.run(sleeper, environment: ["PATH": "/usr/bin:/bin"], shouldCancel: { Date().timeIntervalSince(started) > 0.05 })
    try runExpect(cancelled.cancelled && Date().timeIntervalSince(started) < 3, "owned command did not stop on cancellation")
}

func reviewedRunTicketChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-run-ticket-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/printf", "%s", "$(literal)"], folder: root.path)
    let store = root.appendingPathComponent("approved-command-runs")
    try runRejects { _ = try ApprovedCommandWorker.stage(run: request, directory: store, shellExecutable: "/bin/zsh", ownerPID: ProcessInfo.processInfo.processIdentifier) }
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    var ticketPath: URL?
    coordinator.launchApproved { run in
        ticketPath = try ApprovedCommandWorker.stage(run: run, directory: store, shellExecutable: "/bin/zsh", ownerPID: ProcessInfo.processInfo.processIdentifier)
    }
    guard let ticketPath else { throw ReviewedCommandRunError.invalid("No approved worker ticket was created") }
    let first = try ApprovedCommandWorker.consume(ticketPath)
    try runExpect(first.runID == request.id && first.command.argv == request.command.argv, "ticket changed the approved command")
    try runRejects { _ = try ApprovedCommandWorker.consume(ticketPath) }
    let attributes = try FileManager.default.attributesOfItem(atPath: ticketPath.deletingLastPathComponent().path)
    try runExpect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "worker directory is not private")
    let link = root.appendingPathComponent("ticket.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ticketPath.deletingLastPathComponent().appendingPathComponent("consumed.json"))
    try runRejects { _ = try ApprovedCommandWorker.consume(link) }
}

func reviewedRunBrokerChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-broker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "source")
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let journal = try RelayHandoffJournal(file: root.appendingPathComponent("handoffs.jsonl"))
    let broker = RelayBroker(credentials: credentials, panes: { [source] },
        paste: { _, _ in throw ReviewedCommandRunError.invalid("must not paste into a shell") },
        submit: { _, _ in throw ReviewedCommandRunError.invalid("must not submit into an existing pane") },
        handoffJournal: journal)
    broker.enableReviewedCommandRuns()
    guard let coordinator = broker.commandRuns else { throw ReviewedCommandRunError.invalid("Missing native run coordinator") }
    let request = try coordinator.request(token: token, argv: ["/usr/bin/true"], folder: root.path)
    try runExpect(journal.handoffs().contains { $0.id == request.id && $0.targetPaneID == request.shellPaneID },
        "the request was not recorded as an ordinary attributed handoff")
}

func reviewedRunNewPaneChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-pane-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    let workspace = try controller.createWorkspace(folder: root.path)
    let alias = root.appendingPathComponent("linked-project")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let source = try controller.createPane(kind: .codex, cwd: alias.path)
    var eligible = source
    eligible.relayEnabled = true
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in source.id }, panes: { [eligible] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/printf", "%s", "$(agent-text); never-shell-parse"], folder: root.path)
    try runRejects { _ = try controller.createApprovedCommandPane(run: request, workerExecutable: URL(fileURLWithPath: "/usr/bin/true")) }
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    var created: WorkbenchPane?
    coordinator.launchApproved { run in
        created = try controller.createApprovedCommandPane(run: run, workerExecutable: URL(fileURLWithPath: "/usr/bin/true"))
    }
    guard let created else { throw ReviewedCommandRunError.invalid("The approved run did not create a new Shell pane.") }
    try runExpect(created.kind == .shell && created.id == request.shellPaneID && created.workspaceID == workspace.workspaceID, "run reused or misplaced a pane")
    let launch = try controller.launchConfiguration(for: created.id)
    try runExpect(launch.command.contains(ApprovedCommandWorker.argument) && !launch.command.contains("agent-text"), "agent argv entered Ghostty's command string")
    let next = try controller.launchConfiguration(for: created.id)
    try runExpect(!next.command.contains(ApprovedCommandWorker.argument), "recreating a surface replayed the command")
    let persisted = try String(contentsOf: root.appendingPathComponent("runtime/workbench-state.json"), encoding: .utf8)
    try runExpect(!persisted.contains(ApprovedCommandWorker.argument) && !persisted.contains("agent-text"), "persisted pane metadata contains execution authority")
}

private final class ReviewedRunOutputBox: @unchecked Sendable {
    let lock = NSLock()
    var value: Result<CommandOutput, Error>?
}
func reviewedRunShimChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-shim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "source")
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in })
    broker.enableReviewedCommandRuns()
    let coordinator = broker.commandRuns!
    let transportDirectory = root.appendingPathComponent("transport")
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { coordinator.stop(reason: "test ended"); transport.stop() }
    let bin = try RelayShim.install(in: root.appendingPathComponent("app"), transportDirectory: transportDirectory)
    let executable = bin.appendingPathComponent("parley")
    let arguments = ["/usr/bin/printf", "%s", "", "literal\n$();'\""]
    let box = ReviewedRunOutputBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let value = Result { try ProcessCommandRunner(timeout: 10).run(executable: executable,
            arguments: ["request-run", "--cwd", root.path, "--"] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token]) }
        box.lock.withLock { box.value = value }
        finished.signal()
    }
    let deadline = Date().addingTimeInterval(3)
    while coordinator.runs().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    guard let request = coordinator.runs().first else {
        _ = finished.wait(timeout: .now() + 2)
        throw ReviewedCommandRunError.invalid("The generated shim did not deliver an exact-argv request.")
    }
    try runExpect(request.state == .pending && request.command.argv == arguments, "shim changed argv or granted approval")
    let edited = ["/usr/bin/printf", "%s", "person-edited command"]
    try coordinator.approve(id: request.id, revision: request.revision, argv: edited, folder: root.path, autoApprove: false)
    coordinator.launchApproved { run in
        let output = try ApprovedCommandProcess.run(run.command, environment: ["PATH": "/usr/bin:/bin"])
        coordinator.complete(id: run.id, result: output)
    }
    try runExpect(finished.wait(timeout: .now() + 5) == .success, "request-run did not return captured output")
    let output = try box.lock.withLock { try box.value!.get() }
    try runExpect(output.status == 0, "shim reported transport failure: \(output.stdoutText) \(output.stderrText)")
    let result = try JSONDecoder().decode(ReviewedCommandRunResult.self, from: output.stdout)
    try runExpect(result.stdout == edited[2] && result.exitStatus == 0 && result.outsideAgentBoundary && result.approvedCommand?.argv == edited && result.approvedCommand?.folder == root.path, "result lost output, status or provenance")
    let recovered = broker.waitForTrackedWork(token: token, handoffID: request.id)
    try runExpect(recovered.status == 200, "same-generation run recovery failed")
    try runExpect(broker.waitForTrackedWork(token: "wrong", handoffID: request.id).status == 403, "another identity recovered the result")
}

func reviewedRunWorkerProcessChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/bin/sh", "-c", "printf worker-out; printf worker-err >&2; exit 7"], folder: root.path)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    var ticket: URL?
    let directory = root.appendingPathComponent("approved-command-runs")
    coordinator.launchApproved { run in
        ticket = try ApprovedCommandWorker.stage(run: run, directory: directory,
            shellExecutable: "/usr/bin/true", ownerPID: ProcessInfo.processInfo.processIdentifier)
    }
    guard let ticket else { throw ReviewedCommandRunError.invalid("No worker ticket") }
    let output = try ProcessCommandRunner(timeout: 5).run(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
        arguments: [ApprovedCommandWorker.argument, ticket.path], environment: ["PATH": "/usr/bin:/bin"])
    try runExpect(output.status == 0 && output.stdoutText.contains("worker-out") && output.stderrText.contains("worker-err"),
        "worker failed to mirror output and finish its ordinary-shell replacement: \(output.stderrText)")
    let result = try ApprovedCommandWorker.result(runID: request.id, directory: directory)
    try runExpect(result?.exitStatus == 7 && result?.stdout == "worker-out" && result?.stderr == "worker-err",
        "worker did not publish exact separate streams and exit status")
    try runRejects { _ = try ApprovedCommandWorker.consume(ticket) }

    // A command runs as the person, so a predictable result filename is not
    // sufficient evidence that the worker produced its bytes.
    let resultPath = directory.appendingPathComponent(request.id).appendingPathComponent("result.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: resultPath)) as! [String: Any]
    if let payload = object["payload"] as? String, let data = Data(base64Encoded: payload) {
        var inner = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        inner["exitStatus"] = 0
        object["payload"] = try JSONSerialization.data(withJSONObject: inner).base64EncodedString()
    } else { object["exitStatus"] = 0 }
    try JSONSerialization.data(withJSONObject: object).write(to: resultPath)
    try runRejects { _ = try ApprovedCommandWorker.result(runID: request.id, directory: directory) }
    coordinator.serviceWorkers(directory: directory)
    try runExpect(coordinator.runs().first?.state == .failed && !FileManager.default.fileExists(atPath: resultPath.deletingLastPathComponent().path),
        "an altered terminal result leaked job files or left the run active")
}

func reviewedRunStopChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: folder,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    coordinator.stop(reason: "application quit")
    coordinator.stop(reason: "transport shutdown", permanently: false)
    try runRejects { _ = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: folder) }
}

func reviewedRunNoisyCancellationChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let noisy = try ReviewedCommand(argv: ["/usr/bin/yes"], folder: folder, sourceFolder: folder)
    let start = Date()
    let result = try ApprovedCommandProcess.run(noisy, environment: ["PATH": "/usr/bin:/bin"],
        shouldCancel: { Date().timeIntervalSince(start) > 0.08 })
    try runExpect(result.cancelled && result.outputTruncated && result.stdout.utf8.count <= 30_000
        && Date().timeIntervalSince(start) < 3, "noisy output starved cancellation or escaped capture bounds")
    let descendants = try ReviewedCommand(argv: ["/bin/sh", "-c", "/bin/sleep 30 & exit 7"], folder: folder, sourceFolder: folder)
    let before = Date()
    let ended = try ApprovedCommandProcess.run(descendants, environment: ["PATH": "/usr/bin:/bin"])
    try runExpect(ended.exitStatus == 7 && Date().timeIntervalSince(before) < 3,
        "a descendant holding the output pipe prevented completion")
}

func reviewedRunGrantRevocationChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: folder,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: folder)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: folder, autoApprove: true)
    let grant = coordinator.grants().first!
    coordinator.revoke(grantID: grant.id)
    try runExpect(coordinator.runs().first?.state == .approved, "revocation removed this run's independent human approval")
}

func reviewedRunExpiredWorkerChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-expiry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/printf", "must-not-run"], folder: root.path)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    let directory = root.appendingPathComponent("approved-command-runs")
    var ticket: URL?
    coordinator.launchApproved { run in ticket = try ApprovedCommandWorker.stage(run: run, directory: directory,
        shellExecutable: "/usr/bin/true", ownerPID: ProcessInfo.processInfo.processIdentifier) }
    guard let ticket else { throw ReviewedCommandRunError.invalid("Missing ticket") }
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ticket)) as! [String: Any]
    object["expiresAt"] = -1_000
    try JSONSerialization.data(withJSONObject: object).write(to: ticket)
    _ = try ProcessCommandRunner(timeout: 5).run(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
        arguments: [ApprovedCommandWorker.argument, ticket.path], environment: ["PATH": "/usr/bin:/bin"])
    guard let result = try ApprovedCommandWorker.result(runID: request.id, directory: directory) else {
        throw ReviewedCommandRunError.invalid("An expired claimed ticket left no terminal worker result.")
    }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(request.id).appendingPathComponent("result.json"))
    coordinator.serviceWorkers(directory: directory)
    try runExpect(result.exitStatus == nil && result.stdout.isEmpty && coordinator.runs().first?.state == .failed,
        "an expired worker ran the command or left tracking active")
}

func reviewedRunCancelUnclaimedChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-cancel-ticket-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: root.path)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    let directory = root.appendingPathComponent("approved-command-runs")
    var ticket: URL?
    coordinator.launchApproved { run in ticket = try ApprovedCommandWorker.stage(run: run, directory: directory,
        shellExecutable: "/usr/bin/true", ownerPID: ProcessInfo.processInfo.processIdentifier) }
    guard let ticket else { throw ReviewedCommandRunError.invalid("Missing ticket") }
    try ApprovedCommandWorker.cancel(runID: request.id, directory: directory)
    try runRejects { _ = try ApprovedCommandWorker.consume(ticket) }
}

func reviewedRunLeaseRecoveryChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "source")
    let journalFile = root.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: journalFile)
    let broker = RelayBroker(credentials: credentials, panes: { [source] },
        paste: { _, _ in }, submit: { _, _ in }, handoffJournal: journal)
    broker.enableReviewedCommandRuns()
    guard let coordinator = broker.commandRuns else { throw ReviewedCommandRunError.invalid("Missing coordinator") }
    let request = try coordinator.request(token: token, argv: ["/bin/sleep", "30"], folder: root.path)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    let directory = root.appendingPathComponent("approved-command-runs")
    var path: URL?
    coordinator.launchApproved { run in path = try ApprovedCommandWorker.stage(run: run, directory: directory,
        shellExecutable: "/usr/bin/true", ownerPID: ProcessInfo.processInfo.processIdentifier) }
    guard let path else { throw ReviewedCommandRunError.invalid("Missing worker ticket") }
    let box = ReviewedRunOutputBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let value = Result { try ProcessCommandRunner(timeout: 6).run(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: [ApprovedCommandWorker.argument, path.path], environment: ["PATH": "/usr/bin:/bin"]) }
        box.lock.withLock { box.value = value }
        finished.signal()
    }
    defer { _ = try? ApprovedCommandWorker.cancel(runID: request.id, directory: directory); _ = finished.wait(timeout: .now() + 2) }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let observation = try ApprovedCommandWorker.observation(runID: request.id, directory: directory)
        if observation.running && observation.consumed { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    coordinator.serviceWorkers(directory: directory)
    try runExpect(coordinator.runs().first?.workerStillRunning == true, "a live worker had no kernel lease")
    try runExpect(try !ApprovedCommandWorker.discard(runID: request.id, directory: directory), "cleanup deleted a live worker's files")
    coordinator.cancellationHandler = { _ in throw ReviewedCommandRunError.invalid("simulated cancel write failure") }
    try coordinator.cancel(id: request.id)
    coordinator.serviceWorkers(directory: directory, at: Date().addingTimeInterval(6))
    try runExpect(coordinator.runs().first?.state == .cancelled && coordinator.runs().first?.workerStillRunning == true,
        "cancel grace lost the live worker or left the agent blocked")
    try runRejects { _ = try coordinator.request(token: token, argv: ["/usr/bin/true"], folder: root.path) }
    let transitions = journal.handoffs().first(where: { $0.id == request.id })!.transitions
    try runExpect(broker.deleteAllHistory().status == 200, "clear all failed")
    try runExpect(journal.handoffs().contains { $0.id == request.id },
        "clear all removed a cancelled run whose worker still holds its lease")
    try runExpect(broker.deleteWorkspaceHistory(workspaceID: "workspace").status == 200,
        "workspace clearing failed")
    try runExpect(journal.handoffs().contains { $0.id == request.id },
        "workspace clearing removed a worker-held run")
    try ApprovedCommandWorker.cancel(runID: request.id, directory: directory)
    try runExpect(finished.wait(timeout: .now() + 4) == .success, "the worker did not end on delivered cancellation")
    let output = try box.lock.withLock { try box.value!.get() }
    try runExpect(output.status == 0, "normal cancellation did not preserve Shell replacement")
    coordinator.serviceWorkers(directory: directory)
    let ended = coordinator.runs().first!
    try runExpect(ended.state == .cancelled && ended.result?.cancelled == true && ended.resultSaved
        && !ended.workerStillRunning && ended.detail?.contains("arrived after") == true,
        "a late result replaced cancellation or lost its capture")
    let recorded = journal.handoffs().first(where: { $0.id == request.id })!
    try runExpect(Array(recorded.transitions.prefix(transitions.count)) == transitions
        && recorded.transitions.count > transitions.count, "late capture lost the preserved transition history")
    try runExpect(broker.deleteAllHistory().status == 200 && journal.handoffs().isEmpty,
        "the finished worker could not be cleared")
    try runExpect(try RelayHandoffJournal(file: journalFile).handoffs().isEmpty,
        "finished command clearing was not durable")
    let replay = try coordinator.request(token: token, argv: request.requestedCommand.argv,
        folder: root.path, idempotencyKey: request.idempotencyKey)
    try runExpect(replay.id == request.id && replay.state == .cancelled && journal.handoffs().isEmpty,
        "clearing allowed an idempotent retry to execute again or recreate history")
    try runExpect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path),
        "completed worker files were not cleaned after its lease released")
}

func reviewedRunCleanupIsolationChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let bad = root.appendingPathComponent(UUID().uuidString.lowercased())
    try Data("stray file".utf8).write(to: bad)
    // Maintenance must not take coordination down because one job is unsafe.
    let warnings = ApprovedCommandWorker.removeAbandoned(in: root)
    try runExpect(warnings.count == 1, "unsafe cleanup entry was not reported")
}


func reviewedRunApprovalAttentionChecks() throws {
    var attention = ReviewedCommandRunAttention()
    let first = attention.update(pendingIDs: ["first"], reviewPresented: false, canPresent: true, applicationActive: true)
    try runExpect(first.presentRunID == "first" && !first.requestDockAttention,
                  "a new foreground approval did not open its preview")
    let dismissed = attention.update(pendingIDs: ["first"], reviewPresented: false, canPresent: true, applicationActive: true)
    try runExpect(dismissed.presentRunID == nil, "periodic refresh reopened a dismissed approval")
    let next = attention.update(pendingIDs: ["first", "next"], reviewPresented: false, canPresent: true, applicationActive: true)
    try runExpect(next.presentRunID == "next", "a new request reopened the old dismissed selection")

    // Opening the review manually counts immediately, even if it closes before
    // the next refresh. New rows must not replace an in-progress argument edit.
    attention.didPresent(runID: "manual")
    try runExpect(attention.update(pendingIDs: ["manual"], reviewPresented: false, canPresent: true, applicationActive: true).presentRunID == nil,
                  "manually reviewed request reopened after a quick dismissal")
    let editing = attention.update(pendingIDs: ["manual", "arrived"], reviewPresented: true, canPresent: true, applicationActive: true)
    try runExpect(editing.presentRunID == nil, "new request replaced the open review")
    try runExpect(attention.update(pendingIDs: ["arrived"], reviewPresented: false, canPresent: true, applicationActive: true).presentRunID == "arrived",
                  "approving one request lost another that arrived while editing")

    var batch = ReviewedCommandRunAttention()
    try runExpect(batch.update(pendingIDs: ["a", "b"], reviewPresented: false, canPresent: true, applicationActive: true).presentRunID == "a",
                  "the first request in a batch was not presented")
    try runExpect(batch.update(pendingIDs: ["b"], reviewPresented: false, canPresent: true, applicationActive: true).presentRunID == "b",
                  "deciding the first request suppressed the rest of the batch")
    _ = batch.update(pendingIDs: ["b", "c"], reviewPresented: true, canPresent: true, applicationActive: true)
    batch.didDismiss(pendingIDs: ["b", "c"])
    try runExpect(batch.update(pendingIDs: ["b", "c"], reviewPresented: false, canPresent: true, applicationActive: true).presentRunID == nil,
                  "explicit Done reopened another currently pending request")
    try runExpect(batch.update(pendingIDs: ["b", "c", "d"], reviewPresented: false, canPresent: true, applicationActive: true).presentRunID == "d",
                  "explicit Done suppressed a later new request")
}

func reviewedRunDeferredAttentionChecks() throws {
    var attention = ReviewedCommandRunAttention()
    let background = attention.update(pendingIDs: ["background"], reviewPresented: false, canPresent: true, applicationActive: false)
    try runExpect(background.presentRunID == nil && background.requestDockAttention,
                  "background request did not request attention without opening a sheet")
    let repeated = attention.update(pendingIDs: ["background"], reviewPresented: false, canPresent: true, applicationActive: false)
    try runExpect(!repeated.requestDockAttention && repeated.presentRunID == nil,
                  "background polling repeatedly requested attention")
    let blocked = attention.update(pendingIDs: ["background"], reviewPresented: false, canPresent: false, applicationActive: true)
    try runExpect(blocked.presentRunID == nil, "approval interrupted another dialog or unavailable main window")
    let available = attention.update(pendingIDs: ["background"], reviewPresented: false, canPresent: true, applicationActive: true)
    try runExpect(available.presentRunID == "background", "deferred approval was lost when the window became available")

    var removed = ReviewedCommandRunAttention()
    _ = removed.update(pendingIDs: ["expired"], reviewPresented: false, canPresent: false, applicationActive: true)
    let empty = removed.update(pendingIDs: [], reviewPresented: false, canPresent: true, applicationActive: true)
    try runExpect(empty.presentRunID == nil && !empty.requestDockAttention,
                  "expired or already approved work produced a stale approval prompt")
}

func reviewedRunClearedLateResultChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("parley-cleared-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "source")
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let journalFile = root.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: journalFile)
    let broker = RelayBroker(credentials: credentials, panes: { [source] },
        paste: { _, _ in }, submit: { _, _ in }, handoffJournal: journal)
    broker.enableReviewedCommandRuns()
    guard let coordinator = broker.commandRuns else { throw ReviewedCommandRunError.invalid("Missing coordinator") }
    let request = try coordinator.request(token: token, argv: ["/usr/bin/true"], folder: root.path)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv,
        folder: root.path, autoApprove: false)
    coordinator.launchApproved { _ in }
    coordinator.fail(id: request.id, detail: "Fixture tracking ended without a live worker")
    try runExpect(broker.deleteAllHistory().status == 200 && journal.handoffs().isEmpty,
        "terminal run could not be cleared")
    coordinator.complete(id: request.id,
        result: ReviewedCommandRunResult(exitStatus: 0, stdout: Data("late capture".utf8), stderr: Data()))
    try runExpect(journal.handoffs().isEmpty && (try RelayHandoffJournal(file: journalFile)).handoffs().isEmpty,
        "a late result resurrected a cleared command run")
    try runExpect(coordinator.runs().first?.result?.stdout == "late capture",
        "clearing history lost the requester's owned late result")
}
