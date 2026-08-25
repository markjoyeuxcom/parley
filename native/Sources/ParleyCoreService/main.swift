import Darwin
import Dispatch
import Foundation
import ParleyCore

private func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("Parley core failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("Parley core: \(message)\n".utf8))
}

do {
    signal(SIGHUP, SIG_IGN)
    let fileManager = FileManager.default
    let launch = CoreServiceLaunchConfiguration.resolve(
        arguments: CommandLine.arguments,
        homeDirectory: fileManager.homeDirectoryForCurrentUser,
        currentDirectory: fileManager.currentDirectoryPath
    )
    if launch.mode == .loginAgent {
        let controlToken = try RelayCoreControlToken.loadOrCreate(
            at: launch.applicationDirectory.appendingPathComponent("core-control-token")
        )
        let existing = RelayCoreClient(
            infoFile: launch.applicationDirectory.appendingPathComponent("relay-url"),
            controlToken: controlToken
        )
        if existing.isHealthy() {
            log("an existing core is healthy; login launch has nothing to do")
            exit(0)
        }
    }
    log("starting")
    // Foreground launches inherit the UI's resolved login-shell environment.
    // Login launches inherit launchd's minimal environment and rely on
    // TmuxController's fixed Homebrew/system lookup. Neither path evaluates a
    // shell profile inside this long-lived background service.
    let controller = try TmuxController(
        applicationDirectory: launch.applicationDirectory,
        sessionName: launch.tmuxSessionName,
        environment: ProcessInfo.processInfo.environment
    )
    if launch.bootstrapsTmux {
        log("connecting to tmux")
        try controller.bootstrap(cwd: launch.cwd)
    } else {
        log("waiting for the foreground app to create or reattach tmux")
    }

    log("loading relay state")
    let credentials = try RelayCredentials(
        file: controller.applicationDirectory.appendingPathComponent("relay-tokens.json")
    )
    let existingPanes = (try? controller.listPanes()) ?? []
    try credentials.retain(paneIDs: Set(existingPanes.map(\.id)))
    let agentTransportDirectory = RelayFileTransport.runtimeDirectory(
        applicationDirectory: controller.applicationDirectory
    )
    _ = try RelayShim.install(
        in: controller.applicationDirectory,
        transportDirectory: agentTransportDirectory,
        runtimeMarker: launch.runtimeMarker
    )

    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: controller.applicationDirectory.appendingPathComponent("core-control-token")
    )
    let handoffJournal = try RelayHandoffJournal(
        file: controller.applicationDirectory.appendingPathComponent("handoffs.jsonl")
    )
    let activityJournal = try RelayActivityJournal(
        file: controller.applicationDirectory.appendingPathComponent("activity-events.jsonl")
    )
    let contextReviewStore = try AgentContextReviewStore(
        file: controller.applicationDirectory.appendingPathComponent("context-reviews.json")
    )
    let broker = RelayBroker(
        credentials: credentials,
        panes: { try controller.listPanes() },
        paste: { paneID, text in try controller.paste(text, into: paneID, submit: false) },
        submit: { paneID, text in try controller.paste(text, into: paneID, submit: true) },
        contextSubmit: { paneID, text in try controller.pasteExplicitContext(text, into: paneID, submit: true) },
        directContextSubmit: { sourcePaneID, targetPaneID, text in
            try controller.askWithExplicitContext(from: sourcePaneID, to: targetPaneID, text: text)
        },
        visibleText: { paneID in try controller.capturePane(paneID) },
        handoffJournal: handoffJournal,
        activityJournal: activityJournal,
        contextReviewStore: contextReviewStore
    )
    let agentTransport = RelayFileTransport(
        broker: broker,
        credentials: credentials,
        runtimeDirectory: agentTransportDirectory
    )
    let server = RelayHTTPServer(
        broker: broker,
        infoFile: controller.applicationDirectory.appendingPathComponent("relay-url"),
        controlToken: controlToken,
        identity: .current(),
        shutdownRequested: { reason in
            if reason.preservesExchangeFiles {
                try? agentTransport.preserveExchangeFilesForNextStart()
            }
            // The acknowledgement has already been written. Give this main
            // thread time to install its signal sources before requesting the
            // ordinary cleanup path.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                _ = Darwin.kill(ProcessInfo.processInfo.processIdentifier, SIGTERM)
            }
        }
    )
    log("opening relay socket")
    try server.start()
    do {
        log("opening agent filesystem transport")
        try agentTransport.start()
    } catch {
        server.stop()
        throw error
    }

    let pidFile = controller.applicationDirectory.appendingPathComponent("core.pid")
    try String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFile.path)
    log("ready (pid \(ProcessInfo.processInfo.processIdentifier))")

    RelayServiceProcess.waitForTermination { signalNumber in
        log("stopping after signal \(signalNumber)")
        server.stop()
        agentTransport.stop()
        try? fileManager.removeItem(at: pidFile)
    }
} catch {
    fail(error)
}
