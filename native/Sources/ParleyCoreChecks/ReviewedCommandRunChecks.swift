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
    ("reviewed command run automatic approval is a native switch that approves eligible requests as requested", reviewedRunAutomaticApprovalChecks),
    ("reviewed command run pane auto-close applies only to clean, saved, finished runs", reviewedRunPaneCloseChecks),
    ("reviewed command run authorization file is owner-only, validated and reads as off when untrusted", reviewedRunAuthorizationStoreChecks),
    ("reviewed command run pane cleanup closes only an ended pane of the created generation, across refreshes", reviewedRunPaneCleanupChecks),
    ("reviewed command run worker ends a clean run's pane only when its ticket says so", reviewedRunWorkerExitWhenCleanChecks),
    ("reviewed command run pane close survives a terminal transport that re-enters the workbench", reviewedRunReentrantCloseChecks),
    ("reviewed command run cleanup re-checks the kernel lease after a result arrives", reviewedRunLeaseOrderChecks),
    ("reviewed command run records from earlier releases still decode and load from the journal", reviewedRunLegacyDecodeChecks),
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

/// The person's Settings choice: with automatic approval on, an eligible
/// request is approved exactly as requested and needs no preview; turning
/// it on approves requests already waiting; turning it off restores per-run
/// approval at once, creates no session grant and never touches a run whose
/// requesting pane is no longer current.
func reviewedRunAutomaticApprovalChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-run-auto-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "",
        cwd: root.path, currentCommand: "codex", isActive: true, workspaceID: "workspace",
        relayEnabled: true, inputAvailable: true, launchGeneration: 3)
    var other = WorkbenchPane(id: "other", kind: .claude, customName: nil, terminalTitle: "",
        cwd: root.path, currentCommand: "claude", isActive: true, workspaceID: "workspace",
        relayEnabled: true, inputAvailable: true, launchGeneration: 1)
    var recorded: [ReviewedCommandRun] = []
    let coordinator = ReviewedCommandRunCoordinator(
        authenticate: { ["capability": "source", "other-capability": "other"][$0] },
        panes: { [source, other] }, record: { recorded.append($0) })
    let argv = ["/usr/bin/true"]
    try runExpect(!coordinator.automaticApprovalEnabled, "automatic approval was on by default")
    let waiting = try coordinator.request(token: "capability", argv: argv, folder: root.path)
    try runExpect(waiting.state == .pending, "a request was approved while automatic approval was off")
    let stale = try coordinator.request(token: "other-capability", argv: argv, folder: root.path)
    try runExpect(stale.state == .pending, "the second request was approved while automatic approval was off")
    // The other pane restarts before the switch is turned on: its waiting
    // request must not gain approval from the switch.
    other.launchGeneration += 1

    coordinator.setAutomaticApproval(true)
    try runExpect(coordinator.automaticApprovalEnabled, "the switch did not turn on")
    let approvedWaiting = coordinator.runs().first { $0.id == waiting.id }
    try runExpect(approvedWaiting?.state == .approved, "turning the switch on did not approve the waiting request (\(approvedWaiting?.state.rawValue ?? "missing"))")
    try runExpect(approvedWaiting?.command == waiting.requestedCommand, "automatic approval changed the requested command")
    try runExpect(approvedWaiting?.autoApprovalGrantID == nil && coordinator.grants().isEmpty, "automatic approval created a session grant")
    try runExpect(approvedWaiting?.detail?.contains("automatic") == true, "the run does not say it was approved automatically")
    let staleAfter = coordinator.runs().first { $0.id == stale.id }
    try runExpect(staleAfter?.state == .interrupted, "a request whose pane restarted was not left unapproved (\(staleAfter?.state.rawValue ?? "missing"))")
    try coordinator.cancel(id: waiting.id)

    let immediate = try coordinator.request(token: "capability", argv: ["/usr/bin/true", "again"], folder: root.path)
    try runExpect(immediate.state == .approved && immediate.autoApprovalGrantID == nil, "a new request was not approved automatically")
    try runExpect(immediate.detail?.contains("automatic") == true, "the new run does not say it was approved automatically")
    try runExpect(immediate.approvedAutomatically && approvedWaiting?.approvedAutomatically == true, "automatic approval was not recorded on the run itself")
    // The fact survives completion, when the detail becomes the capture summary.
    coordinator.launchApproved { _ in }
    coordinator.complete(id: immediate.id, result: ReviewedCommandRunResult(exitStatus: 0, stdout: Data(), stderr: Data()))
    let finished = coordinator.runs().first { $0.id == immediate.id }
    try runExpect(finished?.state == .completed && finished?.approvedAutomatically == true, "completion lost the automatic-approval fact")
    try runRejects { _ = try coordinator.request(token: "wrong", argv: argv, folder: root.path) }

    // A request approved by the switch but not yet launched (a sheet was
    // covering the terminal) must go back to waiting when the switch turns
    // off; a run the person approved by hand keeps its approval.
    let queued = try coordinator.request(token: "capability", argv: ["/usr/bin/true", "queued"], folder: root.path)
    try runExpect(queued.state == .approved && queued.approvedAutomatically, "the queued request was not approved by the switch")
    coordinator.setAutomaticApproval(false)
    try runExpect(!coordinator.automaticApprovalEnabled, "the switch did not turn off")
    let queuedAfter = coordinator.runs().first { $0.id == queued.id }
    try runExpect(queuedAfter?.state == .pending && queuedAfter?.approvedAutomatically == false, "turning the switch off left a queued automatic approval armed (\(queuedAfter?.state.rawValue ?? "missing"))")
    var launched: [String] = []
    coordinator.launchApproved { launched.append($0.id) }
    try runExpect(launched.isEmpty, "a queued automatic approval launched after the switch was turned off")
    try coordinator.cancel(id: queued.id)
    coordinator.setAutomaticApproval(true)
    let byHand = try coordinator.request(token: "other-capability", argv: argv, folder: root.path)
    // The other pane restarted earlier; a fresh request from its new generation is eligible again.
    try runExpect(byHand.state == .approved, "unexpected state for the second pane's request")
    try coordinator.cancel(id: byHand.id)
    coordinator.setAutomaticApproval(false)
    let handApproved = try coordinator.request(token: "other-capability", argv: ["/usr/bin/true", "hand"], folder: root.path)
    try coordinator.approve(id: handApproved.id, revision: handApproved.revision, argv: handApproved.command.argv, folder: root.path, autoApprove: false)
    coordinator.setAutomaticApproval(true)
    coordinator.setAutomaticApproval(false)
    try runExpect(coordinator.runs().first(where: { $0.id == handApproved.id })?.state == .approved, "turning the switch off revoked a human approval")
    try coordinator.cancel(id: handApproved.id)
    let manual = try coordinator.request(token: "capability", argv: argv, folder: root.path)
    try runExpect(manual.state == .pending && !manual.approvedAutomatically, "per-run approval did not return when the switch was turned off")
    try coordinator.approve(id: manual.id, revision: manual.revision, argv: argv, folder: root.path, autoApprove: false)
    try runExpect(coordinator.runs().first(where: { $0.id == manual.id })?.approvedAutomatically == false, "a human approval was recorded as automatic")
    try coordinator.cancel(id: manual.id)

    // Permanent stop wins over the switch.
    coordinator.setAutomaticApproval(true)
    coordinator.stop(reason: "Stop Everything")
    try runRejects { _ = try coordinator.request(token: "capability", argv: argv, folder: root.path) }
    source.launchGeneration += 1
    try runExpect(!recorded.isEmpty, "automatic approval left no durable transition")
}

