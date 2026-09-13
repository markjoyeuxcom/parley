import CryptoKit
import Foundation


/// Native approvals only; the agent transport exposes request and owned wait.
/// Session grants and pending execution authority are never loaded from disk.
public final class ReviewedCommandRunCoordinator: @unchecked Sendable {
    public static let trustDisclosure = "Runs as you outside the agent boundary. The command executes this project's current code, which agents can change. It can access your files and other panes' credentials; cross-vendor attribution cannot be guaranteed while this trust is granted."
    /// Shown wherever the person's automatic-approval choice is offered or in effect.
    public static let automaticApprovalDisclosure = "While this is on, every command an agent requests with parley request-run is approved exactly as requested and starts in a new Shell pane without a preview. Each run still needs a live agent pane in a workspace that allows command runs and a canonical folder inside that pane's folder. " + trustDisclosure + " Turning it off restores per-run approval immediately, and any request it approved that has not started yet goes back to waiting for you. Unlike exact-command session trust, this choice stays on across Parley relaunches until you turn it off here. It is stored in Parley's own private directory, which agent processes cannot read or write."
    private static let automaticApprovalRevokedDetail = "Automatic approval was turned off before this run started; human approval is required."
    private static let automaticApprovalDetail = "Approved automatically: the person turned on automatic approval of agent command runs in Settings; runs outside the agent boundary"
    private let lock = NSRecursiveLock()
    private let authenticate: (String) -> String?
    private let panes: () throws -> [WorkbenchPane]
    private let record: (ReviewedCommandRun) throws -> Void
    private var records: [String: ReviewedCommandRun] = [:]
    private struct RequestOwner: Hashable {
        let paneID: String
        let generation: Int
    }
    /// A deleted result must never make the same transport retry executable.
    /// Keep only hashes of request identities, without argv, folders or output.
    private var deletedRequests: [RequestOwner: Set<Data>] = [:]
    private var sessionGrants: [ReviewedCommandGrant] = []
    /// The person's Settings choice, pushed in by the native app and never
    /// read from disk or from any agent request.
    private var automaticApproval = false
    private var stopped = false
    public var cancellationHandler: ((ReviewedCommandRun) throws -> Bool)?
    private var storedError: String?
    public var lastError: String? { lock.withLock { storedError } }

    public init(authenticate: @escaping (String) -> String?, panes: @escaping () throws -> [WorkbenchPane],
                record: @escaping (ReviewedCommandRun) throws -> Void) {
        self.authenticate = authenticate
        self.panes = panes
        self.record = record
    }

    public func request(token: String, argv: [String], folder: String, idempotencyKey: String = UUID().uuidString) throws -> ReviewedCommandRun {
        try lock.withLock {
            guard !stopped else { throw ReviewedCommandRunError.invalid("The command-run service has stopped.") }
            reconcile()
            guard let id = authenticate(token), let source = try panes().first(where: { $0.id == id }),
                  eligible(source) else {
                throw ReviewedCommandRunError.invalid("A live authenticated agent and an Ask-enabled workspace are required.")
            }
            let command = try ReviewedCommand(argv: argv, folder: folder, sourceFolder: source.cwd)
            guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 128 else { throw ReviewedCommandRunError.invalid("Invalid request identity.") }
            let owner = RequestOwner(paneID: source.id, generation: source.launchGeneration)
            let fingerprint = Data(SHA256.hash(data: Data(idempotencyKey.utf8)))
            guard deletedRequests[owner]?.contains(fingerprint) != true else {
                throw ReviewedCommandRunError.invalid("The person deleted this command run and its result. The original request cannot be replayed.")
            }
            if let previous = records.values.first(where: { $0.source?.id == id && $0.source?.launchGeneration == source.launchGeneration && $0.idempotencyKey == idempotencyKey }) {
                guard previous.requestedCommand == command else { throw ReviewedCommandRunError.invalid("A request identity cannot name different commands.") }
                return previous
            }
            guard !records.values.contains(where: { $0.source?.id == id && (!$0.state.isTerminal || $0.workerStillRunning) }) else {
                throw ReviewedCommandRunError.invalid("This pane already has an active command run.")
            }
            let grant = sessionGrants.first { $0.matches(source: source, command: command) }
            let approved = grant != nil || automaticApproval
            let now = Date()
            let run = ReviewedCommandRun(id: UUID().uuidString.lowercased(), idempotencyKey: idempotencyKey, requestedCommand: command, revision: UUID().uuidString,
                source: source, sourceFolder: URL(fileURLWithPath: source.cwd).resolvingSymlinksInPath().standardizedFileURL.path, command: command, state: approved ? .approved : .pending,
                createdAt: now, updatedAt: now, shellPaneID: "pane-" + UUID().uuidString.lowercased(),
                autoApprovalGrantID: grant?.id, approvedAutomatically: grant == nil && automaticApproval, result: nil,
                detail: grant != nil ? "Approved by an explicit session grant; runs outside the agent boundary"
                    : automaticApproval ? Self.automaticApprovalDetail : "Waiting for human approval")
            try save(run)
            prune()
            return run
        }
    }

