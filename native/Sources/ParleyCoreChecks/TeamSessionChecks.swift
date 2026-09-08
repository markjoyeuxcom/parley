import Foundation
import ParleyCore

private func teamExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "TeamSession", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func teamRejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "TeamSession", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private struct TeamFixture {
    let root: URL
    let lead: WorkbenchPane
    var live: [WorkbenchPane]
    let profiles: [PermissionProfileDefinition]
    let recorded: RecordedTransitions

    final class RecordedTransitions: @unchecked Sendable {
        let lock = NSLock()
        var details: [String] = []
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("parley-team-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/module"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        lead = WorkbenchPane(id: "lead", kind: .claude, customName: "Lead", terminalTitle: "", cwd: root.appendingPathComponent("project").path,
            currentCommand: "claude", isActive: true, workspaceID: "workspace", relayEnabled: true, workspaceName: "Team",
            automationPolicy: .askAndDelegate, launchGeneration: 3)
        live = [lead]
        profiles = PermissionProfileDefinition.builtIns
        recorded = RecordedTransitions()
    }

    var project: String { root.appendingPathComponent("project").path }

    func coordinator(tokens: [String: String] = ["lead-token": "lead"], panes: @escaping () -> [WorkbenchPane]) -> TeamSessionCoordinator {
        let recorded = recorded
        return TeamSessionCoordinator(
            authenticate: { tokens[$0] },
            panes: { panes() },
            profiles: { [profiles] in profiles },
            record: { _, transition, _ in recorded.lock.withLock { recorded.details.append(transition.rawValue) } })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class FlakyBox: @unchecked Sendable {
    var failing = false
}

private final class PaneBox: @unchecked Sendable {
    let lock = NSLock()
    var panes: [WorkbenchPane]
    init(_ panes: [WorkbenchPane]) { self.panes = panes }
    func current() -> [WorkbenchPane] { lock.withLock { panes } }
    func update(_ change: (inout [WorkbenchPane]) -> Void) { lock.withLock { change(&panes) } }
}

func teamSessionProposalParsingChecks() throws {
    let proposal = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/project", "--panes", "2", "--hours", "12", "Ship", "the", "feature"])
    try teamExpect(proposal.objective == "Ship the feature" && proposal.folder == "/tmp/project" && proposal.paneLimit == 2 && proposal.hours == 12,
        "team request arguments were not parsed literally")
    try teamExpect(try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "x"]).paneLimit == TeamSessionProposal.defaultPaneLimit, "default pane limit drifted")
    try teamRejects("a relative folder was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "project", "objective"]) }
    try teamRejects("the retired --template option was folded into the objective") {
        _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/project", "--template", "Review pair", "Build feature"])
    }
    try teamRejects("a missing objective was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p"]) }
    try teamRejects("a pane limit above the maximum was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--panes", "9", "x"]) }
    try teamRejects("a deadline above 128 hours was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--hours", "129", "x"]) }
    try teamRejects("a zero pane limit was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--panes", "0", "x"]) }
    try teamRejects("control characters entered the objective") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "bad\u{1b}[31mtext"]) }
    let withWorktree = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--worktree", "feat/parser", "--base", "main", "Parse"])
    try teamExpect(withWorktree.worktreeBranch == "feat/parser" && withWorktree.worktreeBase == "main", "worktree options were not parsed literally")
    try teamExpect(try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "x"]).worktreeBranch == nil, "a proposal without --worktree carried one")
    try teamRejects("--base without --worktree was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--base", "main", "x"]) }
    try teamRejects("an option-shaped worktree branch was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--worktree", "--force", "x"]) }
    try teamRejects("a traversal worktree branch was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--worktree", "../x", "x"]) }
    try teamRejects("an option-shaped base ref was accepted") { _ = try TeamSessionProposal.parse(arguments: ["--folder", "/tmp/p", "--worktree", "ok", "--base", "-x", "x"]) }

    let add = try TeamPaneProvision.parse(arguments: ["--vendor", "Codex", "--name", "Reviewer", "--role", "reviewer"])
    try teamExpect(add.kind == .codex && add.name == "Reviewer" && add.role == "reviewer", "team add arguments were not parsed")
    try teamExpect(try TeamPaneProvision.parse(arguments: ["--vendor", "agy"]).name == "Agy", "a missing name did not default to the vendor label")
    try teamRejects("a shell was accepted as a team member") { _ = try TeamPaneProvision.parse(arguments: ["--vendor", "shell"]) }
    try teamRejects("a reserved role was accepted") { _ = try TeamPaneProvision.parse(arguments: ["--vendor", "codex", "--role", "lead"]) }
    try teamRejects("an unknown option was accepted") { _ = try TeamPaneProvision.parse(arguments: ["--vendor", "codex", "--cwd", "/x"]) }
}

func teamSessionRequestAndApprovalChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }

    try teamRejects("an unauthenticated request was accepted") {
        _ = try coordinator.request(token: "nope", proposal: TeamSessionProposal(objective: "x", folder: fixture.project, paneLimit: 2, hours: 4))
    }
    try teamRejects("a folder outside the lead's folder was accepted") {
        _ = try coordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "x", folder: fixture.root.appendingPathComponent("outside").path, paneLimit: 2, hours: 4))
    }
    let link = fixture.root.appendingPathComponent("project/escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("outside"))
    try teamRejects("a symlink escaping the lead's folder was accepted") {
        _ = try coordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "x", folder: link.path, paneLimit: 2, hours: 4))
    }

    var offPolicy = fixture.lead
    offPolicy.automationPolicy = .askAnswer
    box.update { $0 = [offPolicy] }
    try teamRejects("a workspace without delegation accepted a team request") {
        _ = try coordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "x", folder: fixture.project, paneLimit: 2, hours: 4))
    }
    box.update { $0 = [fixture.lead] }

    let proposal = TeamSessionProposal(objective: "Implement the parser", folder: fixture.root.appendingPathComponent("project/module").path, paneLimit: 2, hours: 4)
    let session = try coordinator.request(token: "lead-token", proposal: proposal, idempotencyKey: "req-1")
    try teamExpect(session.state == .pending && session.grantID == nil && coordinator.grant(for: session.id) == nil, "a request created authority before approval")
    try teamExpect(try coordinator.request(token: "lead-token", proposal: proposal, idempotencyKey: "req-1").id == session.id, "a replayed request was not idempotent")
    try teamRejects("a second concurrent session for one lead was accepted") {
        _ = try coordinator.request(token: "lead-token", proposal: proposal, idempotencyKey: "req-2")
    }
    try teamRejects("provisioning was possible before approval") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Reviewer", role: nil)
    }

    try teamRejects("approval accepted an unknown permission profile") {
        try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: proposal.folder, allowedVendors: [.codex], permissionProfileID: "missing", paneLimit: 2, hours: 4)
    }
    try teamRejects("approval accepted a shell vendor") {
        try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: proposal.folder, allowedVendors: [.shell], permissionProfileID: "default", paneLimit: 2, hours: 4)
    }
    try teamRejects("approval accepted a pane limit above the maximum") {
        try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: proposal.folder, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 9, hours: 4)
    }
    try teamRejects("approval accepted a folder outside the lead's folder") {
        try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: fixture.root.appendingPathComponent("outside").path, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 4)
    }
    try teamRejects("approval accepted a stale revision") {
        try coordinator.approve(id: session.id, revision: "stale", objective: "x", folder: proposal.folder, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 4)
    }
    try coordinator.approve(id: session.id, revision: session.revision, objective: "Implement the parser carefully", folder: fixture.project,
        allowedVendors: [.codex, .agy], permissionProfileID: "review-only", paneLimit: 2, hours: 1)
    guard let active = coordinator.sessions().first(where: { $0.id == session.id }), let grant = coordinator.grant(for: session.id) else {
        throw TeamSessionError.invalid("approval did not activate the session")
    }
    try teamExpect(active.state == .active && active.objective == "Implement the parser carefully" && active.folder == fixture.project
        && active.allowedVendors == [.codex, .agy] && active.permissionProfileID == "review-only" && active.paneLimit == 2
        && active.proposal == proposal, "human edits were not applied or the original proposal was lost")
    try teamExpect(grant.requesterPaneID == "lead" && grant.requesterGeneration == 3 && grant.workspaceID == "workspace" && grant.folder == fixture.project
        && grant.paneLimit == 2 && grant.provisioningDeadline.timeIntervalSinceNow <= 3_600 && grant.provisioningDeadline.timeIntervalSinceNow > 3_500,
        "the grant did not key the lead generation, workspace, folder, limit and deadline")
    try teamExpect(fixture.recorded.lock.withLock { fixture.recorded.details.contains("approved") }, "approval was not recorded")
    try teamRejects("a decided session could be approved again") {
        try coordinator.approve(id: session.id, revision: active.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 4)
    }
}

func teamSessionProvisioningLimitChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator(tokens: ["lead-token": "lead", "member-token": "member-1", "outsider-token": "outsider"]) { box.current() }
    let proposal = TeamSessionProposal(objective: "Build it", folder: fixture.project, paneLimit: 2, hours: 2)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: fixture.project,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 2)

    try teamRejects("a vendor outside the approved list was provisioned") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .agy, name: "Agy", role: nil)
    }
    let first = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Reviewer", role: "reviewer")
    try teamExpect(first.paneID == nil && first.failure == nil, "a provision was fulfilled without the native app")
    try teamRejects("a second provision was queued while one was pending") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Second", role: nil)
    }
    var createdCount = 0
    coordinator.fulfilProvisions { session, grant, provision in
        createdCount += 1
        try teamExpect(session.id == provision.sessionID && session.grantID == grant.id, "provision was not bound to its session and grant")
        try teamExpect(grant.folder == fixture.project && provision.kind == .codex && provision.role == "reviewer", "provision lost its approved values")
        let pane = WorkbenchPane(id: "member-\(createdCount)", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, role: provision.role, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }
    try teamExpect(createdCount == 1, "fulfilment did not create exactly one pane")
    guard let afterFirst = coordinator.sessions().first(where: { $0.id == session.id }) else { throw TeamSessionError.invalid("session vanished") }
    try teamExpect(afterFirst.members.count == 1 && afterFirst.members[0].paneID == "member-1" && afterFirst.members[0].requestedByPaneID == "lead"
        && afterFirst.members[0].grantID == afterFirst.grantID, "member provenance was not recorded")
    try teamExpect(coordinator.session(forToken: "member-token")?.id == session.id, "a member could not see its own session")

    try teamRejects("a team member provisioned a pane (recursive request)") {
        _ = try coordinator.requestPane(token: "member-token", kind: .codex, name: "Nested", role: nil)
    }
    try teamRejects("a team member requested a nested session") {
        _ = try coordinator.request(token: "member-token", proposal: proposal)
    }
    try teamRejects("an unrelated pane provisioned into the session") {
        _ = try coordinator.requestPane(token: "outsider-token", kind: .codex, name: "Outsider", role: nil)
    }

    let second = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Implementer", role: nil)
    coordinator.fulfilProvisions { _, _, provision in
        createdCount += 1
        let pane = WorkbenchPane(id: "member-\(createdCount)", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: fixture.project,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }
    try teamExpect(coordinator.sessions().first(where: { $0.id == session.id })?.members.count == 2, "second member was not recorded")
    try teamExpect(coordinator.provision(id: second.id)?.paneID == "member-2", "the provision did not expose its pane id")
    try teamRejects("the pane limit was exceeded") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Third", role: nil)
    }
    // Closing a created pane frees no budget: the limit bounds creations, not live panes.
    box.update { $0.removeAll { $0.id == "member-2" } }
    try teamRejects("closing a created pane refunded the creation budget") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Third", role: nil)
    }

    // A fulfilment failure is reported to the lead and consumes no budget.
    let limited = fixture.coordinator(tokens: ["lead-token": "lead"]) { box.current() }
    let limitedSession = try limited.request(token: "lead-token", proposal: proposal)
    try limited.approve(id: limitedSession.id, revision: limitedSession.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    let failing = try limited.requestPane(token: "lead-token", kind: .codex, name: "Broken", role: nil)
    limited.fulfilProvisions { _, _, _ in throw TeamSessionError.invalid("role collision") }
    try teamExpect(limited.provision(id: failing.id)?.failure?.contains("role collision") == true, "a creation failure was hidden")
    try teamExpect(limited.sessions().first(where: { $0.id == limitedSession.id })?.members.isEmpty == true, "a failed creation was counted as a member")
    _ = try limited.requestPane(token: "lead-token", kind: .codex, name: "Retry", role: nil)
}

func teamSessionInvalidationChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build it", folder: fixture.project, paneLimit: 3, hours: 2)

    // Lead restart invalidates the grant and refuses provisioning.
    let restarted = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: restarted.id, revision: restarted.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 3, hours: 2)
    box.update { $0[0].launchGeneration += 1 }
    try teamRejects("a restarted lead kept provisioning authority") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Reviewer", role: nil)
    }
    try teamExpect(coordinator.sessions().first(where: { $0.id == restarted.id })?.state == .interrupted && coordinator.grant(for: restarted.id) == nil,
        "lead restart did not interrupt the session")
    box.update { $0 = [fixture.lead] }

    // Policy change invalidates.
    let policy = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: policy.id, revision: policy.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 3, hours: 2)
    box.update { $0[0].automationPolicy = .askAnswer }
    coordinator.reconcile()
    try teamExpect(coordinator.sessions().first(where: { $0.id == policy.id })?.state == .interrupted && coordinator.grant(for: policy.id) == nil, "a policy change kept the grant")
    box.update { $0 = [fixture.lead] }

    // Folder change invalidates.
    let folder = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: folder.id, revision: folder.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 3, hours: 2)
    box.update { $0[0].cwd = fixture.root.appendingPathComponent("outside").path }
    coordinator.reconcile()
    try teamExpect(coordinator.sessions().first(where: { $0.id == folder.id })?.state == .interrupted, "a lead folder change kept the grant")
    box.update { $0 = [fixture.lead] }

    // Deadline expiry revokes the grant without touching panes.
    let expiring = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: expiring.id, revision: expiring.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 3, hours: 1)
    _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Reviewer", role: nil)
    coordinator.fulfilProvisions { _, _, provision in
        let pane = WorkbenchPane(id: "member-1", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: fixture.project,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }
    coordinator.reconcile(at: Date().addingTimeInterval(3_601))
    let expired = coordinator.sessions().first { $0.id == expiring.id }
    try teamExpect(expired?.state == .expired && coordinator.grant(for: expiring.id) == nil && expired?.members.count == 1, "expiry did not revoke the grant or lost provenance")
    try teamExpect(box.current().contains { $0.id == "member-1" }, "expiry removed a pane; only Stop may affect team-owned processes")
    try teamRejects("an expired session still provisioned") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Late", role: nil)
    }
    box.update { $0 = [fixture.lead] }

    // Removing the approved permission profile invalidates.
    let profileBox = PaneBox([fixture.lead])
    let profileless = TeamSessionCoordinator(authenticate: { $0 == "lead-token" ? "lead" : nil }, panes: { profileBox.current() },
        profiles: { [] }, record: { _, _, _ in })
    let profileSession = try profileless.request(token: "lead-token", proposal: proposal)
    try teamRejects("approval succeeded without any permission profile") {
        try profileless.approve(id: profileSession.id, revision: profileSession.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    }

    // A pending request expires after 30 minutes.
    let stale = try coordinator.request(token: "lead-token", proposal: proposal)
    coordinator.reconcile(at: Date().addingTimeInterval(31 * 60))
    try teamExpect(coordinator.sessions().first(where: { $0.id == stale.id })?.state == .interrupted, "a stale pending request did not expire")

    // Stop Everything ends every session permanently.
    let last = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: last.id, revision: last.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    coordinator.stopAll(reason: "Parley stopped")
    try teamExpect(coordinator.sessions().allSatisfy { $0.state.isTerminal } && coordinator.grant(for: last.id) == nil, "stopAll left a live grant")
    try teamRejects("a stopped coordinator accepted a request") { _ = try coordinator.request(token: "lead-token", proposal: proposal) }
}

func teamSessionStopChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let unrelated = WorkbenchPane(id: "unrelated", kind: .codex, customName: "Other", terminalTitle: "", cwd: fixture.project,
        currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
    let box = PaneBox([fixture.lead, unrelated])
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build it", folder: fixture.project, paneLimit: 2, hours: 2)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 2)
    _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Reviewer", role: nil)
    coordinator.fulfilProvisions { _, _, provision in
        let pane = WorkbenchPane(id: "member-1", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: fixture.project,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }
    let pending = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Second", role: nil)
    let affected = try coordinator.stop(id: session.id, reason: "Stopped by the person").map(\.paneID)
    try teamExpect(affected == ["member-1"], "Stop named panes other than the ones this session created: \(affected)")
    try teamExpect(!affected.contains("lead") && !affected.contains("unrelated"), "Stop affected the lead or an unrelated pane")
    let stopped = coordinator.sessions().first { $0.id == session.id }
    try teamExpect(stopped?.state == .stopped && coordinator.grant(for: session.id) == nil, "Stop did not revoke the grant")
    try teamExpect(coordinator.provision(id: pending.id)?.failure != nil, "a queued provision survived Stop")
    coordinator.fulfilProvisions { _, _, _ in throw TeamSessionError.invalid("must not be called after Stop") }
    try teamRejects("Stop could be applied twice") { _ = try coordinator.stop(id: session.id, reason: "again") }
    try teamRejects("provisioning continued after Stop") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Late", role: nil)
    }
    // The lead may start a new session after Stop.
    _ = try coordinator.request(token: "lead-token", proposal: proposal)
}

func teamSessionWaitChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator(tokens: ["lead-token": "lead", "other-token": "outsider"]) { box.current() }
    let proposal = TeamSessionProposal(objective: "Build it", folder: fixture.project, paneLimit: 1, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try teamExpect(coordinator.waitForDecision(token: "other-token", id: session.id).status == 403, "another pane recovered a session decision")
    let approver = Thread {
        Thread.sleep(forTimeInterval: 0.2)
        do {
            try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
        } catch {
            // Never let a regression hang the check: end every session so the wait returns.
            coordinator.stopAll(reason: "approval failed in check: \(error.localizedDescription)")
        }
    }
    approver.start()
    let decision = coordinator.waitForDecision(token: "lead-token", id: session.id)
    try teamExpect(decision.status == 200 && decision.text.contains("\"state\":\"active\"") && !decision.text.contains("token"), "the lead did not receive its approved session: \(decision.text)")
    let provision = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Reviewer", role: nil)
    let creator = Thread {
        Thread.sleep(forTimeInterval: 0.2)
        coordinator.fulfilProvisions { _, _, provision in
            WorkbenchPane(id: "member-1", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: fixture.project,
                currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        }
    }
    creator.start()
    let created = coordinator.waitForProvision(token: "lead-token", id: provision.id)
    try teamExpect(created.status == 200 && created.text.contains("member-1"), "the lead did not receive the created pane id: \(created.text)")
    let status = coordinator.status(token: "lead-token")
    try teamExpect(status.status == 200 && status.text.contains("\"panesCreated\":1"), "status did not report the session: \(status.text)")
    try teamExpect(coordinator.status(token: "other-token").status == 404, "an outsider saw a session status")

    let rejected = fixture.coordinator { box.current() }
    box.update { $0 = [fixture.lead] }
    let second = try rejected.request(token: "lead-token", proposal: proposal)
    try rejected.reject(id: second.id, revision: second.revision)
    let refused = rejected.waitForDecision(token: "lead-token", id: second.id)
    try teamExpect(refused.status == 409 && refused.text.contains("refused"), "a rejection was not reported to the lead: \(refused.text)")
}

func teamSessionNativePaneChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-team-pane-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    let shimDirectory = runtime.appendingPathComponent("bin", isDirectory: true)
    let transportDirectory = runtime.appendingPathComponent("relay", isDirectory: true)
    try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: transportDirectory, withIntermediateDirectories: true)
    controller.configureRelay(RelayRuntime(infoFile: runtime.appendingPathComponent("relay-url"), shimDirectory: shimDirectory,
        transportDirectory: transportDirectory, credentials: try RelayCredentials(file: runtime.appendingPathComponent("relay-tokens.json")), runtimeMarker: "DEV"))
    let workspace = try controller.createWorkspace(folder: root.appendingPathComponent("project").path)
    let lead = try controller.createPane(kind: .claude, cwd: root.appendingPathComponent("project").path)
    var eligible = lead
    eligible.relayEnabled = true
    let box = PaneBox([eligible])
    let coordinator = TeamSessionCoordinator(authenticate: { _ in lead.id }, panes: { box.current() },
        profiles: { PermissionProfileDefinition.builtIns }, record: { _, _, _ in })
    let proposal = TeamSessionProposal(objective: "Build it", folder: root.appendingPathComponent("project").path, paneLimit: 2, hours: 1)
    let session = try coordinator.request(token: "t", proposal: proposal)
    let provisionBeforeApproval = TeamPaneProvision(id: "p", sessionID: session.id, kind: .codex, name: "Reviewer", role: "reviewer", createdAt: Date(), paneID: nil, failure: nil)
    let defaultDefinition = PermissionProfileDefinition.builtIns.first { $0.id == "default" }!
    let defaultProfile = try PermissionProfileResolver.resolve(definition: defaultDefinition, paneFolder: proposal.folder)
    try teamRejects("the controller created a team pane without an active grant") {
        _ = try controller.createTeamPane(session: session, grant: TeamSessionGrant(id: "g", requesterPaneID: lead.id, requesterGeneration: lead.launchGeneration,
            workspaceID: workspace.workspaceID, automationPolicy: eligible.automationPolicy, folder: proposal.folder, allowedVendors: [.codex],
            approvedProfile: defaultDefinition, approvedRoots: [], paneLimit: 2, provisioningDeadline: Date().addingTimeInterval(60), approvedAt: Date()),
            provision: provisionBeforeApproval, permissionProfile: defaultProfile)
    }
    try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: proposal.folder, allowedVendors: [.codex], permissionProfileID: "review-only", paneLimit: 2, hours: 1)
    let firstRequest = try coordinator.requestPane(token: "t", kind: .codex, name: "Reviewer", role: "reviewer")
    var created: WorkbenchPane?
    coordinator.fulfilProvisions { session, grant, provision in
        // A profile resolved from anything but the approved snapshot is refused.
        try teamRejects("a profile under a different definition was accepted for creation") {
            _ = try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: defaultProfile)
        }
        let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots)
        let pane = try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
        created = pane
        box.update { $0.append(pane) }
        return pane
    }
    guard let created else { throw TeamSessionError.invalid("no pane was created: \(coordinator.provision(id: firstRequest.id)?.failure ?? "no failure recorded")") }
    try teamExpect(created.kind == .codex && created.customName == "Reviewer" && created.role == "reviewer" && created.workspaceID == workspace.workspaceID
        && created.cwd == proposal.folder && created.isStarted && created.permissionSelection?.profileID == "review-only",
        "the created pane did not carry the approved vendor, name, role, workspace, folder and profile")
    let persisted = try String(contentsOf: root.appendingPathComponent("runtime/workbench-state.json"), encoding: .utf8)
    try teamExpect(!persisted.contains("Build it") && !persisted.contains(session.id), "session authority or objective entered persisted workbench state")
    let launch = try controller.launchConfiguration(for: created.id)
    try teamExpect(launch.command.contains("codex") && !launch.command.contains("dangerously") && !launch.command.contains("danger-full-access"),
        "the team pane launch bypassed vendor permissions")
    // A role collision fails the provision instead of creating a second pane with the same role.
    _ = try coordinator.requestPane(token: "t", kind: .codex, name: "Duplicate", role: "reviewer")
    var duplicateFailure: String?
    coordinator.fulfilProvisions { session, grant, provision in
        do {
            let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots)
            return try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
        } catch { duplicateFailure = error.localizedDescription; throw error }
    }
    try teamExpect(duplicateFailure != nil && (try controller.listPanes()).filter { $0.role == "reviewer" }.count == 1, "a duplicate role was created")

    // Persistence failure is atomic: no pane, no member, no spent budget; a retry works.
    _ = try coordinator.requestPane(token: "t", kind: .codex, name: "Unpersisted", role: nil)
    let paneCountBefore = try controller.listPanes().count
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: runtime.path)
    var persistenceFailure: String?
    coordinator.fulfilProvisions { session, grant, provision in
        do {
            let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots)
            return try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
        } catch { persistenceFailure = error.localizedDescription; throw error }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    try teamExpect(persistenceFailure?.contains("not created") == true, "a persistence failure did not report atomically: \(persistenceFailure ?? "no error")")
    try teamExpect(try controller.listPanes().count == paneCountBefore, "an unpersisted pane remained in the live workbench")
    try teamExpect(coordinator.sessions().first(where: { $0.id == session.id })?.members.count == 1, "an unpersisted pane consumed budget or ownership")
    _ = try coordinator.requestPane(token: "t", kind: .codex, name: "Retried", role: nil)
    var retried: WorkbenchPane?
    coordinator.fulfilProvisions { session, grant, provision in
        let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots)
        let pane = try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
        retried = pane
        box.update { $0.append(pane) }
        return pane
    }
    try teamExpect(retried != nil && (try controller.listPanes()).count == paneCountBefore + 1, "creation did not recover after the persistence failure")

    // The real controller Stop path increments the generation; a stopped owned
    // generation must read as stopped, never as restarted by the person.
    guard let owning = coordinator.sessions().first(where: { $0.id == session.id }),
          let firstMember = owning.members.first(where: { $0.paneID == created.id }) else { throw TeamSessionError.invalid("member missing") }
    try teamExpect(TeamStopPlanner.plan(members: [firstMember], live: try controller.listPanes()).first?.action == .stop, "a running owned pane was not planned for stopping")
    try controller.stopPaneProcess(created.id)
    let afterStop = try controller.listPanes()
    try teamExpect(firstMember.ownership(of: afterStop.first { $0.id == created.id }) == .stopped, "a pane stopped through the controller was not recognised as the stopped owned generation")
    try teamExpect(TeamStopPlanner.plan(members: [firstMember], live: afterStop).first?.action == .skip(.alreadyStopped), "a stopped owned generation was planned again")
    try teamExpect(owning.currentPaneStates(in: afterStop).first { $0.paneID == created.id }?.ownedRunning == false, "a stopped pane was reported running")
    try controller.startPane(created.id)
    try teamExpect(firstMember.ownership(of: try controller.listPanes().first { $0.id == created.id }) == .restartedByPerson, "a person restart after Stop still counted as owned")

    // Editing the stored custom profile after approval revokes the grant and blocks native creation.
    let store = PermissionProfileStore(file: runtime.appendingPathComponent("permission-profiles.json"))
    let custom = PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!.clone(id: "custom-team", name: "Team review")
    try store.saveCustom(custom)
    let storeBacked = TeamSessionCoordinator(authenticate: { _ in lead.id }, panes: { box.current() },
        profiles: { try store.profiles() }, record: { _, _, _ in })
    let customSession = try storeBacked.request(token: "t", proposal: proposal)
    try storeBacked.approve(id: customSession.id, revision: customSession.revision, objective: "x", folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: custom.id, paneLimit: 1, hours: 1)
    guard let customGrant = storeBacked.grant(for: customSession.id) else { throw TeamSessionError.invalid("custom grant missing") }
    try teamExpect(customGrant.approvedProfile == custom, "the grant did not bind the approved definition")
    let edited = PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }!.clone(id: custom.id, name: custom.name)
    try store.saveCustom(edited)
    let activeCustom = storeBacked.sessions().first { $0.id == customSession.id }!
    let approvedProfile = try PermissionProfileResolver.resolve(definition: customGrant.approvedProfile, paneFolder: customGrant.folder, approvedRoots: customGrant.approvedRoots)
    try teamRejects("the controller created a pane after the approved profile was edited") {
        _ = try controller.createTeamPane(session: activeCustom, grant: customGrant,
            provision: TeamPaneProvision(id: "edited", sessionID: customSession.id, kind: .codex, name: "Edited", role: nil, createdAt: Date()),
            permissionProfile: approvedProfile)
    }
    storeBacked.reconcile()
    try teamExpect(storeBacked.sessions().first(where: { $0.id == customSession.id })?.state == .interrupted && storeBacked.grant(for: customSession.id) == nil,
        "an edited approved profile kept the grant alive")
}

private final class TeamOutputBox: @unchecked Sendable {
    let lock = NSLock()
    var value: Result<CommandOutput, Error>?
}