/// The person's optional choice to close a run's Shell pane: only a run that
/// completed with exit 0, no signal, no cancellation, no truncated output, a
/// saved result and a worker that has already handed over to the ordinary
/// shell has nothing left to look at. Everything else keeps its pane.
func reviewedRunPaneCloseChecks() throws {
    typealias Policy = ReviewedCommandRunPaneClosePolicy
    func result(exit: Int32? = 0, signal: Int32? = nil, cancelled: Bool = false, truncated: Bool = false) -> ReviewedCommandRunResult {
        ReviewedCommandRunResult(exitStatus: exit, terminationSignal: signal, stdout: Data("ok".utf8), stderr: Data(), outputTruncated: truncated, cancelled: cancelled)
    }
    try runExpect(Policy.shouldClose(state: .completed, result: result(), resultSaved: true, workerStillRunning: false), "a clean finished run kept its pane")
    try runExpect(!Policy.shouldClose(state: .completed, result: result(exit: 1), resultSaved: true, workerStillRunning: false), "a failed command lost its pane")
    try runExpect(!Policy.shouldClose(state: .completed, result: result(truncated: true), resultSaved: true, workerStillRunning: false), "a run with truncated output lost its pane")
    try runExpect(!Policy.shouldClose(state: .cancelled, result: result(exit: nil, signal: 15, cancelled: true), resultSaved: true, workerStillRunning: false), "a cancelled run lost its pane")
    try runExpect(!Policy.shouldClose(state: .failed, result: result(exit: nil), resultSaved: true, workerStillRunning: false), "a run without an exit status lost its pane")
    try runExpect(!Policy.shouldClose(state: .completed, result: result(), resultSaved: false, workerStillRunning: false), "a run whose result was not saved lost its pane")
    try runExpect(!Policy.shouldClose(state: .completed, result: result(), resultSaved: true, workerStillRunning: true), "a pane was closed while its worker still held the lease")
    try runExpect(!Policy.shouldClose(state: .running, result: nil, resultSaved: false, workerStillRunning: true), "a running command lost its pane")
    try runExpect(!Policy.shouldClose(state: .completed, result: result(exit: 0, signal: 9), resultSaved: true, workerStillRunning: false), "a signalled run lost its pane")

    // The run overload reads the same facts from a real coordinator record.
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: root.path)
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    coordinator.launchApproved { _ in }
    try runExpect(coordinator.runs().first.map(Policy.shouldClose) == false, "a launched run was closable before it finished")
    coordinator.complete(id: request.id, result: result())
    guard let finished = coordinator.runs().first(where: { $0.id == request.id }) else { throw NSError(domain: "ReviewedCommandRun", code: 1, userInfo: [NSLocalizedDescriptionKey: "the finished run disappeared"]) }
    try runExpect(finished.state == .completed && finished.resultSaved && !finished.workerStillRunning, "unexpected finished run facts")
    try runExpect(Policy.shouldClose(finished), "the finished clean run was not closable")
    let failing = try coordinator.request(token: "capability", argv: ["/usr/bin/false"], folder: root.path)
    try coordinator.approve(id: failing.id, revision: failing.revision, argv: failing.command.argv, folder: root.path, autoApprove: false)
    coordinator.launchApproved { _ in }
    coordinator.complete(id: failing.id, result: result(exit: 1))
    try runExpect(coordinator.runs().first(where: { $0.id == failing.id }).map(Policy.shouldClose) == false, "a failed run was closable")
}