    /// A run the person proposes from the native app, such as Integrate… on
    /// a worktree. Only the native app calls this; no transport route reaches
    /// it. It always waits for the person's approval in the editable preview:
    /// neither the automatic-approval switch nor an exact-command grant
    /// applies, because that preview is where the person confirms the exact
    /// command. The folder is its own containment root. No pane requested it,
    /// so `wait` refuses it and a pane change never interrupts it.
    public func propose(argv: [String], folder: String, workspaceID: String, workspaceName: String?) throws -> ReviewedCommandRun {
        try lock.withLock {
            guard !stopped else { throw ReviewedCommandRunError.invalid("The command-run service has stopped.") }
            reconcile()
            let command = try ReviewedCommand(argv: argv, folder: folder, sourceFolder: folder)
            guard !workspaceID.isEmpty else { throw ReviewedCommandRunError.invalid("Choose a workspace for the run's Shell pane.") }
            guard !records.values.contains(where: { $0.origin == .person && (!$0.state.isTerminal || $0.workerStillRunning) }) else {
                throw ReviewedCommandRunError.invalid("A run you proposed is still waiting or running. Approve, reject or cancel it in Review runs and trust first.")
            }
            let now = Date()
            let run = ReviewedCommandRun(id: UUID().uuidString.lowercased(), idempotencyKey: UUID().uuidString, requestedCommand: command,
                revision: UUID().uuidString, source: nil, sourceFolder: command.folder, command: command, state: .pending,
                createdAt: now, updatedAt: now, shellPaneID: "pane-" + UUID().uuidString.lowercased(),
                autoApprovalGrantID: nil, approvedAutomatically: false, result: nil,
                detail: "Proposed by you; waiting for your approval in the editable preview",
                origin: .person, workspaceID: workspaceID, workspaceName: workspaceName)
            try save(run)
            prune()
            return run
        }
    }

    public func approve(id: String, revision: String, argv: [String], folder: String, autoApprove: Bool) throws {
        try lock.withLock {
            guard !stopped, var run = records[id], run.state == .pending, run.revision == revision,
                  let containment = try currentContainmentRoot(run) else {
                throw ReviewedCommandRunError.invalid("This preview is stale or its requesting pane changed. Refresh before approving.")
            }
            run.command = try ReviewedCommand(argv: argv, folder: folder, sourceFolder: containment)
            run.state = .approved
            // A grant is keyed to a requesting pane generation; a run the
            // person proposed has none, so the toggle cannot create one.
            let source = try currentSource(run)
            let grant = autoApprove && source != nil ? ReviewedCommandGrant(source: source!, command: run.command) : nil
            // This run has its own explicit approval; revoking future trust must not revoke it.
            run.autoApprovalGrantID = nil
            run.detail = autoApprove
                ? "Human approved this run and exact-command session trust outside the agent boundary"
                : "Human approved this one run outside the agent boundary"
            // Grant creation follows durable approval; failure cannot authorize execution.
            try save(changed(run))
            if let grant, let source {
                sessionGrants.removeAll { $0.matches(source: source, command: run.command) }
                sessionGrants.append(grant)
            }
        }
    }

