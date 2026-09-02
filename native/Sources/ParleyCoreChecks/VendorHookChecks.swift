import Foundation
import ParleyCore

private enum VendorHookCheckFailure: Error {
    case failed(String)
}

private func hookExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VendorHookCheckFailure.failed(message) }
}

private func hookCheckDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-vendor-hook-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func hookPane(
    id: String,
    kind: PaneKind,
    runtimeState: VendorRuntimeState? = nil,
    runtimeSignal: VendorHookSignal? = nil
) -> WorkbenchPane {
    WorkbenchPane(
        id: id,
        kind: kind,
        customName: kind.label,
        terminalTitle: "PRIVATE TITLE",
        cwd: "/private/project",
        currentCommand: "PRIVATE COMMAND",
        isActive: true,
        workspaceID: "@hooks",
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "Hooks",
        inputAvailable: true,
        vendorRuntimeState: runtimeState,
        vendorRuntimeSignal: runtimeSignal,
        vendorRuntimeSignaledAt: runtimeSignal == nil ? nil : Date(timeIntervalSince1970: 100)
    )
}

func checkOfficialVendorHookAdaptersAndSignals() throws {
    try hookExpect(AgentProtocol.version == "11", "official hook semantics did not receive a protocol version")

    let directory = try hookCheckDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let protocolDirectory = try AgentProtocol.install(in: directory)
    let managedShim = protocolDirectory.deletingLastPathComponent().appendingPathComponent("bin/parley").path

    let claudeSettings = protocolDirectory.appendingPathComponent("claude-hooks.json")
    let copilotPlugin = protocolDirectory.appendingPathComponent("copilot-hooks", isDirectory: true)
    let adapterFiles = [
        claudeSettings,
        copilotPlugin.appendingPathComponent("plugin.json"),
        copilotPlugin.appendingPathComponent("hooks.json"),
    ]
    for file in adapterFiles {
        try hookExpect(FileManager.default.fileExists(atPath: file.path), "missing generated hook adapter \(file.lastPathComponent)")
        let permissions = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try hookExpect(permissions & 0o077 == 0, "generated hook adapter was readable outside its owner")
        let text = try String(contentsOf: file, encoding: .utf8)
        try hookExpect(text.contains("parley") && text.contains("signal"), "generated adapter does not call authenticated signal ingress")
        for privateField in ["PARLEY_RELAY_TOKEN", "workspacePaths", "transcriptPath", "prompt"] {
            try hookExpect(!text.contains(privateField), "generated adapter captures or embeds vendor content")
        }
    }
    for file in [claudeSettings, copilotPlugin.appendingPathComponent("hooks.json")] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
        try hookExpect(unescaped.contains(managedShim), "generated adapter does not use the absolute managed shim")
    }

    let expected: Set<VendorHookSignal> = [
        .sessionStarted, .turnStarted, .turnEnded, .awaitingPermission, .notification, .sessionEnded,
    ]
    try hookExpect(VendorHookAdapter.supportedSignals(for: .claude) == expected, "Claude hook coverage drifted")
    try hookExpect(VendorHookAdapter.supportedSignals(for: .copilot) == expected, "Copilot hook coverage drifted")
    try hookExpect(VendorHookAdapter.supportedSignals(for: .codex) == expected.subtracting([.notification]), "Codex hook coverage drifted")
    try hookExpect(VendorHookAdapter.supportedSignals(for: .agy).isEmpty, "Agy claimed a safe per-launch hook source")

    let claudeCommand = AgentProtocol.command(for: .claude, protocolDirectory: protocolDirectory)
    try hookExpect(claudeCommand.contains("--settings") && claudeCommand.contains(claudeSettings.path), "Claude did not receive session-scoped settings")
    let codexCommand = AgentProtocol.command(for: .codex, protocolDirectory: protocolDirectory)
    try hookExpect(codexCommand.filter { $0 == "-c" }.count >= 6, "Codex did not receive inline session hooks")
    try hookExpect(codexCommand.joined(separator: " ").contains("signal turn-started"), "Codex turn hook is missing")
    try hookExpect(codexCommand.joined(separator: " ").contains(managedShim), "Codex hooks do not use the managed shim")
    let copilotCommand = AgentProtocol.command(for: .copilot, protocolDirectory: protocolDirectory)
    try hookExpect(copilotCommand.contains("--plugin-dir") && copilotCommand.contains(copilotPlugin.path), "Copilot did not receive its session-only plugin")
    let agyCommand = AgentProtocol.command(for: .agy, protocolDirectory: protocolDirectory)
    try hookExpect(!agyCommand.joined(separator: " ").contains("signal"), "Agy received an unverified hook adapter")
    for command in [claudeCommand, codexCommand, copilotCommand, agyCommand] {
        let joined = command.joined(separator: " ")
        try hookExpect(!joined.contains("dangerously") && !joined.contains("bypass"), "hook adapter bypassed approval or trust")
    }

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let source = hookPane(id: "%hook-source", kind: .claude)
    let agy = hookPane(id: "%hook-agy", kind: .agy)
    let sourceToken = try credentials.token(for: source.id)
    let agyToken = try credentials.token(for: agy.id)
    var observed: [(String, VendorHookSignal)] = []
    let activityJournal = try RelayActivityJournal(
        file: directory.appendingPathComponent("activity-events.jsonl"),
        maximumEvents: 3
    )
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, agy] },
        paste: { _, _ in },
        submit: { _, _ in },
        vendorSignal: { paneID, signal, _ in observed.append((paneID, signal)) },
        activityJournal: activityJournal
    )
    let humanActivity = try broker.recordActivity(RelayActivityEventRequest(
        kind: .paneRestarted,
        workspaceID: source.workspaceID,
        workspaceName: source.workspaceName ?? source.workspaceID,
        paneID: source.id,
        paneName: source.displayName,
        paneKind: source.kind,
        detail: "Pane restarted by its owner."
    ))

    try hookExpect(broker.handleVendorSignal(token: "bad-token", signal: "turn-started").status == 401, "signals did not fail closed")
    try hookExpect(broker.handleVendorSignal(token: sourceToken, signal: "made-up").status == 400, "unknown signal was accepted")
    try hookExpect(broker.handleVendorSignal(token: agyToken, signal: "turn-started").status == 409, "unsupported Agy signal was accepted")
    let started = broker.handleVendorSignal(token: sourceToken, signal: "turn-started")
    try hookExpect(started.status == 200 && started.text.isEmpty, "official signal was not recorded silently")
    try hookExpect(observed.count == 1 && observed[0].0 == source.id && observed[0].1 == .turnStarted, "signal lost authenticated sender")

    try hookExpect(
        !broker.activityEvents().contains(where: { $0.kind == .vendorTurnStarted }),
        "high-frequency turn signal entered durable human activity"
    )
    try hookExpect(
        broker.activityEvents().contains(where: { $0.id == humanActivity.id }),
        "turn signal displaced human activity"
    )
    let eventResponse = broker.agentEvents(token: sourceToken, since: "beginning")
    let eventPage = try JSONDecoder().decode(RelayAgentEventPage.self, from: Data(eventResponse.text.utf8))
    try hookExpect(eventPage.events.contains(where: {
        $0.category == .vendorSignal && $0.vendorSignal == .turnStarted && $0.paneID == source.id
    }), "official signal did not reach resumable events")
    for forbidden in ["PRIVATE TITLE", "PRIVATE COMMAND", "/private/project", sourceToken] {
        try hookExpect(!eventResponse.text.contains(forbidden), "vendor event exposed private pane data")
    }

    try hookExpect(
        broker.handleVendorSignal(token: sourceToken, signal: "session-started").status == 200,
        "session start signal was refused"
    )
    let durableSession = try hookExpectValue(
        broker.activityEvents().first(where: { $0.kind == .vendorSessionStarted }),
        "low-frequency session signal was not retained for recovery"
    )
    try hookExpect(
        durableSession.origin == .automation && durableSession.detail == nil,
        "durable session signal retained content or claimed human origin"
    )
    for _ in 0..<12 {
        _ = broker.handleVendorSignal(token: sourceToken, signal: "turn-started")
        _ = broker.handleVendorSignal(token: sourceToken, signal: "turn-ended")
    }
    try hookExpect(
        broker.activityEvents().contains(where: { $0.id == humanActivity.id }),
        "turn traffic evicted human activity from the durable journal"
    )
    try hookExpect(
        !broker.activityEvents().contains(where: { $0.kind == .vendorTurnStarted || $0.kind == .vendorTurnEnded }),
        "turn traffic remained mixed into durable activity"
    )

    let working = hookPane(id: "%working", kind: .claude, runtimeState: .working, runtimeSignal: .turnStarted)
    let projected = try hookExpectValue(VendorRuntimeSignalProjection.signal(for: working), "official state projection disappeared")
    try hookExpect(projected.state == .working && projected.source == .vendorOfficialHook, "official state was not authoritative")
    let unknown = try hookExpectValue(VendorRuntimeSignalProjection.signal(for: agy), "unsupported projection disappeared")
    try hookExpect(unknown.state == .unknown && unknown.source == .unavailable, "unsupported vendor state was guessed")

    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { transport.stop() }
    let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": sourceToken]) { _, supplied in supplied }
    let output = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "signal", "turn-ended"],
        environment: environment,
        input: nil
    )
    try hookExpect(output.status == 0 && output.stdout.isEmpty, "shim signal did not cross protected transport silently")
    try hookExpect(observed.last?.0 == source.id && observed.last?.1 == .turnEnded, "transport signal lost source identity")
}

private func hookExpectValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw VendorHookCheckFailure.failed(message) }
    return value
}