/// `approvedAutomatically` was added after runs were first journaled. A
/// record written by an earlier release has no such key and must decode as
/// "not automatic"; a record carrying a non-boolean value is still refused.
func reviewedRunLegacyDecodeChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-legacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let run = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: root.path)
    let encoded = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
    try runExpect(encoded.contains("\"approvedAutomatically\":false"), "the run did not encode its approval kind")
    let legacy = encoded.replacingOccurrences(of: "\"approvedAutomatically\":false,", with: "").replacingOccurrences(of: ",\"approvedAutomatically\":false", with: "")
    try runExpect(!legacy.contains("approvedAutomatically"), "the legacy fixture still carries the key")
    let decoded = try JSONDecoder().decode(ReviewedCommandRun.self, from: Data(legacy.utf8))
    try runExpect(decoded.id == run.id && !decoded.approvedAutomatically && decoded.state == .pending, "a legacy run did not decode as a manual run")
    let malformed = encoded.replacingOccurrences(of: "\"approvedAutomatically\":false", with: "\"approvedAutomatically\":\"yes\"")
    try runRejects { _ = try JSONDecoder().decode(ReviewedCommandRun.self, from: Data(malformed.utf8)) }

    // The same record nested in a handoff must load from an existing journal,
    // which is what the coordination core opens at startup.
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "source")
    let journalFile = root.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: journalFile)
    let broker = RelayBroker(credentials: credentials, panes: { [source] },
        paste: { _, _ in throw ReviewedCommandRunError.invalid("must not paste") },
        submit: { _, _ in throw ReviewedCommandRunError.invalid("must not submit") },
        handoffJournal: journal)
    broker.enableReviewedCommandRuns()
    guard let brokerRuns = broker.commandRuns else { throw ReviewedCommandRunError.invalid("Missing native run coordinator") }
    let recorded = try brokerRuns.request(token: token, argv: ["/usr/bin/true"], folder: root.path)
    let text = try String(contentsOf: journalFile, encoding: .utf8)
    try runExpect(text.contains("\"approvedAutomatically\":false"), "the journal record did not carry the approval kind")
    let legacyJournal = text.replacingOccurrences(of: "\"approvedAutomatically\":false,", with: "").replacingOccurrences(of: ",\"approvedAutomatically\":false", with: "")
    try Data(legacyJournal.utf8).write(to: journalFile)
    let reloaded = try RelayHandoffJournal(file: journalFile)
    let handoff = reloaded.handoffs().first { $0.id == recorded.id }
    try runExpect(handoff?.commandRun?.approvedAutomatically == false && handoff?.targetPaneID == recorded.shellPaneID, "an earlier release's command-run record did not load from the journal")
    try runExpect(reloaded.lastError == nil, "loading the legacy journal reported an error: \(reloaded.lastError ?? "")")
}

func reviewedRunAuthorizationStoreChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-auth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("private").appendingPathComponent(CommandRunAuthorizationStore.fileName)
    let store = CommandRunAuthorizationStore(file: file)
    try runExpect(store.load() == .off, "a missing file did not read as off without error")
    try store.save(automaticApproval: true, closeCleanPanes: false)
    var info = stat()
    try runExpect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "the authorization file is not owner-only")
    try runExpect(store.load() == .init(automaticApproval: true, closeCleanPanes: false, error: nil), "a saved choice did not round-trip")
    try store.save(automaticApproval: true, closeCleanPanes: true)
    try runExpect(store.load() == .init(automaticApproval: true, closeCleanPanes: true, error: nil), "the second choice did not round-trip")
    try runExpect(!FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).contains(where: { $0.hasSuffix(".tmp") }), "a temporary file was left behind")

    func expectOff(_ label: String) throws {
        let loaded = store.load()
        try runExpect(!loaded.automaticApproval && !loaded.closeCleanPanes && loaded.error != nil, "\(label) did not read as off with an explanation (\(loaded))")
    }
    try Data("not json".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try expectOff("a malformed file")
    try Data("{\"version\":1,\"automaticApproval\":\"yes\",\"closeCleanPanes\":true,\"updatedAt\":\"2026-09-06T18:00:00Z\"}".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try expectOff("a non-boolean value")
    try Data("{\"version\":2,\"automaticApproval\":true,\"closeCleanPanes\":true,\"updatedAt\":\"2026-09-06T18:00:00Z\"}".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try expectOff("an unsupported version")
    try store.save(automaticApproval: true, closeCleanPanes: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try expectOff("a group- or world-readable file")
    try FileManager.default.removeItem(at: file)
    let elsewhere = root.appendingPathComponent("elsewhere.json")
    try Data("{\"version\":1,\"automaticApproval\":true,\"closeCleanPanes\":true,\"updatedAt\":\"2026-09-06T18:00:00Z\"}".utf8).write(to: elsewhere)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: elsewhere.path)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
    try expectOff("a symbolic link")
    try FileManager.default.removeItem(at: file)
    try Data(String(repeating: " ", count: CommandRunAuthorizationStore.maximumBytes + 1).utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try expectOff("an oversized file")
    // An unprotected true value is never migrated from anywhere else.
    try FileManager.default.removeItem(at: file)
    try runExpect(store.load() == .off, "removing the file did not read as off")

    // A Settings change reports what really happened: turning on fails
    // closed, turning off always applies for this session and says when the
    // saved choice may return.
    typealias Change = CommandRunAuthorizationChange
    try runExpect(Change.outcome(turningOn: true, saveError: nil, setting: "X") == .init(applied: true, message: nil), "a saved enable was not applied")
    try runExpect(Change.outcome(turningOn: false, saveError: nil, setting: "X") == .init(applied: true, message: nil), "a saved disable was not applied")
    let failedOn = Change.outcome(turningOn: true, saveError: "disk full", setting: "X")
    try runExpect(!failedOn.applied && failedOn.message?.contains("remains off") == true, "a failed enable was applied or misreported: \(failedOn)")
    let failedOff = Change.outcome(turningOn: false, saveError: "disk full", setting: "X")
    try runExpect(failedOff.applied && failedOff.message?.contains("off for this session") == true && failedOff.message?.contains("may return") == true, "a failed disable was not applied for the session or misreported: \(failedOff)")
    // The store itself refuses to write into a file path it cannot own.
    let blocked = CommandRunAuthorizationStore(file: root.appendingPathComponent("blocked-dir").appendingPathComponent("x").appendingPathComponent(CommandRunAuthorizationStore.fileName))
    try Data().write(to: root.appendingPathComponent("blocked-dir"))
    try runRejects { try blocked.save(automaticApproval: false, closeCleanPanes: false) }
}

func reviewedRunPaneCleanupChecks() throws {
    typealias Cleanup = CommandRunPaneCleanup
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    func result(exit: Int32? = 0, truncated: Bool = false) -> ReviewedCommandRunResult {
        ReviewedCommandRunResult(exitStatus: exit, stdout: Data(), stderr: Data(), outputTruncated: truncated)
    }
    func launched(_ argv: [String]) throws -> ReviewedCommandRun {
        let request = try coordinator.request(token: "capability", argv: argv, folder: root.path)
        try coordinator.approve(id: request.id, revision: request.revision, argv: argv, folder: root.path, autoApprove: false)
        coordinator.launchApproved { _ in }
        return coordinator.runs().first { $0.id == request.id }!
    }
    func current(_ id: String) -> ReviewedCommandRun { coordinator.runs().first { $0.id == id }! }
    func pane(_ run: ReviewedCommandRun, generation: Int = 1, started: Bool = true, dead: Bool = false) -> Cleanup.PaneFacts {
        Cleanup.PaneFacts(id: run.shellPaneID, launchGeneration: generation, isStarted: started, isDead: dead)
    }

    // Clean run staged to exit: wait while running, wait while the lease is
    // held or the process lives, close once the created generation has ended.
    var cleanup = Cleanup()
    let clean = try launched(["/usr/bin/true"])
    cleanup.recordLaunch(runID: clean.id, paneID: clean.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: "source")
    try runExpect(cleanup.decisions(runs: [current(clean.id)], panes: [pane(clean)]).isEmpty, "a running command produced a decision")
    coordinator.complete(id: clean.id, result: result())
    var finished = current(clean.id)
    finished.workerStillRunning = true // observed before the lease released
    try runExpect(cleanup.decisions(runs: [finished], panes: [pane(finished)]) == [.wait(runID: clean.id)], "a held lease did not wait")
    try runExpect(!cleanup.isSettled(clean.id), "waiting settled the run")
    // Ghostty forces wait-after-command on every surface created with a
    // command, so the pane never reports its process as ended by itself: once
    // the worker's lease is released in exit-when-clean mode there is no
    // process behind the surface, and the pane is closed as it stands.
    let sourcePane = Cleanup.PaneFacts(id: "source", launchGeneration: 1, isStarted: true, isDead: false)
    try runExpect(cleanup.decisions(runs: [current(clean.id)], panes: [pane(finished), sourcePane]) == [.close(runID: clean.id, paneID: clean.shellPaneID, restoreTo: "source")], "a pane whose worker exited was not closed while Ghostty still showed it")
    try runExpect(cleanup.decisions(runs: [current(clean.id)], panes: [pane(finished, dead: true), sourcePane]) == [.close(runID: clean.id, paneID: clean.shellPaneID, restoreTo: "source")], "an ended pane was not closed with focus restore")
    // A predecessor that no longer exists and was never a run pane yields no target.
    try runExpect(cleanup.decisions(runs: [current(clean.id)], panes: [pane(finished, dead: true)]) == [.close(runID: clean.id, paneID: clean.shellPaneID, restoreTo: nil)], "a vanished non-run predecessor produced a restore target")
    try coordinator.cancel(id: clean.id)
    // Close failures retry then give up.
    try runExpect(!cleanup.didFailToClose(runID: clean.id) && !cleanup.didFailToClose(runID: clean.id), "gave up too early")
    try runExpect(cleanup.decisions(runs: [current(clean.id)], panes: [pane(finished, dead: true)]).count == 1, "a retry was not offered")
    try runExpect(cleanup.didFailToClose(runID: clean.id) && cleanup.isSettled(clean.id), "did not give up after the attempt limit")
    try runExpect(cleanup.decisions(runs: [current(clean.id)], panes: [pane(finished, dead: true)]).isEmpty, "a settled run was decided again")

    // Successful close settles; a restarted pane (new generation) is the person's.
    var second = Cleanup()
    let restarted = try launched(["/usr/bin/true", "restarted"])
    second.recordLaunch(runID: restarted.id, paneID: restarted.shellPaneID, paneGeneration: 4, exitsWhenClean: true, previousActivePaneID: nil)
    coordinator.complete(id: restarted.id, result: result())
    try runExpect(second.decisions(runs: [current(restarted.id)], panes: [pane(restarted, generation: 5, dead: true)]) == [.keep(runID: restarted.id, reason: "the pane was restarted by the person")], "a restarted pane was not kept")
    let closable = try launched(["/usr/bin/true", "closable"])
    second.recordLaunch(runID: closable.id, paneID: closable.shellPaneID, paneGeneration: 2, exitsWhenClean: true, previousActivePaneID: "elsewhere")
    coordinator.complete(id: closable.id, result: result())
    try runExpect(second.decisions(runs: [current(closable.id)], panes: [pane(closable, generation: 2, started: false), Cleanup.PaneFacts(id: "elsewhere", launchGeneration: 1, isStarted: true, isDead: false)]) == [.close(runID: closable.id, paneID: closable.shellPaneID, restoreTo: "elsewhere")], "an unstarted pane was not closable")
    second.didClose(runID: closable.id)
    try runExpect(second.isSettled(closable.id) && second.decisions(runs: [current(closable.id)], panes: []).isEmpty, "a closed run was decided again")

    // Everything else keeps its pane, once.
    var third = Cleanup()
    let handedOver = try launched(["/usr/bin/true", "shell"])
    third.recordLaunch(runID: handedOver.id, paneID: handedOver.shellPaneID, paneGeneration: 1, exitsWhenClean: false, previousActivePaneID: "source")
    coordinator.complete(id: handedOver.id, result: result())
    try runExpect(third.decisions(runs: [current(handedOver.id)], panes: [pane(handedOver, dead: true)]) == [.keep(runID: handedOver.id, reason: "the run's pane was handed to an interactive shell")], "a pane with an interactive shell was not kept")
    let failing = try launched(["/usr/bin/false"])
    third.recordLaunch(runID: failing.id, paneID: failing.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: nil)
    coordinator.complete(id: failing.id, result: result(exit: 1))
    try runExpect(third.decisions(runs: [current(failing.id)], panes: [pane(failing, dead: true)]) == [.keep(runID: failing.id, reason: "the run did not finish cleanly")], "a failed run was not kept")
    let truncated = try launched(["/usr/bin/true", "big"])
    third.recordLaunch(runID: truncated.id, paneID: truncated.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: nil)
    coordinator.complete(id: truncated.id, result: result(truncated: true))
    try runExpect(third.decisions(runs: [current(truncated.id)], panes: [pane(truncated, dead: true)]) == [.keep(runID: truncated.id, reason: "the run did not finish cleanly")], "a truncated run was not kept")
    let gone = try launched(["/usr/bin/true", "gone"])
    third.recordLaunch(runID: gone.id, paneID: gone.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: nil)
    coordinator.complete(id: gone.id, result: result())
    try runExpect(third.decisions(runs: [current(gone.id)], panes: []) == [.keep(runID: gone.id, reason: "the pane is already gone")], "a missing pane was not settled")
    let unknown = try launched(["/usr/bin/true", "unknown"])
    coordinator.complete(id: unknown.id, result: result())
    try runExpect(third.decisions(runs: [current(unknown.id)], panes: [pane(unknown, dead: true)]) == [.keep(runID: unknown.id, reason: "the run was not launched by this app session")], "an unrecorded launch was not kept")
    let seen = [handedOver, failing, truncated, gone, unknown].map { current($0.id) }
    try runExpect(third.decisions(runs: seen, panes: []).isEmpty, "settled runs were reported again")
    // Chains unwind newest first and resolve a vanished predecessor.
    // Person on A; run B created from A; run C created from B; both complete
    // at once with C active: close C (restore B), then B (restore A).
    var chain = Cleanup()
    let runB = try launched(["/usr/bin/true", "B"])
    chain.recordLaunch(runID: runB.id, paneID: runB.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: "A")
    coordinator.complete(id: runB.id, result: result()) // one active run per pane
    let runC = try launched(["/usr/bin/true", "C"])
    chain.recordLaunch(runID: runC.id, paneID: runC.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: runB.shellPaneID)
    coordinator.complete(id: runC.id, result: result())
    let both = [current(runB.id), current(runC.id)]
    let bothPanes = [pane(runB, dead: true), pane(runC, dead: true), Cleanup.PaneFacts(id: "A", launchGeneration: 1, isStarted: true, isDead: false), Cleanup.PaneFacts(id: "D", launchGeneration: 1, isStarted: true, isDead: false)]
    let simultaneous = chain.decisions(runs: both, panes: bothPanes)
    try runExpect(simultaneous == [.close(runID: runC.id, paneID: runC.shellPaneID, restoreTo: runB.shellPaneID), .close(runID: runB.id, paneID: runB.shellPaneID, restoreTo: "A")], "simultaneous completion did not unwind newest first: \(simultaneous)")
    chain.didClose(runID: runC.id)
    // After C's pane is gone, B's own restore still resolves to A.
    try runExpect(chain.restoreTarget(from: runB.shellPaneID, panes: bothPanes.filter { $0.id != runB.shellPaneID && $0.id != runC.shellPaneID }) == "A", "the chain did not resolve past a closed run pane")
    chain.didClose(runID: runB.id)
    // Staggered: B closed on an earlier tick while C was active, so C's
    // recorded predecessor B no longer exists; C must return to A, not to
    // whatever the controller picks.
    var staggered = Cleanup()
    let earlyB = try launched(["/usr/bin/true", "earlyB"])
    staggered.recordLaunch(runID: earlyB.id, paneID: earlyB.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: "A")
    coordinator.complete(id: earlyB.id, result: result())
    let lateC = try launched(["/usr/bin/true", "lateC"])
    staggered.recordLaunch(runID: lateC.id, paneID: lateC.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: earlyB.shellPaneID)
    let paneA = Cleanup.PaneFacts(id: "A", launchGeneration: 1, isStarted: true, isDead: false)
    let firstTick = staggered.decisions(runs: [current(earlyB.id), current(lateC.id)], panes: [pane(earlyB, dead: true), pane(lateC), paneA])
    try runExpect(firstTick == [.close(runID: earlyB.id, paneID: earlyB.shellPaneID, restoreTo: "A")], "the earlier run did not close on its own tick: \(firstTick)")
    staggered.didClose(runID: earlyB.id)
    coordinator.complete(id: lateC.id, result: result())
    let panesNow = [pane(lateC, dead: true), Cleanup.PaneFacts(id: "A", launchGeneration: 1, isStarted: true, isDead: false), Cleanup.PaneFacts(id: "D", launchGeneration: 1, isStarted: true, isDead: false)]
    let secondTick = staggered.decisions(runs: [current(earlyB.id), current(lateC.id)], panes: panesNow)
    try runExpect(secondTick == [.close(runID: lateC.id, paneID: lateC.shellPaneID, restoreTo: "A")], "the later run did not resolve its vanished predecessor to the original pane: \(secondTick)")
    // Nothing surviving up the chain means no restore, never a guess.
    try runExpect(staggered.restoreTarget(from: earlyB.shellPaneID, panes: [pane(lateC, dead: true)]) == nil, "an empty chain produced a restore target")
    try runExpect(staggered.restoreTarget(from: nil, panes: panesNow) == nil, "a nil predecessor produced a target")

    // The pure predicate agrees with the tracker's clean rule.
    try runExpect(ReviewedCommandRunPaneClosePolicy.isClean(result()) && !ReviewedCommandRunPaneClosePolicy.isClean(result(exit: 1)) && !ReviewedCommandRunPaneClosePolicy.isClean(result(truncated: true)), "isClean drifted")
}

func reviewedRunWorkerExitWhenCleanChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-exit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A stand-in login shell that announces itself, so the check can tell
    // whether the worker handed the pane over or ended it.
    let shell = root.appendingPathComponent("shell.sh")
    try Data("#!/bin/sh\nprintf SHELL-STARTED\n".utf8).write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { [source] }, record: { _ in })
    let directory = root.appendingPathComponent("approved-command-runs")
    var lastWorkerLifetime: TimeInterval = 0
    func run(_ argv: [String], exitWhenClean: Bool) throws -> (stdout: String, status: Int32, result: ReviewedCommandRunResult?) {
        let request = try coordinator.request(token: "capability", argv: argv, folder: root.path)
        try coordinator.approve(id: request.id, revision: request.revision, argv: argv, folder: root.path, autoApprove: false)
        var ticket: URL?
        coordinator.launchApproved { run in
            ticket = try ApprovedCommandWorker.stage(run: run, directory: directory, shellExecutable: shell.path,
                ownerPID: ProcessInfo.processInfo.processIdentifier, exitWhenClean: exitWhenClean)
        }
        guard let ticket else { throw ReviewedCommandRunError.invalid("No worker ticket") }
        let launchedAt = ProcessInfo.processInfo.systemUptime
        let output = try ProcessCommandRunner(timeout: 5).run(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: [ApprovedCommandWorker.argument, ticket.path], environment: ["PATH": "/usr/bin:/bin"])
        lastWorkerLifetime = ProcessInfo.processInfo.systemUptime - launchedAt
        let result = try ApprovedCommandWorker.result(runID: request.id, directory: directory)
        coordinator.complete(id: request.id, result: result ?? ReviewedCommandRunResult(exitStatus: nil, stdout: Data(), stderr: Data()))
        coordinator.serviceWorkers(directory: directory)
        return (output.stdoutText, output.status, result)
    }
    let cleanExit = try run(["/bin/sh", "-c", "printf clean-out"], exitWhenClean: true)
    // Ghostty treats an exit inside its abnormal-runtime threshold (250 ms by
    // default) as a failed launch and waits for a key; the worker must outlive it.
    try runExpect(lastWorkerLifetime >= ApprovedCommandWorker.minimumCleanExitRuntime, "a clean exit returned inside Ghostty's abnormal-runtime threshold (\(lastWorkerLifetime) s)")
    try runExpect(cleanExit.result?.exitStatus == 0 && cleanExit.result?.stdout == "clean-out", "the clean run did not publish its result")
    try runExpect(!cleanExit.stdout.contains("SHELL-STARTED") && cleanExit.stdout.contains("this pane closes") && cleanExit.status == 0,
        "a clean run staged to exit still handed the pane to a shell: \(cleanExit.stdout)")
    let failedExit = try run(["/bin/sh", "-c", "printf failed-out; exit 3"], exitWhenClean: true)
    try runExpect(failedExit.result?.exitStatus == 3 && failedExit.stdout.contains("SHELL-STARTED") && failedExit.stdout.contains("Returning to Shell"),
        "a failed run staged to exit did not hand the pane to a shell: \(failedExit.stdout)")
    let cleanShell = try run(["/bin/sh", "-c", "printf keep-out"], exitWhenClean: false)
    try runExpect(cleanShell.result?.exitStatus == 0 && cleanShell.stdout.contains("SHELL-STARTED"),
        "a clean run not staged to exit did not hand the pane to a shell: \(cleanShell.stdout)")
    // A ticket from an earlier build has no flag and keeps the shell handover.
    let legacy = "{\"resultKey\":\"\(Data(repeating: 1, count: 32).base64EncodedString())\",\"runID\":\"\(UUID().uuidString.lowercased())\",\"command\":{\"argv\":[\"/usr/bin/true\"],\"folder\":\"\(root.path)\"},\"sourceFolder\":\"\(root.path)\",\"shellExecutable\":\"/bin/sh\",\"ownerPID\":1,\"expiresAt\":0}"
    let decoded = try JSONDecoder().decode(ApprovedCommandTicket.self, from: Data(legacy.utf8))
    try runExpect(!decoded.exitInsteadOfShellWhenClean, "a legacy ticket did not default to handing over a shell")
}

/// Ghostty reports a surface close synchronously from inside the transport's
/// terminate call; that report marks the pane dead and triggers a refresh,
/// which may close other panes before the outer close finishes. The
/// workbench must remove the right pane even when the array changed under it.
func reviewedRunReentrantCloseChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-reenter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    _ = try controller.createWorkspace(folder: root.path)
    let keeper = try controller.createPane(kind: .shell, cwd: root.path)
    let first = try controller.createPane(kind: .shell, cwd: root.path)
    let second = try controller.createPane(kind: .shell, cwd: root.path)
    let expected = try controller.listPanes().map(\.id).filter { $0 != first.id && $0 != second.id }
    var terminated: [String] = []
    controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, interrupt: { _ in }, captureSelectedText: { _ in "" },
        terminate: { paneID in
            terminated.append(paneID)
            // The surface close report and a refresh that closes an earlier pane.
            try? controller.terminalDidClose(paneID: paneID, processAlive: false)
            if paneID == second.id { try? controller.closePane(first.id) }
        }, terminateAll: {}))
    try controller.closePane(second.id)
    let remaining = try controller.listPanes().map(\.id)
    // A lifecycle mutation must not be entered from inside a termination:
    // the nested close is refused, the outer close removes exactly its pane,
    // and the earlier pane is still there for a later, non-nested pass.
    try runExpect(remaining == expected + [first.id] || remaining == expected.filter { $0 != first.id } + [first.id] || Set(remaining) == Set(expected + [first.id]), "re-entrant close mutated other panes: \(remaining) vs \(expected + [first.id])")
    try runExpect(remaining.contains(keeper.id) && remaining.contains(first.id) && !remaining.contains(second.id), "the wrong pane was removed: \(remaining)")
    try runExpect(terminated == [second.id], "a nested close reached the transport: \(terminated)")
    try runExpect(!controller.isTerminatingSurface, "termination state leaked after the close")
    try controller.closePane(first.id)
    try runExpect(try controller.listPanes().map(\.id) == expected, "the deferred close did not remove the earlier pane")
    try runRejects { try controller.closePane(second.id) }

    // Restart and stop compute their target before terminating it; a nested
    // cleanup during termination must neither remove the target nor shift a
    // following pane into its place. Sentinel after the target, then target last.
    for targetLast in [false, true] {
        let sandbox = root.appendingPathComponent(targetLast ? "last" : "middle")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let lifecycle = try WorkbenchController(applicationDirectory: sandbox.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
        _ = try lifecycle.createWorkspace(folder: sandbox.path)
        let earlier = try lifecycle.createPane(kind: .shell, cwd: sandbox.path)
        // Middle case: the target is followed by a sentinel pane that a stale
        // index would hit; last case: nothing follows the target.
        let target = try lifecycle.createPane(kind: .codex, cwd: sandbox.path)
        let sentinel: WorkbenchPane? = targetLast ? nil : try lifecycle.createPane(kind: .shell, cwd: sandbox.path)
        try runExpect((try lifecycle.listPanes().last?.id == target.id) == targetLast, "fixture ordering drifted (targetLast \(targetLast))")
        var nestedRefusals = 0
        lifecycle.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, interrupt: { _ in }, captureSelectedText: { _ in "" },
            terminate: { paneID in
                try? lifecycle.terminalDidClose(paneID: paneID, processAlive: false)
                // A refresh inside the termination tries to clean up an earlier pane.
                do { try lifecycle.closePane(earlier.id) } catch { nestedRefusals += 1 }
            }, terminateAll: {}))
        let sentinelBefore = sentinel.map { s in try? lifecycle.listPanes().first { $0.id == s.id } } ?? nil
        let before = try lifecycle.listPanes().first { $0.id == target.id }!
        try lifecycle.restartPane(target.id)
        let afterRestart = try lifecycle.listPanes()
        let restarted = afterRestart.first { $0.id == target.id }
        try runExpect(restarted?.launchGeneration == before.launchGeneration + 1 && restarted?.isStarted == true && restarted?.isDead == false, "restart did not act on its own pane (targetLast \(targetLast)): \(String(describing: restarted))")
        if let sentinelBefore, let sentinelAfter = afterRestart.first(where: { $0.id == sentinelBefore.id }) {
            try runExpect(sentinelAfter.launchGeneration == sentinelBefore.launchGeneration && sentinelAfter.isStarted == sentinelBefore.isStarted, "restart mutated the following pane (targetLast \(targetLast))")
        }
        try runExpect(afterRestart.contains { $0.id == earlier.id }, "nested cleanup removed a pane during restart (targetLast \(targetLast))")
        try lifecycle.stopPaneProcess(target.id)
        let afterStop = try lifecycle.listPanes()
        let stopped = afterStop.first { $0.id == target.id }
        try runExpect(stopped?.isStarted == false && stopped?.currentCommand == "stopped" && stopped?.launchGeneration == before.launchGeneration + 2, "stop did not act on its own pane (targetLast \(targetLast)): \(String(describing: stopped))")
        if let sentinelBefore, let sentinelAfter = afterStop.first(where: { $0.id == sentinelBefore.id }) {
            try runExpect(sentinelAfter.launchGeneration == sentinelBefore.launchGeneration && sentinelAfter.isStarted == sentinelBefore.isStarted && sentinelAfter.currentCommand != "stopped", "stop mutated the following pane (targetLast \(targetLast))")
        }
        try runExpect(afterStop.contains { $0.id == earlier.id }, "nested cleanup removed a pane during stop (targetLast \(targetLast))")
        try runExpect(nestedRefusals == 2, "nested closes were not refused during restart and stop (targetLast \(targetLast)): \(nestedRefusals)")
    }

    // Two panes: the outer close passed the last-pane check; a nested close of
    // the other pane must be refused so a workspace never ends with no pane.
    let twoPaneRoot = root.appendingPathComponent("two")
    try FileManager.default.createDirectory(at: twoPaneRoot, withIntermediateDirectories: true)
    let two = try WorkbenchController(applicationDirectory: twoPaneRoot.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    _ = try two.createWorkspace(folder: twoPaneRoot.path)
    let seeded = try two.listPanes()
    let extra = try two.createPane(kind: .shell, cwd: twoPaneRoot.path)
    let others = try two.listPanes().filter { $0.id != extra.id }
    // Close every seeded pane but one so exactly two remain.
    for pane in others.dropFirst() { try two.closePane(pane.id) }
    let survivor = others.first!
    try runExpect(try two.listPanes().count == 2, "two-pane fixture did not settle at two panes (seeded \(seeded.count))")
    var nestedError: Error?
    two.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, interrupt: { _ in }, captureSelectedText: { _ in "" },
        terminate: { paneID in
            try? two.terminalDidClose(paneID: paneID, processAlive: false)
            if paneID == extra.id { do { try two.closePane(survivor.id) } catch { nestedError = error } }
        }, terminateAll: {}))
    try two.closePane(extra.id)
    try runExpect(nestedError != nil, "a nested close of the last other pane was not refused")
    let finalPanes = try two.listPanes()
    try runExpect(finalPanes.map(\.id) == [survivor.id] && (try two.listWorkspaces()).count == 1, "nested close emptied the workspace: \(finalPanes.map(\.id))")
}