    public var automaticApprovalEnabled: Bool { lock.withLock { automaticApproval } }

    /// The person's Settings switch. Only the native app calls this; no
    /// transport route can reach it. Turning it on approves requests already
    /// waiting, exactly as requested, provided their requesting pane is still
    /// current; it creates no session grant. Turning it off restores per-run
    /// approval for later requests and returns any approval this switch
    /// supplied that has not launched to waiting; a running command, a human
    /// approval and an exact-command grant are untouched.
    public func setAutomaticApproval(_ enabled: Bool) {
        lock.withLock {
            automaticApproval = enabled
            guard !stopped else { return }
            if !enabled {
                // Mirror grant revocation: an approval this switch supplied that
                // has not launched goes back to waiting. A run the person
                // approved by hand or by an exact grant is untouched.
                for id in records.values.filter({ $0.state == .approved && $0.launchedAt == nil && $0.approvedAutomatically && $0.autoApprovalGrantID == nil }).map(\.id) {
                    guard var run = records[id] else { continue }
                    run.state = .pending
                    run.approvedAutomatically = false
                    run.detail = Self.automaticApprovalRevokedDetail
                    do { try save(changed(run)) } catch {
                        records[id] = changed(run) // Fail closed in memory even if recording fails.
                        storedError = error.localizedDescription
                    }
                }
                return
            }
            reconcile()
            // A run the person proposed is theirs to confirm in the preview;
            // the switch covers agent requests only.
            for id in records.values.filter({ $0.state == .pending && $0.origin == .agentPane }).sorted(by: { $0.createdAt < $1.createdAt }).map(\.id) {
                guard var run = records[id], (try? currentSource(run)) != nil else { continue }
                run.state = .approved
                run.autoApprovalGrantID = nil
                run.approvedAutomatically = true
                run.detail = Self.automaticApprovalDetail
                // Approval is durable first; a failed record leaves the run pending.
                do { try save(changed(run)) } catch { storedError = error.localizedDescription }
            }
        }
    }

    /// Called only by the native app on its main actor. No transport route
    /// invokes this method or supplies a launch closure.
    public func launchApproved(_ start: (ReviewedCommandRun) throws -> Void) {
        lock.withLock {
            reconcile()
            for id in records.values.filter({ $0.state == .approved }).sorted(by: { $0.createdAt < $1.createdAt }).map(\.id) {
                guard !stopped, var run = records[id] else { continue }
                do {
                    guard let containment = try currentContainmentRoot(run) else {
                        throw ReviewedCommandRunError.invalid("The requesting pane changed before launch.")
                    }
                    _ = try ReviewedCommand(argv: run.command.argv, folder: run.command.folder, sourceFolder: containment)
                    run.state = .running
                    run.launchedAt = Date()
                    run.detail = "Starting the approved command in a new Shell pane outside the agent boundary"
                    try save(changed(run))
                    try start(records[id]!)
                } catch {
                    fail(id: id, detail: "The approved run could not start: \(error.localizedDescription)")
                }
            }
        }
    }

    public func complete(id: String, result: ReviewedCommandRunResult) {
        lock.withLock {
            guard var run = records[id], run.launchedAt != nil, run.result == nil else { return }
            let late = run.state.isTerminal
            run.result = result.attributed(to: run.command)
            if !late {
                run.state = result.cancelled ? .cancelled : (result.exitStatus == nil && result.terminationSignal == nil ? .failed : .completed)
            }
            run.detail = late ? "A captured command result arrived after tracking ended. " + (result.detail ?? "The previous outcome is retained.")
                : (result.detail ?? "Captured command output and process exit; no test verdict was assigned.")
            run.resultSaved = true
            run = changed(run)
            do { try save(run) }
            catch {
                run.resultSaved = false
                run.detail = "Command ran, but its result could not be saved: \(error.localizedDescription). Do not resend to repair history."
                records[id] = run
                storedError = run.detail
            }
        }
    }

