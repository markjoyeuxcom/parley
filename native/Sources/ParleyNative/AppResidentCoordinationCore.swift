import Foundation
import ParleyCore

private enum AppResidentCoordinationCoreError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case let .message(text): text }
    }
}

/// Runs Parley's local broker beside the retained Ghostty surfaces. The
/// server and filesystem transport continue while every app window is hidden;
/// they stop with the application process, matching pane lifetime exactly.
final class AppResidentCoordinationCore {
    let client: RelayCoreClient
    /// The in-process broker. The UI still reads relay state through the
    /// authenticated control socket; this reference exists so the periodic
    /// tick can ask `stateRevision()` and skip the round trips when nothing
    /// changed, and so native-only coordinators are reachable.
    let broker: RelayBroker
    let commandRuns: ReviewedCommandRunCoordinator
    let commandRunDirectory: URL
    let commandRunCleanupWarnings: [String]
    let teamSessions: TeamSessionCoordinator

    private let handoffJournal: RelayHandoffJournal
    private let activityJournal: RelayActivityJournal
    /// Handoff persistence failures and activity-journal maintenance failures
    /// share the Status Center health route; an activity compaction failure
    /// follows an already durable append and clears on the next success.
    var historyPersistenceError: String? {
        let errors = [handoffJournal.lastError, activityJournal.lastError.map { "Activity journal maintenance: \($0)" }].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    private let server: RelayHTTPServer
    private let agentTransport: RelayFileTransport
    /// The peer-verified ticket socket. Its failure to listen is not the
    /// core's failure: the transport then runs token-only for every pane and
    /// says so in each pane's policy.
    let ticketServer: RelayTicketServer
    private let pidFile: URL

    init(
        controller: WorkbenchController,
        credentials: RelayCredentials,
        applicationDirectory: URL,
        transportDirectory: URL,
        permissionProfiles: @escaping () throws -> [PermissionProfileDefinition]
    ) throws {
        let controlToken = try RelayCoreControlToken.generate()
        let infoFile = applicationDirectory.appendingPathComponent("relay-url")
        let historyRetentionStore = CollaborationHistoryRetentionStore(
            file: applicationDirectory.appendingPathComponent("history-retention.json")
        )
        let historyRetentionPolicy = try historyRetentionStore.policy()
        let handoffJournal = try RelayHandoffJournal(
            file: applicationDirectory.appendingPathComponent("handoffs.jsonl"),
            maximumHandoffs: historyRetentionPolicy.maximumRecords
        )
        self.handoffJournal = handoffJournal
        let activityJournal = try RelayActivityJournal(
            file: applicationDirectory.appendingPathComponent("activity-events.jsonl"),
            maximumEvents: historyRetentionPolicy.maximumRecords
        )
        self.activityJournal = activityJournal
        let contextReviewStore = try AgentContextReviewStore(
            file: applicationDirectory.appendingPathComponent("context-reviews.json")
        )
        let busyDraftStore = try ReviewedBusyDraftStore(
            file: applicationDirectory.appendingPathComponent("reviewed-busy-drafts.json")
        )
        let managedWorktreeStore = ManagedWorktreeStore(file: applicationDirectory.appendingPathComponent("managed-worktrees.json"))
        let gitFactsCapture = DelegationGitSnapshotCapture(managedWorktreeLookup: { root in managedWorktreeStore.evidence(forWorktreeRoot: root) })
        let broker = RelayBroker(
            credentials: credentials,
            panes: { try controller.listPanes() },
            paste: { paneID, text in try controller.paste(text, into: paneID, submit: false) },
            submit: { paneID, text in try controller.paste(text, into: paneID, submit: true) },
            contextSubmit: { paneID, text in
                try controller.pasteExplicitContext(text, into: paneID, submit: true)
            },
            selectedText: { paneID in try controller.capturePane(paneID) },
            vendorSignal: { paneID, signal, occurredAt in
                try controller.recordVendorSignal(paneID: paneID, signal: signal, occurredAt: occurredAt)
            },
            gitFacts: { folder in gitFactsCapture.snapshot(in: folder) },
            handoffJournal: handoffJournal,
            activityJournal: activityJournal,
            historyRetentionPolicy: historyRetentionPolicy,
            historyRetentionStore: historyRetentionStore,
            contextReviewStore: contextReviewStore,
            busyDraftStore: busyDraftStore
        )
        self.broker = broker
        broker.enableReviewedCommandRuns()
        commandRuns = broker.commandRuns!
        broker.enableTeamSessions(profiles: permissionProfiles)
        teamSessions = broker.teamSessions!
        commandRunDirectory = applicationDirectory.resolvingSymlinksInPath().appendingPathComponent("approved-command-runs")
        let runDirectory = commandRunDirectory
        commandRunCleanupWarnings = ApprovedCommandWorker.removeAbandoned(in: runDirectory)
        broker.deleteCommandRunArtifacts = { ids in
            for id in ids {
                let observation = try ApprovedCommandWorker.observation(runID: id, directory: runDirectory)
                guard !observation.running, !observation.ticketPending,
                      try ApprovedCommandWorker.discard(runID: id, directory: runDirectory) else {
                    throw ReviewedCommandRunError.invalid("A command worker is still active or has an unclaimed ticket. Let it finish or cancel it before clearing its result.")
                }
            }
        }
        commandRuns.cancellationHandler = { run in
            try ApprovedCommandWorker.cancel(runID: run.id, directory: runDirectory)
        }
        server = RelayHTTPServer(
            broker: broker,
            infoFile: infoFile,
            controlToken: controlToken
        )
        broker.hostNetworkAllowed = { [controller] pane in controller.hostNetworkAllowed(for: pane) }
        ticketServer = RelayTicketServer(
            socketFile: RelayTicketServer.socketURL(transportDirectory: transportDirectory),
            credentials: credentials,
            paneGeneration: { [controller] paneID in (try? controller.listPanes())?.first { $0.id == paneID }?.launchGeneration }
        )
        agentTransport = RelayFileTransport(
            broker: broker,
            credentials: credentials,
            runtimeDirectory: transportDirectory,
            tickets: ticketServer
        )
        client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
        pidFile = applicationDirectory.appendingPathComponent("core.pid")

        do {
            try server.start()
            try agentTransport.start()
            // Kept out of the failure path on purpose: the failure is retained
            // on the server and reported through every pane's policy.
            try? ticketServer.start()
            try String(ProcessInfo.processInfo.processIdentifier).write(
                to: pidFile,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pidFile.path
            )
        } catch {
            server.stop()
            agentTransport.stop()
            ticketServer.stop()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        commandRuns.stop(reason: "Parley stopped; session trust was revoked and active command runs were interrupted.")
        teamSessions.stopAll(reason: "Parley stopped; team session grants were revoked. Created panes were not stopped separately.")
        server.stop()
        agentTransport.stop()
        ticketServer.stop()
        try? FileManager.default.removeItem(at: pidFile)
    }
}