/// serviceWorkers observes the lease before it reads a newly published
/// result, so a result that lands in between is recorded while the cached
/// "worker still running" flag is stale. Cleanup must therefore ask for a
/// fresh lease fact before closing, and the coordinator must re-observe after
/// recording a result; an unknown observation counts as held.
func reviewedRunLeaseOrderChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-run-lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = WorkbenchPane(id: "source", kind: .codex, customName: nil, terminalTitle: "", cwd: root.path,
        currentCommand: "codex", isActive: true, workspaceID: "workspace", relayEnabled: true)
    // The run's Shell pane must be listed, or the pending ticket is cancelled
    // as "Shell closed before the worker claimed its ticket" and discarded.
    var panes = [source]
    let coordinator = ReviewedCommandRunCoordinator(authenticate: { _ in "source" }, panes: { panes }, record: { _ in })
    let directory = root.appendingPathComponent("approved-command-runs")
    let request = try coordinator.request(token: "capability", argv: ["/usr/bin/true"], folder: root.path)
    panes.append(WorkbenchPane(id: request.shellPaneID, kind: .shell, customName: "Command run", terminalTitle: "", cwd: root.path,
        currentCommand: "sh", isActive: false, workspaceID: "workspace", relayEnabled: false))
    try coordinator.approve(id: request.id, revision: request.revision, argv: request.command.argv, folder: root.path, autoApprove: false)
    var ticket: URL?
    coordinator.launchApproved { run in
        ticket = try ApprovedCommandWorker.stage(run: run, directory: directory, shellExecutable: "/usr/bin/true",
            ownerPID: ProcessInfo.processInfo.processIdentifier, exitWhenClean: true)
    }
    guard let ticket else { throw ReviewedCommandRunError.invalid("No worker ticket") }
    let job = ticket.deletingLastPathComponent()
    // First observation: the ticket is pending and no worker holds the lease.
    coordinator.serviceWorkers(directory: directory)
    try runExpect(coordinator.runs().first?.workerStillRunning == false, "the pending ticket was observed as a running worker")
    // The worker acquires its lease and publishes a clean result before the
    // next observation; model the arrival with complete(), as the reader does.
    let lease = open(job.appendingPathComponent("worker.lock").path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try runExpect(lease >= 0, "could not acquire a test lease")
    defer { if lease >= 0 { close(lease) } }
    coordinator.complete(id: request.id, result: ReviewedCommandRunResult(exitStatus: 0, stdout: Data(), stderr: Data()))
    let stale = coordinator.runs().first { $0.id == request.id }
    try runExpect(stale?.state == .completed && stale?.resultSaved == true, "the modelled result was not recorded")
    // Cleanup asks for the fresh fact: held means not released, and the
    // record is corrected at the same time.
    try runExpect(!coordinator.workerLeaseReleased(id: request.id, directory: directory), "a held lease was reported as released")
    try runExpect(coordinator.runs().first(where: { $0.id == request.id })?.workerStillRunning == true, "the fresh lease fact did not correct the record")
    var cleanup = CommandRunPaneCleanup()
    cleanup.recordLaunch(runID: request.id, paneID: request.shellPaneID, paneGeneration: 1, exitsWhenClean: true, previousActivePaneID: "source")
    let facts = [CommandRunPaneCleanup.PaneFacts(id: request.shellPaneID, launchGeneration: 1, isStarted: true, isDead: false)]
    try runExpect(cleanup.decisions(runs: coordinator.runs(), panes: facts) == [.wait(runID: request.id)], "cleanup did not wait for the held lease")
    // The next ordinary observation agrees while the lease is held.
    coordinator.serviceWorkers(directory: directory)
    try runExpect(coordinator.runs().first(where: { $0.id == request.id })?.workerStillRunning == true, "a later observation lost the held lease")
    // An inspection that fails (job directory not traversable, then an
    // inaccessible ancestor) is not absence: the lease counts as held.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: job.path)
    try runExpect(!coordinator.workerLeaseReleased(id: request.id, directory: directory), "an untraversable job directory was reported as a released lease")
    try runExpect(coordinator.runs().first(where: { $0.id == request.id })?.workerStillRunning == true, "an inspection failure cleared the running flag")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: job.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    try runExpect(!coordinator.workerLeaseReleased(id: request.id, directory: directory), "an inaccessible ancestor was reported as a released lease")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try runExpect(!coordinator.workerLeaseReleased(id: request.id, directory: directory), "the held lease was lost after restoring access")
    // Release: the worker exited without a shell; now the pane may go.
    close(lease)
    try runExpect(coordinator.workerLeaseReleased(id: request.id, directory: directory), "a released lease was reported as held")
    try runExpect(cleanup.decisions(runs: coordinator.runs(), panes: facts).first.map { if case .close = $0 { true } else { false } } == true, "cleanup did not close after the lease was released")
    // A job directory that is already gone cannot hold a lease.
    coordinator.serviceWorkers(directory: directory)
    try runExpect(coordinator.workerLeaseReleased(id: request.id, directory: directory), "a discarded job was reported as a held lease")
    // An unreadable job directory is an unknown fact, which counts as held.
    let unknownRoot = root.appendingPathComponent("unknown")
    try FileManager.default.createDirectory(at: unknownRoot.appendingPathComponent(request.id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
    try runExpect(!coordinator.workerLeaseReleased(id: request.id, directory: unknownRoot), "an uninspectable job was reported as released")
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