    public func cancel(id: String, reason: String = "Cancellation requested by the person") throws {
        try lock.withLock {
            guard var run = records[id], !run.state.isTerminal else { return }
            if run.state == .running {
                run.cancellationRequested = true
                run.cancellationRequestedAt = Date()
                do {
                    if try cancellationHandler?(run) == true {
                        run.state = .cancelled
                        run.detail = reason + "; the unclaimed ticket was invalidated, so the command was not launched"
                    } else {
                        run.detail = reason + "; waiting for the owned process to exit"
                    }
                } catch {
                    run.detail = "Cancellation could not be delivered: \(error.localizedDescription). The process may still be running; close its Shell pane to stop it."
                }
            } else {
                run.state = .cancelled
                run.detail = reason + "; command was not launched"
            }
            try save(changed(run))
        }
    }

    public func reject(id: String, revision: String) throws {
        try lock.withLock {
            guard var run = records[id], run.state == .pending, run.revision == revision else {
                throw ReviewedCommandRunError.invalid("This request is no longer awaiting that approval.")
            }
            run.state = .rejected
            run.detail = "The person refused this command run."
            try save(changed(run))
        }
    }

    public func fail(id: String, detail: String) {
        lock.withLock {
            guard var run = records[id], !run.state.isTerminal else { return }
            _ = try? cancellationHandler?(run)
            run.state = .failed
            run.detail = detail
            run = changed(run)
            do { try save(run) } catch { records[id] = run; storedError = error.localizedDescription }
        }
    }


    /// Native file/lease observations only. Transport waiters never perform
    /// process liveness probes or choose execution paths.
    public func serviceWorkers(directory: URL, at now: Date = Date()) {
        for snapshot in runs() where snapshot.launchedAt != nil {
            do {
                let observation = try ApprovedCommandWorker.observation(runID: snapshot.id, directory: directory)
                lock.withLock {
                    if var current = records[snapshot.id], current.workerStillRunning != observation.running {
                        current.workerStillRunning = observation.running
                        records[current.id] = current
                    }
                }
                if snapshot.result == nil, let result = try ApprovedCommandWorker.result(runID: snapshot.id, directory: directory) {
                    complete(id: snapshot.id, result: result)
                    // The lease was observed before this result existed; a
                    // worker that acquired it in between (and now sits in its
                    // clean-exit delay) must not read as gone. Unknown is held.
                    _ = workerLeaseReleased(id: snapshot.id, directory: directory)
                }
                guard var run = lock.withLock({ records[snapshot.id] }) else { continue }
                if !run.state.isTerminal {
                    if !observation.running {
                        if observation.ticketPending {
                            let shellExists = try panes().contains { $0.id == run.shellPaneID && $0.isStarted && !$0.isDead }
                            if !shellExists || now.timeIntervalSince(run.launchedAt!) > 130 {
                                let reason = shellExists ? "The worker did not start before its ticket expired." : "The command Shell closed before the worker claimed its ticket."
                                if try ApprovedCommandWorker.cancel(runID: run.id, directory: directory) {
                                    fail(id: run.id, detail: reason + " The ticket was invalidated; the command was not launched.")
                                } else {
                                    try cancel(id: run.id, reason: reason)
                                }
                            }
                        } else if observation.consumed || observation.failure != nil {
                            fail(id: run.id, detail: observation.failure ?? "The worker ended without publishing a captured result. Do not resend to repair this unknown outcome.")
                        } else {
                            let shellExists = try panes().contains { $0.id == run.shellPaneID && $0.isStarted && !$0.isDead }
                            if !shellExists || now.timeIntervalSince(run.launchedAt!) > 10 {
                                fail(id: run.id, detail: "The command Shell ended or its worker files disappeared before a captured result was available.")
                            }
                        }
                    }
                    if let requestedAt = run.cancellationRequestedAt, now.timeIntervalSince(requestedAt) > 5 {
                        lock.withLock {
                            guard var current = records[run.id], !current.state.isTerminal else { return }
                            current.state = .cancelled
                            current.detail = (current.detail ?? "Cancellation requested") + ". No captured result arrived within the cancellation grace period; the process may still be running. Close its Shell pane to stop it."
                            current = changed(current)
                            do { try save(current) } catch { records[current.id] = current; storedError = error.localizedDescription }
                        }
                    }
                }
                run = lock.withLock { records[snapshot.id] ?? run }
                if run.state.isTerminal, !observation.running, run.result == nil || run.resultSaved {
                    if observation.ticketPending { _ = try ApprovedCommandWorker.cancel(runID: run.id, directory: directory) }
                    _ = try ApprovedCommandWorker.discard(runID: run.id, directory: directory)
                }
            } catch {
                fail(id: snapshot.id, detail: "The command worker could not be inspected: \(error.localizedDescription). No successful execution is inferred; close its Shell if it is still running.")
                if let current = lock.withLock({ records[snapshot.id] }), current.state.isTerminal,
                   current.result == nil || current.resultSaved,
                   (try? ApprovedCommandWorker.workerIsRunning(runID: snapshot.id, directory: directory)) == false {
                    _ = try? ApprovedCommandWorker.discard(runID: snapshot.id, directory: directory)
                }
            }
        }
    }