private func runShim(_ executable: URL, _ arguments: [String], token: String, extraEnvironment: [String: String] = [:]) -> (box: TeamOutputBox, finished: DispatchSemaphore) {
    let box = TeamOutputBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let value = Result { try ProcessCommandRunner(timeout: 15).run(executable: executable, arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token].merging(extraEnvironment) { $1 }) }
        box.lock.withLock { box.value = value }
        finished.signal()
    }
    return (box, finished)
}

func teamSessionShimChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-team-shim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project").path
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "lead")
    let lead = WorkbenchPane(id: "lead", kind: .claude, customName: "Lead", terminalTitle: "", cwd: project,
        currentCommand: "claude", isActive: true, workspaceID: "workspace", relayEnabled: true, workspaceName: "Team", automationPolicy: .askAndDelegate)
    let box = PaneBox([lead])
    let broker = RelayBroker(credentials: credentials, panes: { box.current() }, paste: { _, _ in }, submit: { _, _ in })
    broker.enableTeamSessions(profiles: { PermissionProfileDefinition.builtIns })
    let coordinator = broker.teamSessions!
    let transportDirectory = root.appendingPathComponent("transport")
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { coordinator.stopAll(reason: "test ended"); transport.stop() }
    let bin = try RelayShim.install(in: root.appendingPathComponent("app"), transportDirectory: transportDirectory)
    let executable = bin.appendingPathComponent("parley")

    let usage = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["team", "request", "--folder", project],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token])
    try teamExpect(usage.status == 2 && coordinator.sessions().isEmpty, "a request without an objective reached the broker")

    let request = runShim(executable, ["team", "request", "--folder", project, "--panes", "2", "--hours", "1", "Build", "the $(thing)"], token: token)
    let deadline = Date().addingTimeInterval(3)
    while coordinator.sessions().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    guard let pending = coordinator.sessions().first else {
        _ = request.finished.wait(timeout: .now() + 2)
        throw TeamSessionError.invalid("The generated shim did not deliver a team request.")
    }
    try teamExpect(pending.state == .pending && pending.proposal.objective == "Build the $(thing)" && pending.proposal.paneLimit == 2 && pending.grantID == nil,
        "the shim changed the proposal or created authority")
    try coordinator.approve(id: pending.id, revision: pending.revision, objective: "Build it carefully", folder: project,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 1)
    try teamExpect(request.finished.wait(timeout: .now() + 5) == .success, "team request did not return after approval")
    let approved = try request.box.lock.withLock { try request.box.value!.get() }
    try teamExpect(approved.status == 0, "shim reported failure: \(String(decoding: approved.stderr, as: UTF8.self))")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let view = try decoder.decode(TeamSession.AgentView.self, from: approved.stdout)
    try teamExpect(view.provisioningDeadline != nil && view.remainingProvisioningSeconds.map { $0 > 3_500 && $0 <= 3_600 } == true, "the deadline was not returned to the lead")
    try teamExpect(view.state == "active" && view.objective == "Build it carefully" && view.paneLimit == 2 && view.allowedVendors == ["codex"] && view.requesterPaneID == "lead",
        "the lead did not receive the approved values")
    try teamExpect(String(decoding: approved.stderr, as: UTF8.self).contains("Parley Team Session ID: \(pending.id)"), "the session id was not reported on stderr")
    try teamExpect(broker.waitForTrackedWork(token: token, handoffID: pending.id).status == 200, "parley wait could not recover the decision")
    try teamExpect(broker.waitForTrackedWork(token: "wrong", handoffID: pending.id).status == 403, "another identity recovered the decision")
    try teamExpect(broker.activityEvents().contains { $0.kind == .teamSessionApproved && $0.paneID == "lead" }, "approval was not recorded as native activity")

    let add = runShim(executable, ["team", "add", "--vendor", "codex", "--name", "Reviewer", "--role", "reviewer"], token: token)
    let addDeadline = Date().addingTimeInterval(3)
    while coordinator.pendingProvisions().isEmpty && Date() < addDeadline { Thread.sleep(forTimeInterval: 0.02) }
    try teamExpect(!coordinator.pendingProvisions().isEmpty, "the shim did not deliver a pane request")
    coordinator.fulfilProvisions { _, grant, provision in
        let pane = WorkbenchPane(id: "member-1", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, role: provision.role, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }
    try teamExpect(add.finished.wait(timeout: .now() + 5) == .success, "team add did not return after creation")
    let created = try add.box.lock.withLock { try add.box.value!.get() }
    try teamExpect(created.status == 0 && String(decoding: created.stdout, as: UTF8.self).contains("\"paneID\":\"member-1\""),
        "team add did not return the created pane: \(String(decoding: created.stdout + created.stderr, as: UTF8.self))")
    try teamExpect(String(decoding: created.stderr, as: UTF8.self).contains("Parley Pane Request ID: ")
        && String(decoding: created.stdout, as: UTF8.self).contains("\"provisionID\":\""), "team add did not announce a recoverable request id")

    // A repeated request identity returns the same pane instead of creating another,
    // and the announced id recovers the result after a disconnected shell.
    let replayKey = "replay-\(UUID().uuidString.lowercased())"
    let second = runShim(executable, ["team", "add", "--vendor", "codex", "--name", "Implementer"], token: token, extraEnvironment: ["PARLEY_IDEMPOTENCY_KEY": replayKey])
    let secondDeadline = Date().addingTimeInterval(3)
    while coordinator.pendingProvisions().isEmpty && Date() < secondDeadline { Thread.sleep(forTimeInterval: 0.02) }
    guard let secondProvision = coordinator.pendingProvisions().first else { throw TeamSessionError.invalid("the second pane request did not arrive") }
    coordinator.fulfilProvisions { _, grant, provision in
        let pane = WorkbenchPane(id: "member-2", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }
    try teamExpect(second.finished.wait(timeout: .now() + 5) == .success, "the second team add did not return")
    let secondOutput = try second.box.lock.withLock { try second.box.value!.get() }
    try teamExpect(secondOutput.status == 0 && String(decoding: secondOutput.stderr, as: UTF8.self).contains("Parley Pane Request ID: \(secondProvision.id)"),
        "the announced request id did not match the coordinator's: \(String(decoding: secondOutput.stderr, as: UTF8.self))")
    let replay = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["team", "add", "--vendor", "codex", "--name", "Implementer"],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token, "PARLEY_IDEMPOTENCY_KEY": replayKey])
    try teamExpect(replay.status == 0 && String(decoding: replay.stdout, as: UTF8.self).contains("\"paneID\":\"member-2\"")
        && coordinator.pendingProvisions().isEmpty && coordinator.sessions().first(where: { $0.id == pending.id })?.members.count == 2,
        "a replayed request identity created or queued a second pane: \(String(decoding: replay.stdout + replay.stderr, as: UTF8.self))")
    let recovered = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["wait", secondProvision.id],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token])
    try teamExpect(recovered.status == 0 && String(decoding: recovered.stdout, as: UTF8.self).contains("\"paneID\":\"member-2\""),
        "parley wait did not recover the pane request: \(String(decoding: recovered.stdout + recovered.stderr, as: UTF8.self))")

    let status = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["team", "status"],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token])
    try teamExpect(status.status == 0 && String(decoding: status.stdout, as: UTF8.self).contains("\"panesCreated\":2"), "team status did not report the session")
    // A launched pane's endpoint is prepared by the app at start; mirror that here.
    let memberToken = try credentials.token(for: "member-1")
    let memberEndpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: memberToken)
    // The shim refuses an endpoint until the transport's next heartbeat tick.
    let heartbeatDeadline = Date().addingTimeInterval(4)
    while !FileManager.default.fileExists(atPath: memberEndpoint.appendingPathComponent("heartbeat").path) && Date() < heartbeatDeadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    let memberStatus = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["team", "status"],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": memberToken])
    try teamExpect(memberStatus.status == 0 && String(decoding: memberStatus.stdout, as: UTF8.self).contains(pending.id),
        "a member could not see its session: \(memberStatus.status) \(String(decoding: memberStatus.stdout + memberStatus.stderr, as: UTF8.self))")

    let overLimit = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["team", "add", "--vendor", "codex"],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": token])
    try teamExpect(overLimit.status != 0 && String(decoding: overLimit.stdout + overLimit.stderr, as: UTF8.self).contains("limit"), "the pane limit was not enforced over the shim")
    let nested = try ProcessCommandRunner(timeout: 10).run(executable: executable, arguments: ["team", "add", "--vendor", "codex"],
        environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": memberToken])
    try teamExpect(nested.status != 0 && String(decoding: nested.stdout + nested.stderr, as: UTF8.self).contains("requesting pane"), "a member provisioned over the shim")
}

func teamSessionWorktreeBindingChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let tree = fixture.root.appendingPathComponent("project/.worktrees/feat-parser")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    let proposal = TeamSessionProposal(objective: "Parse", folder: fixture.project, paneLimit: 2, hours: 2, worktreeBranch: "feat/parser", worktreeBase: "main")
    let session = try coordinator.request(token: "lead-token", proposal: proposal, idempotencyKey: "wt-1")
    try teamExpect(session.proposal.worktreeBranch == "feat/parser" && session.worktree == nil, "a request bound a worktree before approval")
    let binding = TeamWorktreeBinding(path: tree.path, branch: "feat/parser", baseRef: "main", baseCommit: String(repeating: "a", count: 40), parleyCreated: true, managedRecordID: "rec")
    // The approved folder must be exactly the bound worktree, and containment still applies.
    try teamRejects("a binding whose path differs from the approved folder was accepted") {
        try coordinator.approve(id: session.id, revision: session.revision, objective: "Parse", folder: fixture.project, allowedVendors: [.codex],
            permissionProfileID: "default", paneLimit: 2, hours: 2, worktree: binding)
    }
    let outside = fixture.root.appendingPathComponent("outside")
    try teamRejects("a worktree outside the requester's folder was accepted") {
        try coordinator.approve(id: session.id, revision: session.revision, objective: "Parse", folder: outside.path, allowedVendors: [.codex],
            permissionProfileID: "default", paneLimit: 2, hours: 2,
            worktree: TeamWorktreeBinding(path: outside.path, branch: "x", baseRef: nil, baseCommit: nil, parleyCreated: false, managedRecordID: "r"))
    }
    try coordinator.approve(id: session.id, revision: session.revision, objective: "Parse", folder: tree.path, allowedVendors: [.codex],
        permissionProfileID: "default", paneLimit: 2, hours: 2, worktree: binding)
    guard let active = coordinator.sessions().first(where: { $0.id == session.id }), let grant = coordinator.grant(for: session.id) else {
        throw TeamSessionError.invalid("approval with a worktree did not activate the session")
    }
    try teamExpect(active.worktree == binding && grant.folder == WorkspaceFolderIdentity.matchingKey(tree.path) && grant.approvedRoots.allSatisfy { $0 == grant.folder },
        "the grant was not bound to exactly the worktree folder: \(grant.folder) roots \(grant.approvedRoots)")
    let view = active.agentView(live: box.current())
    try teamExpect(view.worktree?.branch == "feat/parser" && view.worktree?.baseCommit == binding.baseCommit && view.folder == grant.folder,
        "team status did not expose the worktree binding")
    try teamExpect(active.detail?.contains("worktree feat/parser created by Parley") == true, "the session detail did not name the worktree")
    // Preflight mirrors approval without mutating: a planned path that does not
    // exist yet is contained by its nearest existing ancestor; traversal,
    // escapes, stale revisions and unknown profiles are refused before any Git runs.
    let second = try TeamFixture()
    defer { second.cleanup() }
    let secondBox = PaneBox(second.live)
    let secondCoordinator = second.coordinator { secondBox.current() }
    let pending = try secondCoordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "Plan", folder: second.project, paneLimit: 1, hours: 1), idempotencyKey: "pre-1")
    let planned = second.root.appendingPathComponent("project/.worktrees/feat-x").path
    try secondCoordinator.preflightApproval(id: pending.id, revision: pending.revision, objective: "Plan", folder: planned, allowedVendors: [.codex],
        permissionProfileID: "default", paneLimit: 1, hours: 1, folderExists: false)
    try teamExpect(secondCoordinator.sessions().first { $0.id == pending.id }?.state == .pending && secondCoordinator.grant(for: pending.id) == nil, "preflight mutated the session")
    try teamRejects("preflight accepted a planned path escaping by traversal") {
        try secondCoordinator.preflightApproval(id: pending.id, revision: pending.revision, objective: "Plan", folder: second.project + "/.worktrees/../../outside/x",
            allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1, folderExists: false)
    }
    try teamRejects("preflight accepted a planned path outside the requester's folder") {
        try secondCoordinator.preflightApproval(id: pending.id, revision: pending.revision, objective: "Plan", folder: second.root.appendingPathComponent("outside/wt").path,
            allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1, folderExists: false)
    }
    let escapeLink = second.root.appendingPathComponent("project/.worktrees")
    try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: second.root.appendingPathComponent("outside"))
    try teamRejects("preflight accepted a planned path under a symlinked parent that escapes") {
        try secondCoordinator.preflightApproval(id: pending.id, revision: pending.revision, objective: "Plan", folder: planned,
            allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1, folderExists: false)
    }
    try FileManager.default.removeItem(at: escapeLink)
    try teamRejects("preflight accepted a stale revision") {
        try secondCoordinator.preflightApproval(id: pending.id, revision: "stale", objective: "Plan", folder: planned,
            allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1, folderExists: false)
    }
    try teamRejects("preflight accepted an unknown profile") {
        try secondCoordinator.preflightApproval(id: pending.id, revision: pending.revision, objective: "Plan", folder: planned,
            allowedVendors: [.codex], permissionProfileID: "missing", paneLimit: 1, hours: 1, folderExists: false)
    }
    // Older records without the field still decode, and the binding round-trips.
    let encoded = try JSONEncoder().encode(active)
    let decoded = try JSONDecoder().decode(TeamSession.self, from: encoded)
    try teamExpect(decoded.worktree == binding, "the worktree binding did not round-trip")
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    legacy.removeValue(forKey: "worktree")
    let legacySession = try JSONDecoder().decode(TeamSession.self, from: JSONSerialization.data(withJSONObject: legacy))
    try teamExpect(legacySession.worktree == nil && legacySession.id == active.id, "a record without a worktree field failed to decode")
}

@MainActor
let teamSessionChecks: [(String, () throws -> Void)] = [
    ("team session worktree binding is exact, contained and visible in status", teamSessionWorktreeBindingChecks),
    ("team session review regression changed profile revokes approval", teamSessionReviewProfileMutationCheck),
    ("team session review regression partial creation remains owned", teamSessionReviewPartialCreationCheck),
    ("team session review regression recovery requires original generation", teamSessionReviewRecoveryGenerationCheck),
    ("team session transitions carry trusted origin and correlation", teamSessionTransitionOriginChecks),
    ("team session requester is distinct from the workspace lead alias", teamSessionRequesterChecks),
    ("team session Stop results are structured and derived from pane state", teamSessionStopResultChecks),
    ("team session machine timestamps are ISO 8601 and detail is display-only", teamSessionTimestampChecks),
    ("team session stop recording failures are classified from real workbench state", teamSessionStopRecordingFailureChecks),
    ("team session diagnostics are byte-bounded and control-clean under the transport cap", teamSessionBoundedDiagnosticsChecks),
    ("team session native presentation never blocks on the session sheet", teamSessionPresentationChecks),
    ("team session ownership is pane id plus created generation and survives expiry", teamSessionOwnershipChecks),
    ("team session shim round trip, recovery and activity attribution", teamSessionShimChecks),
    ("team session proposal and add arguments are literal and bounded", teamSessionProposalParsingChecks),
    ("team session request needs an eligible lead and approval creates one bounded grant", teamSessionRequestAndApprovalChecks),
    ("team session provisioning enforces vendor, limit and lead-only rules", teamSessionProvisioningLimitChecks),
    ("team session grants are invalidated by restart, policy, folder, expiry and shutdown", teamSessionInvalidationChecks),
    ("team session Stop affects only team-owned panes", teamSessionStopChecks),
    ("team session waits, status and recovery are owner-only", teamSessionWaitChecks),
    ("team session native pane creation carries approved values only", teamSessionNativePaneChecks),
]

// Independent review regressions: failure paths beyond the happy-path checks.
func teamSessionReviewProfileMutationCheck() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let original = PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!.clone(id: "custom-review", name: "Custom review")
    var available = [original]
    let coordinator = TeamSessionCoordinator(authenticate: { $0 == "lead-token" ? "lead" : nil }, panes: { box.current() },
        profiles: { available }, record: { _, _, _ in })
    let proposal = TeamSessionProposal(objective: "Review", folder: fixture.project, paneLimit: 1, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: original.id, paneLimit: 1, hours: 1)
    available = [PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }!.clone(id: original.id, name: original.name)]
    coordinator.reconcile()
    try teamRejects("a changed profile retained the old human approval") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Worker", role: nil)
    }
}

func teamSessionReviewPartialCreationCheck() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 1, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Worker", role: nil)
    // AppModel commits controller creation (`create`) before Ghostty configuration
    // (`mount`) can throw. The pane exists either way and must stay owned.
    coordinator.fulfilProvisions(create: { _, grant, provision in
        let pane = WorkbenchPane(id: "partially-created", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    }, mount: { _, _ in
        throw TeamSessionError.invalid("Injected post-create Ghostty configuration failure")
    })
    guard let owned = coordinator.sessions().first(where: { $0.id == session.id }) else { throw TeamSessionError.invalid("session vanished") }
    try teamExpect(owned.members.count == 1 && owned.members[0].paneID == "partially-created" && owned.members[0].warning?.contains("Injected") == true,
        "a partially created pane was not owned with its mounting failure reported")
    try teamRejects("a mounting failure refunded the creation budget") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Second", role: nil)
    }
    let affected = try coordinator.stop(id: session.id, reason: "Review check")
    try teamExpect(!box.current().contains { $0.id == "partially-created" } || affected.map(\.paneID).contains("partially-created"),
        "a failed creation left an existing pane outside session ownership, Stop and its creation limit")
}

func teamSessionPresentationChecks() throws {
    typealias P = TeamProvisioningPresentation
    try teamExpect(P.allowsCreation(teamSheetPresented: true, commandRunsPresented: false, otherSheetAttached: true, modalWindowPresent: false, mainWindowVisible: true),
        "the Team Sessions sheet blocked provisioning while the person watched the session")
    try teamExpect(P.allowsCreation(teamSheetPresented: false, commandRunsPresented: false, otherSheetAttached: false, modalWindowPresent: false, mainWindowVisible: true),
        "an idle visible window refused provisioning")
    try teamExpect(!P.allowsCreation(teamSheetPresented: false, commandRunsPresented: false, otherSheetAttached: true, modalWindowPresent: false, mainWindowVisible: true),
        "an unrelated editable sheet was disturbed by provisioning")
    try teamExpect(!P.allowsCreation(teamSheetPresented: true, commandRunsPresented: true, otherSheetAttached: true, modalWindowPresent: false, mainWindowVisible: true),
        "a command-run approval preview was disturbed by provisioning")
    try teamExpect(!P.allowsCreation(teamSheetPresented: true, commandRunsPresented: false, otherSheetAttached: true, modalWindowPresent: true, mainWindowVisible: true),
        "a modal alert was disturbed by provisioning")
    try teamExpect(!P.allowsCreation(teamSheetPresented: false, commandRunsPresented: false, otherSheetAttached: false, modalWindowPresent: false, mainWindowVisible: false),
        "a hidden or miniaturized window created panes without any visible surface")
}

func teamSessionOwnershipChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 2, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 1)
    for name in ["Worker", "Reviewer"] {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: name, role: nil)
        coordinator.fulfilProvisions(create: { _, grant, provision in
            let pane = WorkbenchPane(id: "member-\(provision.name)", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
                currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate, launchGeneration: 4)
            box.update { $0.append(pane) }
            return pane
        })
    }
    guard let active = coordinator.sessions().first(where: { $0.id == session.id }) else { throw TeamSessionError.invalid("session vanished") }
    try teamExpect(active.members.map(\.launchGeneration) == [4, 4] && active.members.map(\.workspaceID) == ["workspace", "workspace"],
        "members did not record the created generation and workspace")
    // The person restarts Worker (new generation) and moves Reviewer to another workspace.
    box.update {
        $0[1].launchGeneration = 5
        $0[2].workspaceID = "elsewhere"
    }
    let owned = active.ownedRunningMembers(in: box.current())
    try teamExpect(owned.map(\.paneID) == ["member-Reviewer"], "ownership ignored a person restart or lost a moved pane: \(owned.map(\.paneID))")
    // Expiry ends provisioning but leaves an explicit human stop path for owned panes.
    coordinator.reconcile(at: Date().addingTimeInterval(3_601))
    try teamExpect(coordinator.sessions().first(where: { $0.id == session.id })?.state == .expired, "the provisioning deadline did not expire")
    try teamRejects("Stop session applied to an expired session") { _ = try coordinator.stop(id: session.id, reason: "late") }
    let survivors = try coordinator.ownedMembers(id: session.id)
    try teamExpect(survivors.map(\.paneID) == ["member-Worker", "member-Reviewer"], "owned members were unavailable after expiry")
    try teamRejects("provisioning resumed after expiry through the stop path") {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Late", role: nil)
    }
    coordinator.recordStopAttempt(id: session.id, attempt: TeamStopAttempt(reason: "Stopped by the person", outcomes: [
        TeamMemberStopOutcome(paneID: "member-Reviewer", launchGeneration: 4, name: "Reviewer", result: .stopped, message: nil),
        TeamMemberStopOutcome(paneID: "member-Worker", launchGeneration: 4, name: "Worker", result: .skippedRestarted, message: nil),
    ]))
    try teamExpect(coordinator.sessions().first(where: { $0.id == session.id })?.stopAttempts.last?.outcomes.map(\.result) == [.stopped, .skippedRestarted],
        "the structured stop attempt was not recorded")
    try teamRejects("a pending session exposed owned members") {
        let fresh = fixture.coordinator { box.current() }
        box.update { $0[0].launchGeneration = 3 }
        let pending = try fresh.request(token: "lead-token", proposal: proposal)
        _ = try fresh.ownedMembers(id: pending.id)
    }
}

func teamSessionReviewRecoveryGenerationCheck() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 1, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    let provision = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Worker", role: nil)
    coordinator.fulfilProvisions { _, grant, request in
        WorkbenchPane(id: "member", kind: request.kind, customName: request.name, terminalTitle: "", cwd: grant.folder,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
    }
    box.update { $0[0].launchGeneration += 1 }
    let recovered = coordinator.waitForProvision(token: "lead-token", id: provision.id)
    try teamExpect(recovered.status != 200, "a restarted lead recovered a previous generation's provisioning result")
}

// MARK: - PR #46 pre-merge corrections

private func teamBroker(root: URL, panes: @escaping () -> [WorkbenchPane]) throws -> (RelayBroker, RelayCredentials, RelayActivityJournal) {
    let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    let activity = try RelayActivityJournal(file: root.appendingPathComponent("activity-events.jsonl"))
    let journal = try RelayHandoffJournal(file: root.appendingPathComponent("handoffs.jsonl"))
    let broker = RelayBroker(credentials: credentials, panes: { panes() }, paste: { _, _ in }, submit: { _, _ in },
        handoffJournal: journal, activityJournal: activity)
    broker.enableTeamSessions(profiles: { PermissionProfileDefinition.builtIns })
    return (broker, credentials, activity)
}

func teamSessionTransitionOriginChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let (broker, credentials, activity) = try teamBroker(root: fixture.root) { box.current() }
    let token = try credentials.token(for: "lead")
    let coordinator = broker.teamSessions!
    let proposal = TeamSessionProposal(objective: "PRIVATE_OBJECTIVE build", folder: fixture.project, paneLimit: 2, hours: 1)
    let session = try coordinator.request(token: token, proposal: proposal)
    func events(_ kind: RelayActivityEventKind) -> [RelayActivityEvent] {
        broker.activityEvents().filter { $0.kind == kind && $0.teamSessionID == session.id }.sorted { $0.occurredAt < $1.occurredAt }
    }
    guard let requested = events(.teamSessionRequested).last else { throw TeamSessionError.invalid("no request event") }
    try teamExpect(requested.origin == .automation && requested.requesterPaneID == "lead" && requested.paneID == "lead",
        "an agent-initiated request was attributed to the person or lost its requester")
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 1)
    try teamExpect(events(.teamSessionApproved).last?.origin == .human, "a native approval was not attributed to the person")
    _ = try coordinator.requestPane(token: token, kind: .codex, name: "Worker", role: nil)
    coordinator.fulfilProvisions(create: { _, grant, provision in
        let pane = WorkbenchPane(id: "member-1", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
            currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate, launchGeneration: 2)
        box.update { $0.append(pane) }
        return pane
    })
    guard let created = events(.teamPaneCreated).last else { throw TeamSessionError.invalid("no pane-created event") }
    try teamExpect(created.origin == .automation && created.affectedPaneIDs == ["member-1"] && created.requesterPaneID == "lead",
        "an agent-requested creation was attributed to the person or lost the created pane id")
    let endedBefore = events(.teamSessionEnded).count
    let members = try coordinator.stop(id: session.id, reason: "Stopped by the person")
    try teamExpect(events(.teamSessionEnded).count == endedBefore + 1 && events(.teamSessionEnded).last?.origin == .human,
        "one Stop did not produce exactly one human session-ended event")
    coordinator.recordStopAttempt(id: session.id, attempt: TeamStopAttempt(reason: "Stopped by the person", outcomes: members.map {
        TeamMemberStopOutcome(paneID: $0.paneID, launchGeneration: $0.launchGeneration, name: $0.name, result: .stopped, message: nil)
    }))
    guard let attempt = events(.teamPaneStopAttempted).last else { throw TeamSessionError.invalid("no stop-attempt event") }
    try teamExpect(attempt.origin == .human && attempt.affectedPaneIDs == ["member-1"] && events(.teamSessionEnded).count == endedBefore + 1,
        "a pane stop attempt masqueraded as a session-ended event or lost the affected pane")
    coordinator.recordStopAttempt(id: session.id, attempt: TeamStopAttempt(reason: "retry", outcomes: [
        TeamMemberStopOutcome(paneID: "member-1", launchGeneration: 2, name: "Worker", result: .failed, message: "EACCES \(fixture.project)/PRIVATE_DIAGNOSTIC"),
    ]))
    for event in broker.activityEvents() where event.teamSessionID == session.id {
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        try teamExpect(!text.contains("PRIVATE_OBJECTIVE") && !text.contains(fixture.project) && !text.contains("PRIVATE_DIAGNOSTIC"),
            "an activity record carried the objective, folder or a stop diagnostic")
    }
    try teamExpect(events(.teamPaneStopAttempted).last?.detail?.contains("1 failed") == true, "the stop-attempt activity lost its counts")
    // Content-minimal agent projection carries identifiers only.
    let page = try JSONDecoder().decode(RelayAgentEventPage.self, from: Data(broker.agentEvents(token: token, since: "beginning").text.utf8))
    let projected = page.events.filter { $0.teamSessionID == session.id }
    try teamExpect(projected.contains { $0.activityKind == .teamPaneCreated && $0.affectedPaneIDs == ["member-1"] && $0.requesterPaneID == "lead" && $0.origin == .automation },
        "the agent event projection lost team correlation or origin")
    let raw = broker.agentEvents(token: token, since: "beginning").text
    try teamExpect(!raw.contains("PRIVATE_OBJECTIVE") && !raw.contains(fixture.project) && !raw.contains(token), "the events feed exposed content or credentials")
    // Older journal lines without the correlation fields still decode.
    let legacy = """
    {"id":"legacy","kind":"paneRestarted","occurredAt":0,"workspaceID":"workspace","workspaceName":"Team","origin":"human"}
    """
    let decoded = try JSONDecoder().decode(RelayActivityEvent.self, from: Data(legacy.utf8))
    try teamExpect(decoded.teamSessionID == nil && decoded.affectedPaneIDs == nil, "legacy activity decoding changed")
    // The durable journal round-trips the new fields through the file, not memory.
    _ = activity
    let reopened = try RelayActivityJournal(file: fixture.root.appendingPathComponent("activity-events.jsonl"))
    let persisted = reopened.events().first { $0.id == created.id }
    try teamExpect(persisted?.affectedPaneIDs == ["member-1"] && persisted?.origin == .automation && persisted?.teamSessionID == session.id
        && persisted?.requesterPaneID == "lead", "the activity journal dropped correlation or origin after reopening from disk")
    // Expiry and interruption are automation, never the person.
    let again = try coordinator.request(token: token, proposal: proposal)
    try coordinator.approve(id: again.id, revision: again.revision, objective: "x", folder: proposal.folder, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    coordinator.reconcile(at: Date().addingTimeInterval(3_601))
    try teamExpect(broker.activityEvents().last { $0.teamSessionID == again.id }?.origin == .automation, "expiry was attributed to the person")
}

func teamSessionRequesterChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let chief = WorkbenchPane(id: "chief", kind: .codex, customName: "Chief", terminalTitle: "", cwd: fixture.project, currentCommand: "codex",
        isActive: false, workspaceID: "workspace", relayEnabled: true, workspaceName: "Team", inputAvailable: true, isWorkspaceLead: true, automationPolicy: .askAndDelegate)
    let requester = WorkbenchPane(id: "pane-requester", kind: .claude, customName: "Requester", terminalTitle: "", cwd: fixture.project,
        currentCommand: "claude", isActive: true, workspaceID: "workspace", relayEnabled: true, workspaceName: "Team", inputAvailable: true,
        isWorkspaceLead: false, automationPolicy: .askAndDelegate, launchGeneration: 3)
    let box = PaneBox([requester, chief])
    let (broker, credentials, _) = try teamBroker(root: fixture.root) { box.current() }
    let token = try credentials.token(for: "pane-requester")
    let coordinator = broker.teamSessions!
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 1, hours: 1)
    let session = try coordinator.request(token: token, proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    _ = try coordinator.requestPane(token: token, kind: .codex, name: "Worker", role: nil)
    coordinator.fulfilProvisions(create: { _, grant, provision in
        let pane = WorkbenchPane(id: "member-1", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder, currentCommand: "codex",
            isActive: false, workspaceID: "workspace", relayEnabled: true, workspaceName: "Team", inputAvailable: true, automationPolicy: .askAndDelegate)
        box.update { $0.append(pane) }
        return pane
    })
    let status = coordinator.status(token: token)
    try teamExpect(status.text.contains("\"requesterPaneID\":\"pane-requester\"") && !status.text.contains("leadPaneID"), "team status did not name the requester: \(status.text)")
    let memberToken = try credentials.token(for: "member-1")
    let toLead = broker.handle(token: memberToken, target: "lead", text: "to the workspace lead", idempotencyKey: UUID().uuidString)
    try teamExpect(toLead.status == 200, "a member could not address the workspace lead: \(toLead)")
    let handoffs = broker.handoffs(limit: 10)
    try teamExpect(handoffs.contains { $0.sourcePaneID == "member-1" && $0.targetPaneID == "chief" } && !handoffs.contains { $0.targetPaneID == "pane-requester" },
        "the lead alias stopped meaning the marked workspace lead")
    let exact = broker.handle(token: memberToken, target: requester.id, text: "to the requester by exact id", idempotencyKey: UUID().uuidString)
    try teamExpect(exact.status == 200 && broker.handoffs(limit: 10).contains { $0.sourcePaneID == "member-1" && $0.targetPaneID == requester.id },
        "a member could not reach the requester by its exact pane id: \(exact)")
}

func teamSessionStopResultChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 6, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 6, hours: 1)
    for name in ["Running", "Restarted", "Closed", "Stopped", "Moved", "Exited"] {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: name, role: nil)
        coordinator.fulfilProvisions(create: { _, grant, provision in
            let pane = WorkbenchPane(id: "pane-\(provision.name)", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
                currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate, launchGeneration: 7)
            box.update { $0.append(pane) }
            return pane
        })
    }
    box.update { panes in
        panes[2].launchGeneration = 8                       // Restarted by the person
        panes.removeAll { $0.id == "pane-Closed" }          // Closed by the person
        panes[3].isStarted = false                          // Already stopped (index shifted after removal)
        panes[3].launchGeneration = 8                       // stopPaneProcess increments the generation
        panes[4].workspaceID = "elsewhere"                  // Moved, still owned
        panes[5].isDead = true                              // Exited but still started: baseline cleanup still stops it
        panes[5].exitStatus = 1
    }
    guard let active = coordinator.sessions().first(where: { $0.id == session.id }) else { throw TeamSessionError.invalid("session vanished") }
    let plan = TeamStopPlanner.plan(members: active.members, live: box.current())
    let byName = Dictionary(uniqueKeysWithValues: plan.map { ($0.member.name, $0.action) })
    try teamExpect(byName["Running"] == .stop && byName["Moved"] == .stop && byName["Exited"] == .stop,
        "owned running, moved or exited-but-started panes were not planned for stopping (baseline eligibility)")
    try teamExpect(byName["Restarted"] == .skip(.skippedRestarted) && byName["Closed"] == .skip(.skippedClosed) && byName["Stopped"] == .skip(.alreadyStopped),
        "the stop plan misjudged a restarted, closed or stopped pane: \(byName)")
    // The native app records what actually happened, including a failure that keeps the retry path open.
    let members = try coordinator.stop(id: session.id, reason: "Stopped by the person")
    try teamExpect(members.count == 6, "historical membership was lost at Stop")
    let attempt = TeamStopAttempt(reason: "Stopped by the person", outcomes: plan.map { entry in
        switch entry.action {
        case .stop where entry.member.name == "Moved":
            TeamMemberStopOutcome(paneID: entry.member.paneID, launchGeneration: entry.member.launchGeneration, name: entry.member.name, result: .failed, message: "injected terminate failure")
        case .stop:
            TeamMemberStopOutcome(paneID: entry.member.paneID, launchGeneration: entry.member.launchGeneration, name: entry.member.name, result: .stopped, message: nil)
        case let .skip(result):
            TeamMemberStopOutcome(paneID: entry.member.paneID, launchGeneration: entry.member.launchGeneration, name: entry.member.name, result: result, message: nil)
        }
    })
    coordinator.recordStopAttempt(id: session.id, attempt: attempt)
    box.update { panes in panes[1].isStarted = false; panes[1].launchGeneration = 8 }   // Running actually stopped (generation incremented); Moved did not.
    let state = coordinator.status(token: "lead-token")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let view = try decoder.decode(TeamSession.AgentView.self, from: Data(state.text.utf8))
    try teamExpect(view.state == "stopped" && view.members.count == 6, "status lost historical membership")
    try teamExpect(view.stopAttempts.count == 1 && view.stopAttempts[0].origin == .human && view.stopAttempts[0].outcomes.count == 6
        && view.stopAttempts[0].outcomes.contains { $0.name == "Moved" && $0.result == .failed && $0.message == "injected terminate failure" },
        "status did not carry the structured stop attempt")
    let current = Dictionary(uniqueKeysWithValues: view.currentPanes.map { ($0.name, $0) })
    try teamExpect(current["Running"]?.ownership == .stopped && current["Running"]?.ownedRunning == false && current["Running"]?.processRunning == false, "a stopped owned pane was misreported")
    try teamExpect(current["Moved"]?.ownership == .owned && current["Moved"]?.ownedRunning == true && current["Moved"]?.processRunning == true && current["Moved"]?.moved == true, "a moved, still-running owned pane was misreported")
    try teamExpect(current["Exited"]?.ownership == .owned && current["Exited"]?.processRunning == false && current["Exited"]?.ownedRunning == false,
        "an exited-but-started owned pane misreported its process lifecycle")
    try teamExpect(current["Restarted"]?.ownership == .restartedByPerson && current["Restarted"]?.processRunning == true && current["Restarted"]?.ownedRunning == false
        && current["Closed"]?.ownership == .closed && current["Closed"]?.processRunning == nil && current["Stopped"]?.ownership == .stopped,
        "restarted, closed or stopped panes conflated process lifecycle with ownership")
    try teamExpect(view.ownedRunningPaneIDs == ["pane-Moved"], "still-running owned generations were not listed for retry: \(view.ownedRunningPaneIDs)")
    // A pane listing failure is reported, never presented as every pane closed.
    let failing = TeamSessionCoordinator(authenticate: { $0 == "lead-token" ? "lead" : nil },
        panes: { throw TeamSessionError.invalid("listing unavailable") }, profiles: { PermissionProfileDefinition.builtIns }, record: { _, _, _ in })
    _ = failing
    let flaky = PaneBox(box.current())
    let flakyFail = FlakyBox()
    let flakyCoordinator = TeamSessionCoordinator(authenticate: { $0 == "lead-token" ? "lead" : nil },
        panes: { if flakyFail.failing { throw TeamSessionError.invalid("listing unavailable") } else { return flaky.current() } },
        profiles: { PermissionProfileDefinition.builtIns }, record: { _, _, _ in })
    let flakySession = try flakyCoordinator.request(token: "lead-token", proposal: TeamSessionProposal(objective: "x", folder: fixture.project, paneLimit: 1, hours: 1))
    try flakyCoordinator.approve(id: flakySession.id, revision: flakySession.revision, objective: "x", folder: fixture.project, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 1)
    flakyFail.failing = true
    let withheld = flakyCoordinator.status(token: "lead-token")
    try teamExpect(withheld.status == 503 && withheld.text.contains("unavailable") && !withheld.text.contains("closed"), "a pane listing failure was reported as pane state: \(withheld.text)")
    flakyFail.failing = false
    // Repeated retries stay bounded.
    for _ in 0..<(TeamSession.maximumRetainedStopAttempts + 5) {
        coordinator.recordStopAttempt(id: session.id, attempt: TeamStopAttempt(reason: "retry", outcomes: attempt.outcomes))
    }
    let bounded = coordinator.sessions().first { $0.id == session.id }
    try teamExpect(bounded?.stopAttempts.count == TeamSession.maximumRetainedStopAttempts && bounded?.stopAttempts.last?.reason == "retry",
        "stop attempt history was not bounded or dropped the newest attempt")
    try teamExpect(coordinator.status(token: "lead-token").text.utf8.count < 200_000, "status grew past the transport cap")
    // Retry after the failure still names only the surviving owned generation, even after expiry-like termination.
    let survivors = try coordinator.ownedMembers(id: session.id)
    try teamExpect(TeamStopPlanner.plan(members: survivors, live: box.current()).filter { $0.action == .stop }.map(\.member.paneID) == ["pane-Moved", "pane-Exited"],
        "the retry plan did not target the surviving owned generations (running moved pane and exited-but-started pane)")
}

func teamSessionTimestampChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 1, hours: 2)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 1, hours: 2)
    let text = coordinator.status(token: "lead-token").text
    let iso = try NSRegularExpression(pattern: "\"provisioningDeadline\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"")
    try teamExpect(iso.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil, "the provisioning deadline is not ISO 8601 UTC: \(text)")
    try teamExpect(text.contains("\"approvedAt\":\"") && text.contains("\"createdAt\":\""), "structured times are missing from status")
    let detail = coordinator.sessions().first { $0.id == session.id }?.detail ?? ""
    try teamExpect(detail.contains(TimeZone.current.abbreviation() ?? "local") || detail.contains("GMT"), "the display-only detail time is not labelled with its zone: \(detail)")
}


func teamSessionStopRecordingFailureChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-team-stopfail-\(UUID().uuidString)")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("runtime").path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    let shimDirectory = runtime.appendingPathComponent("bin", isDirectory: true)
    let transportDirectory = runtime.appendingPathComponent("relay", isDirectory: true)
    try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: transportDirectory, withIntermediateDirectories: true)
    controller.configureRelay(RelayRuntime(infoFile: runtime.appendingPathComponent("relay-url"), shimDirectory: shimDirectory,
        transportDirectory: transportDirectory, credentials: try RelayCredentials(file: runtime.appendingPathComponent("relay-tokens.json")), runtimeMarker: "DEV"))
    _ = try controller.createWorkspace(folder: root.appendingPathComponent("project").path)
    let requester = try controller.createPane(kind: .claude, cwd: root.appendingPathComponent("project").path)
    var eligible = requester
    eligible.relayEnabled = true
    let box = PaneBox([eligible])
    let coordinator = TeamSessionCoordinator(authenticate: { _ in requester.id }, panes: { box.current() },
        profiles: { PermissionProfileDefinition.builtIns }, record: { _, _, _ in })
    let proposal = TeamSessionProposal(objective: "Build", folder: root.appendingPathComponent("project").path, paneLimit: 2, hours: 1)
    let session = try coordinator.request(token: "t", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: "x", folder: proposal.folder, allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 2, hours: 1)
    var created: [WorkbenchPane] = []
    for name in ["Unrecorded", "Refused"] {
        _ = try coordinator.requestPane(token: "t", kind: .codex, name: name, role: nil)
        coordinator.fulfilProvisions(create: { session, grant, provision in
            let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots)
            let pane = try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
            created.append(pane)
            box.update { $0.append(pane) }
            return pane
        })
    }
    guard created.count == 2, let active = coordinator.sessions().first(where: { $0.id == session.id }) else { throw TeamSessionError.invalid("panes were not created") }
    let members = active.members

    // Real path: stopPaneProcess terminates and mutates the pane, then credential
    // forgetting / persistence throws under a read-only runtime directory.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: runtime.path)
    let unrecorded = TeamStopExecution.execute(
        plan: TeamStopPlanner.plan(members: [members[0]], live: try controller.listPanes()),
        stop: { try controller.stopPaneProcess($0) },
        currentPane: { id in (try? controller.listPanes())?.first { $0.id == id } })
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    try teamExpect(unrecorded.count == 1 && unrecorded[0].result == .stoppedUnrecorded && unrecorded[0].message?.isEmpty == false,
        "a stop whose recording failed was not classified as stopped-but-unrecorded: \(unrecorded)")
    let afterUnrecorded = try controller.listPanes().first { $0.id == members[0].paneID }
    try teamExpect(afterUnrecorded?.isStarted == false && members[0].ownership(of: afterUnrecorded) == .stopped,
        "the pane whose stop went unrecorded was not reported as the stopped owned generation")
    try teamExpect(TeamStopPlanner.plan(members: [members[0]], live: try controller.listPanes()).first?.action == .skip(.alreadyStopped),
        "a retry would re-stop a pane the workbench already shows stopped")

    // A stop the workbench refuses before mutating anything is a plain failure and stays retryable.
    let refused = TeamStopExecution.execute(
        plan: TeamStopPlanner.plan(members: [members[1]], live: try controller.listPanes()),
        stop: { _ in throw TeamSessionError.invalid("injected refusal before termination") },
        currentPane: { id in (try? controller.listPanes())?.first { $0.id == id } })
    try teamExpect(refused[0].result == .failed && refused[0].message == "injected refusal before termination", "a refused stop was misclassified: \(refused)")
    let blind = TeamStopExecution.execute(
        plan: TeamStopPlanner.plan(members: [members[1]], live: try controller.listPanes()),
        stop: { _ in throw TeamSessionError.invalid("injected error") },
        currentPane: { _ in nil })
    try teamExpect(blind[0].result == .unknown && !blind[0].result.label.contains("stopped,"), "a failed state lookup claimed a termination or a running process: \(blind)")
    try teamExpect(TeamStopPlanner.plan(members: [members[1]], live: try controller.listPanes()).first?.action == .stop, "a failed stop lost its retry")
    try teamExpect(TeamStopAttempt(reason: "Stopped by the person", outcomes: unrecorded + refused).summary.contains("Stopped but not recorded: Unrecorded"),
        "the summary hid the unrecorded stop")
}

func teamSessionBoundedDiagnosticsChecks() throws {
    let fixture = try TeamFixture()
    defer { fixture.cleanup() }
    let box = PaneBox(fixture.live)
    let coordinator = fixture.coordinator { box.current() }
    let proposal = TeamSessionProposal(objective: "Build", folder: fixture.project, paneLimit: 8, hours: 1)
    let session = try coordinator.request(token: "lead-token", proposal: proposal)
    try coordinator.approve(id: session.id, revision: session.revision, objective: proposal.objective, folder: proposal.folder,
        allowedVendors: [.codex], permissionProfileID: "default", paneLimit: 8, hours: 1)
    for index in 0..<8 {
        _ = try coordinator.requestPane(token: "lead-token", kind: .codex, name: "Worker \(index)", role: nil)
        coordinator.fulfilProvisions(create: { _, grant, provision in
            let pane = WorkbenchPane(id: "pane-\(index)", kind: provision.kind, customName: provision.name, terminalTitle: "", cwd: grant.folder,
                currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, automationPolicy: .askAndDelegate)
            box.update { $0.append(pane) }
            return pane
        })
    }
    let members = try coordinator.stop(id: session.id, reason: String(repeating: "很长的原因", count: 2_000))
    let longMessage = "\u{1b}[31m/Users/private/very/long/path/" + String(repeating: "é", count: 5_000) + "\u{7}"
    let cleaned = TeamBoundedText.clean(longMessage)
    try teamExpect(cleaned.utf8.count <= TeamBoundedText.maximumMessageBytes && cleaned.hasSuffix(TeamBoundedText.truncationMarker)
        && !cleaned.contains("\u{1b}") && !cleaned.contains("\u{7}") && cleaned.hasPrefix("[31m/Users"), "diagnostic text was not bounded or control-cleaned: \(cleaned.utf8.count)")
    try teamExpect(TeamBoundedText.clean("short ok") == "short ok", "a short message was altered")
    for _ in 0..<(TeamSession.maximumRetainedStopAttempts + 5) {
        coordinator.recordStopAttempt(id: session.id, attempt: TeamStopAttempt(reason: longMessage, outcomes: members.map {
            TeamMemberStopOutcome(paneID: $0.paneID, launchGeneration: $0.launchGeneration, name: $0.name, result: .failed, message: longMessage)
        } + members.map {
            TeamMemberStopOutcome(paneID: $0.paneID, launchGeneration: $0.launchGeneration, name: $0.name, result: .failed, message: longMessage)
        }))
    }
    let status = coordinator.status(token: "lead-token")
    try teamExpect(status.status == 200 && status.text.utf8.count < 200_000, "status with retried long diagnostics exceeded the transport cap: \(status.text.utf8.count) bytes")
    let stored = coordinator.sessions().first { $0.id == session.id }!
    try teamExpect(stored.stopAttempts.count == TeamSession.maximumRetainedStopAttempts
        && stored.stopAttempts.allSatisfy { $0.outcomes.count == 8 && $0.reason.utf8.count <= TeamBoundedText.maximumMessageBytes
            && $0.reasonTruncated && $0.outcomesTruncated
            && $0.outcomes.allSatisfy { ($0.message?.utf8.count ?? 0) <= TeamBoundedText.maximumMessageBytes && $0.message?.hasSuffix(TeamBoundedText.truncationMarker) == true && $0.messageTruncated } },
        "stored attempts were not bounded per outcome and per reason with disclosed truncation")
    try teamExpect(status.text.contains("\"messageTruncated\":true") && status.text.contains("\"reasonTruncated\":true"), "truncation metadata is missing from status")
    try teamExpect(!TeamMemberStopOutcome(paneID: "p", launchGeneration: 1, name: "n", result: .stopped, message: "fine").messageTruncated, "a short message was flagged truncated")
    try teamExpect(!status.text.contains("\u{1b}") && stored.detail?.utf8.count ?? 0 < 4_000, "control characters or an unbounded detail reached the status record")
}
