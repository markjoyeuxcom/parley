import Darwin
import Dispatch
import Foundation
import ParleyCore

private func argument(named name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

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
    let applicationDirectory = argument(named: "--application-directory").map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    let cwd = argument(named: "--cwd") ?? fileManager.currentDirectoryPath
    log("starting")
    // The UI has already resolved the login-shell environment and passes it
    // to this process. Resolving it again can consume the launcher's entire
    // startup deadline when a shell profile is slow or interactive.
    let controller = try TmuxController(
        applicationDirectory: applicationDirectory,
        environment: ProcessInfo.processInfo.environment
    )
    log("connecting to tmux")
    try controller.bootstrap(cwd: cwd)

    log("loading relay state")
    let credentials = try RelayCredentials(
        file: controller.applicationDirectory.appendingPathComponent("relay-tokens.json")
    )
    try credentials.retain(paneIDs: Set(try controller.listPanes().map(\.id)))
    let agentTransportDirectory = RelayFileTransport.runtimeDirectory(
        applicationDirectory: controller.applicationDirectory
    )
    _ = try RelayShim.install(
        in: controller.applicationDirectory,
        transportDirectory: agentTransportDirectory
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
    let broker = RelayBroker(
        credentials: credentials,
        panes: { try controller.listPanes() },
        paste: { paneID, text in try controller.paste(text, into: paneID, submit: false) },
        submit: { paneID, text in try controller.paste(text, into: paneID, submit: true) },
        handoffJournal: handoffJournal,
        activityJournal: activityJournal
    )
    let server = RelayHTTPServer(
        broker: broker,
        infoFile: controller.applicationDirectory.appendingPathComponent("relay-url"),
        controlToken: controlToken
    )
    log("opening relay socket")
    try server.start()
    let agentTransport = RelayFileTransport(
        broker: broker,
        runtimeDirectory: agentTransportDirectory
    )
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