    /// A fresh kernel-lease fact for native cleanup, taken right before a
    /// pane is removed: true only when the worker's lock is observed free (or
    /// its job directory is already gone). An observation that cannot be made
    /// counts as held. The record's cached flag is corrected at the same time.
    public func workerLeaseReleased(id: String, directory: URL) -> Bool {
        let held: Bool
        do { held = try ApprovedCommandWorker.workerIsRunning(runID: id, directory: directory) }
        catch { held = true }
        lock.withLock {
            if var current = records[id], current.workerStillRunning != held {
                current.workerStillRunning = held
                records[id] = current
            }
        }
        return !held
    }

    /// Keep coordinator -> broker lock order throughout history deletion.
    /// A late completion cannot re-record a result between journal removal and
    /// forgetting its recovery copy. Only durably removed terminal IDs leave.
    public func withHistoryDeletion(_ delete: ([ReviewedCommandRun]) -> Set<String>) {
        lock.withLock {
            let removed = delete(Array(records.values))
            for run in records.values where removed.contains(run.id) && run.state.isTerminal && !run.workerStillRunning {
                let owner = RequestOwner(paneID: run.source?.id ?? "person", generation: run.source?.launchGeneration ?? 0)
                deletedRequests[owner, default: []].insert(Data(SHA256.hash(data: Data(run.idempotencyKey.utf8))))
            }
            records = records.filter { id, run in
                !removed.contains(id) || !run.state.isTerminal || run.workerStillRunning
            }
        }
    }

    public func runs() -> [ReviewedCommandRun] {
        lock.withLock { records.values.sorted { $0.createdAt > $1.createdAt } }
    }
    public func grants() -> [ReviewedCommandGrant] { lock.withLock { sessionGrants } }
    public func owns(id: String) -> Bool { lock.withLock { records[id] != nil } }

    public func revoke(grantID: String) {
        lock.withLock {
            sessionGrants.removeAll { $0.id == grantID }
            // Revoke queued approval too; an already running command has its
            // own visible Cancel action.
            for id in records.values.filter({ $0.state == .approved && $0.autoApprovalGrantID == grantID }).map(\.id) {
                guard var run = records[id] else { continue }
                run.state = .pending
                run.autoApprovalGrantID = nil
                run.detail = "Session trust was revoked; human approval is required."
                do { try save(changed(run)) } catch {
                    // Fail closed in memory even if recording the revocation fails.
                    records[id] = changed(run)
                    storedError = error.localizedDescription
                }
            }
        }
    }

