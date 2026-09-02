import Foundation
import ParleyCore

private enum AgentDiscoveryCheckFailure: Error {
    case failed(String)
}

private func discoveryExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw AgentDiscoveryCheckFailure.failed(message) }
}

private func discoveryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-agent-discovery-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func discoveryPane(
    id: String,
    kind: PaneKind,
    name: String,
    workspaceID: String,
    workspaceName: String,
    started: Bool = true,
    dead: Bool = false,
    relayEnabled: Bool = true,
    inputAvailable: Bool = true,
    protocolVersion: String? = AgentProtocol.version,
    role: String? = nil,
    lead: Bool = false
) -> WorkbenchPane {
    WorkbenchPane(
        id: id,
        kind: kind,
        customName: name,
        terminalTitle: "PRIVATE TERMINAL TITLE",
        cwd: "/private/workspace/path",
        currentCommand: "PRIVATE COMMAND",
        isActive: false,
        workspaceID: workspaceID,
        relayEnabled: relayEnabled,
        protocolVersion: protocolVersion,
        workspaceName: workspaceName,
        inputAvailable: inputAvailable,
        isDead: dead,
        isStarted: started,
        isWorkspaceLead: lead,
        role: role
    )
}

func checkAuthenticatedAgentDiscoveryAndResumableEvents() throws {
    let directory = try discoveryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let source = discoveryPane(
        id: "%1",
        kind: .codex,
        name: "Builder",
        workspaceID: "@alpha",
        workspaceName: "Alpha",
        role: "builder",
        lead: true
    )
    let target = discoveryPane(
        id: "%2",
        kind: .claude,
        name: "Reviewer",
        workspaceID: "@alpha",
        workspaceName: "Alpha",
        role: "reviewer"
    )
    let stopped = discoveryPane(
        id: "%3",
        kind: .agy,
        name: "Auditor",
        workspaceID: "@beta",
        workspaceName: "Beta",
        started: false,
        relayEnabled: false,
        inputAvailable: false,
        protocolVersion: nil
    )
    let shell = discoveryPane(
        id: "%4",
        kind: .shell,
        name: "Shell",
        workspaceID: "@alpha",
        workspaceName: "Alpha",
        relayEnabled: false,
        protocolVersion: nil
    )
    let panes = [source, target, stopped, shell]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in }
    )

    let identityResponse = broker.agentIdentity(token: sourceToken)
    try discoveryExpect(identityResponse.status == 200, "authenticated whoami failed")
    let identity = try JSONDecoder().decode(RelayAgentIdentity.self, from: Data(identityResponse.text.utf8))
    try discoveryExpect(identity.paneID == source.id, "whoami lost the authenticated pane id")
    try discoveryExpect(identity.vendor == .codex, "whoami lost the vendor identity")
    try discoveryExpect(identity.workspaceID == source.workspaceID, "whoami lost the workspace identity")
    try discoveryExpect(identity.role == "@builder", "whoami did not return a canonical role")
    try discoveryExpect(identity.qualifiedRole == "@alpha/@builder", "whoami did not return a durable qualified role")
    try discoveryExpect(identity.isWorkspaceLead, "whoami lost the app-owned lead identity")
    let identityJSON = identityResponse.text.lowercased()
    for forbidden in ["private/workspace", "private command", "private terminal", sourceToken] {
        try discoveryExpect(!identityJSON.contains(forbidden.lowercased()), "whoami exposed private process or credential data")
    }
    try discoveryExpect(broker.agentIdentity(token: "bad-token").status == 401, "whoami did not fail closed")

    let panesResponse = broker.agentPanes(token: sourceToken)
    try discoveryExpect(panesResponse.status == 200, "authenticated pane discovery failed")
    let discovered = try JSONDecoder().decode(RelayAgentPaneList.self, from: Data(panesResponse.text.utf8))
    try discoveryExpect(discovered.panes.map(\.paneID) == ["%2", "%3"], "pane discovery was not bounded to explicit non-self agent targets")
    try discoveryExpect(!discovered.truncated, "a small pane list claimed truncation")
    let readyTarget = try discoveryExpectValue(discovered.panes.first(where: { $0.paneID == "%2" }), "ready target disappeared")
    try discoveryExpect(readyTarget.lifecycle == .running, "ready target lost its app-owned lifecycle")
    try discoveryExpect(readyTarget.inputPathAvailable, "ready target lost its Ghostty input fact")
    try discoveryExpect(readyTarget.role == "@reviewer", "target role was not canonical")
    let stoppedTarget = try discoveryExpectValue(discovered.panes.first(where: { $0.paneID == "%3" }), "stopped target disappeared")
    try discoveryExpect(stoppedTarget.lifecycle == .stopped, "stopped target was presented as running")
    try discoveryExpect(!stoppedTarget.inputPathAvailable, "stopped target claimed a live input path")
    let panesJSON = panesResponse.text.lowercased()
    for forbidden in ["private/workspace", "private command", "private terminal", sourceToken] {
        try discoveryExpect(!panesJSON.contains(forbidden.lowercased()), "pane discovery exposed private process or credential data")
    }

    let relay = broker.handle(
        token: sourceToken,
        target: target.id,
        text: "PRIVATE_HANDOFF_BODY",
        idempotencyKey: "discovery-event-relay"
    )
    try discoveryExpect(relay.status == 200, "event fixture relay failed")
    _ = try broker.recordActivity(RelayActivityEventRequest(
        kind: .paneRestarted,
        workspaceID: source.workspaceID,
        workspaceName: source.workspaceName ?? "Alpha",
        paneID: source.id,
        paneName: source.displayName,
        paneKind: source.kind,
        detail: "PRIVATE_ACTIVITY_DETAIL"
    ))
    let firstResponse = broker.agentEvents(token: sourceToken, since: "beginning")
    try discoveryExpect(firstResponse.status == 200, "initial event page failed")
    let first = try JSONDecoder().decode(RelayAgentEventPage.self, from: Data(firstResponse.text.utf8))
    try discoveryExpect(first.events.count == 4, "event page omitted handoff transitions or native activity")
    try discoveryExpect(first.events.map(\.occurredAt) == first.events.map(\.occurredAt).sorted(), "events were not chronological")
    try discoveryExpect(first.events.contains(where: { $0.category == .handoffTransition }), "handoff events disappeared")
    try discoveryExpect(first.events.contains(where: { $0.category == .activity }), "native activity disappeared")
    try discoveryExpect(!first.hasMore, "small event page claimed more records")
    for forbidden in ["PRIVATE_HANDOFF_BODY", "PRIVATE_ACTIVITY_DETAIL", sourceToken] {
        try discoveryExpect(!firstResponse.text.contains(forbidden), "event discovery exposed content or credentials")
    }

    let caughtUp = try JSONDecoder().decode(
        RelayAgentEventPage.self,
        from: Data(broker.agentEvents(token: sourceToken, since: first.nextCursor).text.utf8)
    )
    try discoveryExpect(caughtUp.events.isEmpty && caughtUp.nextCursor == first.nextCursor, "event cursor did not resume exactly")
    _ = try broker.recordActivity(RelayActivityEventRequest(
        kind: .workspaceRestored,
        workspaceID: "@beta",
        workspaceName: "Beta"
    ))
    let resumed = try JSONDecoder().decode(
        RelayAgentEventPage.self,
        from: Data(broker.agentEvents(token: sourceToken, since: first.nextCursor).text.utf8)
    )
    try discoveryExpect(resumed.events.count == 1, "event cursor skipped or replayed records")

    var clockValues = [
        Date(timeIntervalSince1970: 200),
        Date(timeIntervalSince1970: 100),
    ]
    let orderingBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        clock: { clockValues.removeFirst() }
    )
    _ = try orderingBroker.recordActivity(RelayActivityEventRequest(
        kind: .workspaceCreated,
        workspaceID: "@clock",
        workspaceName: "Clock"
    ))
    let orderingEdge = try JSONDecoder().decode(
        RelayAgentEventPage.self,
        from: Data(orderingBroker.agentEvents(token: sourceToken, since: "beginning").text.utf8)
    ).nextCursor
    _ = try orderingBroker.recordActivity(RelayActivityEventRequest(
        kind: .workspaceRestored,
        workspaceID: "@clock",
        workspaceName: "Clock"
    ))
    let afterClockStep = try JSONDecoder().decode(
        RelayAgentEventPage.self,
        from: Data(orderingBroker.agentEvents(token: sourceToken, since: orderingEdge).text.utf8)
    )
    try discoveryExpect(
        afterClockStep.events.count == 1 && afterClockStep.events[0].activityKind == .workspaceRestored,
        "event cursor silently skipped an event recorded after a backwards clock step"
    )
    try discoveryExpect(broker.agentEvents(token: sourceToken, since: "v1:missing").status == 410, "expired event cursor was silently accepted")
    try discoveryExpect(broker.agentEvents(token: "bad-token", since: "beginning").status == 401, "events did not fail closed")

    let manyPanes = [source] + (0..<(RelayAgentPaneList.maximumPanes + 5)).map { index in
        discoveryPane(
            id: "%bounded-\(index)",
            kind: .claude,
            name: "Target \(index)",
            workspaceID: "@bounded",
            workspaceName: "Bounded"
        )
    }
    let boundedBroker = RelayBroker(
        credentials: credentials,
        panes: { manyPanes },
        paste: { _, _ in },
        submit: { _, _ in }
    )
    let boundedPanes = try JSONDecoder().decode(
        RelayAgentPaneList.self,
        from: Data(boundedBroker.agentPanes(token: sourceToken).text.utf8)
    )
    try discoveryExpect(boundedPanes.panes.count == RelayAgentPaneList.maximumPanes && boundedPanes.truncated, "pane discovery was not bounded")
    for index in 0..<(RelayAgentEventPage.maximumEvents + 5) {
        _ = try boundedBroker.recordActivity(RelayActivityEventRequest(
            kind: .workspaceCreated,
            workspaceID: "@bounded",
            workspaceName: "Bounded",
            detail: "PRIVATE EVENT \(index)"
        ))
    }
    let pageOne = try JSONDecoder().decode(
        RelayAgentEventPage.self,
        from: Data(boundedBroker.agentEvents(token: sourceToken, since: "beginning").text.utf8)
    )
    try discoveryExpect(pageOne.events.count == RelayAgentEventPage.maximumEvents && pageOne.hasMore, "event discovery did not enforce its page bound")
    let pageTwo = try JSONDecoder().decode(
        RelayAgentEventPage.self,
        from: Data(boundedBroker.agentEvents(token: sourceToken, since: pageOne.nextCursor).text.utf8)
    )
    try discoveryExpect(pageTwo.events.count == 5 && !pageTwo.hasMore, "event pagination was not resumable")

    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { transport.stop() }
    let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": sourceToken]) { _, supplied in supplied }
    let executable = URL(fileURLWithPath: "/bin/sh")
    let shim = shimDirectory.appendingPathComponent("parley").path
    let runner = ProcessCommandRunner(timeout: 5)
    let shimIdentity = try runner.run(executable: executable, arguments: [shim, "whoami"], environment: environment, input: nil)
    try discoveryExpect(shimIdentity.status == 0, "parley whoami did not cross the protected filesystem transport")
    _ = try JSONDecoder().decode(RelayAgentIdentity.self, from: shimIdentity.stdout)
    let shimPanes = try runner.run(executable: executable, arguments: [shim, "panes"], environment: environment, input: nil)
    try discoveryExpect(shimPanes.status == 0, "parley panes did not cross the protected filesystem transport")
    _ = try JSONDecoder().decode(RelayAgentPaneList.self, from: shimPanes.stdout)
    let shimEvents = try runner.run(executable: executable, arguments: [shim, "events", "--since", "beginning"], environment: environment, input: nil)
    try discoveryExpect(shimEvents.status == 0, "parley events did not cross the protected filesystem transport")
    _ = try JSONDecoder().decode(RelayAgentEventPage.self, from: shimEvents.stdout)
}

private func discoveryExpectValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw AgentDiscoveryCheckFailure.failed(message)
    }
    return value
}
