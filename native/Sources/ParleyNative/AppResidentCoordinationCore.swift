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
    let commandRuns: ReviewedCommandRunCoordinator
    let commandRunDirectory: URL
    let commandRunCleanupWarnings: [String]

    private let handoffJournal: RelayHandoffJournal
    var historyPersistenceError: String? { handoffJournal.lastError }

    private let server: RelayHTTPServer
    private let agentTransport: RelayFileTransport
    private let pidFile: URL

    init(
        controller: WorkbenchController,
        credentials: RelayCredentials,
        applicationDirectory: URL,
        transportDirectory: URL
    ) throws {
        let controlToken = try RelayCoreControlToken.loadOrCreate(
            at: applicationDirectory.appendingPathComponent("core-control-token")
        )
        let infoFile = applicationDirectory.appendingPathComponent("relay-url")
        let previousClient = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
        if previousClient.isHealthy() {
            let response = try previousClient.shutdownLegacyCoreIfIdle()
            guard response.status == 202 else {
                let active = response.readiness.activeWorkCount
                throw AppResidentCoordinationCoreError.message(
                    "Parley cannot replace the older coordination core while \(active) tracked item\(active == 1 ? " is" : "s are") active. Finish or cancel that work, then reopen Parley."
                )
            }
            let deadline = Date().addingTimeInterval(3)
            while previousClient.isHealthy(), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !previousClient.isHealthy() else {
                throw AppResidentCoordinationCoreError.message(
                    "The older coordination core accepted shutdown but did not release its local socket."
                )
            }
        }
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
        let contextReviewStore = try AgentContextReviewStore(
            file: applicationDirectory.appendingPathComponent("context-reviews.json")
        )
        let busyDraftStore = try ReviewedBusyDraftStore(
            file: applicationDirectory.appendingPathComponent("reviewed-busy-drafts.json")
        )
        let gitFactsCapture = DelegationGitSnapshotCapture()
        let broker = RelayBroker(
            credentials: credentials,
            panes: { try controller.listPanes() },
            paste: { paneID, text in try controller.paste(text, into: paneID, submit: false) },
            submit: { paneID, text in try controller.paste(text, into: paneID, submit: true) },
            contextSubmit: { paneID, text in
                try controller.pasteExplicitContext(text, into: paneID, submit: true)
            },
            directContextSubmit: { _, targetPaneID, text in
                try controller.pasteExplicitContext(text, into: targetPaneID, submit: true)
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
        broker.enableReviewedCommandRuns()
        commandRuns = broker.commandRuns!
        commandRunDirectory = applicationDirectory.resolvingSymlinksInPath().appendingPathComponent("approved-command-runs")
        let runDirectory = commandRunDirectory
        commandRunCleanupWarnings = ApprovedCommandWorker.removeAbandoned(in: runDirectory)
        commandRuns.cancellationHandler = { run in
            try ApprovedCommandWorker.cancel(runID: run.id, directory: runDirectory)
        }
        server = RelayHTTPServer(
            broker: broker,
            infoFile: infoFile,
            controlToken: controlToken
        )
        agentTransport = RelayFileTransport(
            broker: broker,
            credentials: credentials,
            runtimeDirectory: transportDirectory
        )
        client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
        pidFile = applicationDirectory.appendingPathComponent("core.pid")

        do {
            try server.start()
            try agentTransport.start()
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
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        commandRuns.stop(reason: "Parley stopped; session trust was revoked and active command runs were interrupted.")
        server.stop()
        agentTransport.stop()
        try? FileManager.default.removeItem(at: pidFile)
    }
}