    public func reconcile() {
        lock.withLock {
            guard let live = try? panes() else { return }
            sessionGrants.removeAll { grant in
                !live.contains { eligible($0) && grant.matches(source: $0, command: grant.command) }
            }
            for id in records.values.filter({ !$0.state.isTerminal }).map(\.id) {
                guard var run = records[id] else { continue }
                let expired = run.state == .pending && Date().timeIntervalSince(run.createdAt) > 30 * 60
                // A person-proposed run has no requesting pane to lose; only expiry ends it here.
                guard expired || (run.origin == .agentPane && !live.contains(where: { sourceMatches($0, run: run) })) else { continue }
                _ = try? cancellationHandler?(run)
                run.state = .interrupted
                run.detail = expired ? "The unapproved request expired." : "The requesting pane stopped, moved, changed folder or restarted."
                run = changed(run)
                do { try save(run) } catch {
                    records[id] = run // Never leave stale execution authority live.
                    storedError = error.localizedDescription
                }
            }
        }
    }

    public func stop(reason: String, permanently: Bool = true) {
        lock.withLock {
            if permanently { stopped = true }
            sessionGrants.removeAll()
            for id in records.values.filter({ !$0.state.isTerminal }).map(\.id) {
                guard var run = records[id] else { continue }
                _ = try? cancellationHandler?(run)
                run.state = .interrupted
                run.detail = reason
                run = changed(run)
                do { try save(run) } catch { records[id] = run; storedError = error.localizedDescription }
            }
        }
    }

    public func wait(token: String, id: String) -> RelayTextResponse {
        while true {
            let response: RelayTextResponse? = lock.withLock {
                reconcile()
                guard let run = records[id], run.origin == .agentPane, let source = run.source, authenticate(token) == source.id,
                      (try? currentSource(run)) != nil else {
                    return RelayTextResponse(status: 403, text: "Only the same live requesting pane generation can recover this run.")
                }
                guard run.state.isTerminal else { return nil }
                if let result = run.result, let data = try? JSONEncoder().encode(result), data.count <= 200_000 {
                    return RelayTextResponse(status: 200, text: String(decoding: data, as: UTF8.self))
                }
                return RelayTextResponse(status: 409, text: run.detail ?? "This run did not return a captured command result.")
            }
            if let response { return response }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func currentSource(_ run: ReviewedCommandRun) throws -> WorkbenchPane? {
        try panes().first { sourceMatches($0, run: run) }
    }
    private func eligible(_ source: WorkbenchPane) -> Bool {
        source.kind.isAgent && source.isStarted && !source.isDead && source.relayEnabled
            && source.automationPolicy.allows(.commandRun)
    }
    private func sourceMatches(_ source: WorkbenchPane, run: ReviewedCommandRun) -> Bool {
        guard let requester = run.source else { return false }
        return eligible(source) && source.id == requester.id
            && source.automationPolicy == requester.automationPolicy
            && source.launchGeneration == requester.launchGeneration && source.workspaceID == requester.workspaceID
            && URL(fileURLWithPath: source.cwd).resolvingSymlinksInPath().standardizedFileURL.path
                == run.sourceFolder
    }
    /// The folder the approved command must stay inside: the live requesting
    /// pane's folder, or, for a run the person proposed, the folder they
    /// proposed it in. nil means an agent run's pane is no longer current.
    private func currentContainmentRoot(_ run: ReviewedCommandRun) throws -> String? {
        switch run.origin {
        case .agentPane: try currentSource(run)?.cwd
        case .person: run.sourceFolder
        }
    }
    private func changed(_ value: ReviewedCommandRun) -> ReviewedCommandRun {
        var run = value
        run.updatedAt = Date()
        run.revision = UUID().uuidString
        return run
    }
    private func save(_ run: ReviewedCommandRun) throws {
        try record(run)
        records[run.id] = run
        storedError = nil
    }
    private func prune() {
        let terminal = records.values.filter { $0.state.isTerminal && !$0.workerStillRunning }.sorted { $0.updatedAt > $1.updatedAt }
        for run in terminal.dropFirst(128) { records.removeValue(forKey: run.id) }
    }
}
