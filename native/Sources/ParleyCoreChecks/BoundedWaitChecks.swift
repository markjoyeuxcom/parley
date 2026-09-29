import Dispatch
import Foundation
import ParleyCore

private func waitExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "BoundedWait", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func waitRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "BoundedWait", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// A lead and a worker behind a real file transport.
private struct TransportFixture {
    let directory: URL
    let credentials: RelayCredentials
    let lead: WorkbenchPane
    let worker: WorkbenchPane
    let leadToken: String
    let workerToken: String
    let transportDirectory: URL

    init(_ name: String) throws {
        directory = URL(fileURLWithPath: "/tmp/parley-\(name)-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
            WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/\(id)", currentCommand: "x", isActive: false,
                          workspaceID: "@wait", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Wait",
                          inputAvailable: true)
        }
        lead = pane("lead", .claude)
        worker = pane("worker", .codex)
        leadToken = try credentials.token(for: lead.id)
        workerToken = try credentials.token(for: worker.id)
        transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    /// Writes one request the way the shim does and returns its reply marker.
    func post(_ command: String, token: String, item: String = "", body: String = "") throws -> URL {
        let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
        let id = UUID().uuidString.lowercased()
        let request = endpoint.appendingPathComponent("inbox", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, value) in [("command", command), ("token", token), ("target", ""), ("item", item),
                              ("idempotency-key", "wait-check-\(id.prefix(12))"), ("body", body)] {
            let file = request.appendingPathComponent(name)
            try Data(value.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        // `ready` goes last and is not touched afterwards: the transport may
        // claim the request the moment it appears (a chmod after it raced a
        // fast claim on the CI runner).
        try Data("ready".utf8).write(to: request.appendingPathComponent("ready"))
        return endpoint.appendingPathComponent("outbox", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    static func replied(_ response: URL) -> Bool {
        FileManager.default.fileExists(atPath: response.appendingPathComponent("ready").path)
    }

    static func status(_ response: URL) -> Int? {
        (try? String(contentsOf: response.appendingPathComponent("status"), encoding: .utf8)).flatMap { Int($0) }
    }
}

private func eventually(within seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds > deadline { return false }
        usleep(20_000)
    }
    return true
}

/// Review of 22 September 2026, H2: every agent request ran on the shared
/// dispatch pool and `parley wait` blocked with no deadline, so a few dozen
/// waits whose shims a vendor had killed filled the pool and the worker's own
/// `parley done`, the one request that would release them, was never
/// processed. Waits must not be able to stop anything else.
func checkParkedWaitsNeverStarveADone() throws {
    let fixture = try TransportFixture("starve")
    defer { fixture.cleanup() }
    let broker = RelayBroker(credentials: fixture.credentials, panes: { [fixture.lead, fixture.worker] },
                             paste: { _, _ in }, submit: { _, _ in }, livenessPollInterval: 0.05)
    let transport = RelayFileTransport(broker: broker, credentials: fixture.credentials, runtimeDirectory: fixture.transportDirectory)
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: fixture.transportDirectory, paneToken: fixture.leadToken)
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: fixture.transportDirectory, paneToken: fixture.workerToken)
    try transport.start()
    defer { transport.stop() }

    let delegated = broker.handleDelegate(token: fixture.leadToken, target: fixture.worker.id, text: "Long work.", idempotencyKey: "starve-work")
    let handoffID = try waitRequire(delegated.body.handoffID, "the delegation returned no id")
    // More parked waits than the shared pool has threads (70 on the Mac the
    // review ran on), as orphaned `parley wait` retries leave behind.
    let waits = try (0..<80).map { _ in try fixture.post("wait", token: fixture.leadToken, item: handoffID) }
    // Every wait must be parked or refused before the done arrives: a fixed
    // half second was too short on a loaded run, and a wait the transport
    // reached only after the done returned at once and was counted as parked.
    let limit = RelayFileTransport.defaultMaximumBlockingRequests
    try waitExpect(eventually(within: 20) {
        transport.activeBlockingRequests == limit && waits.filter { TransportFixture.status($0) == 503 }.count == waits.count - limit
    }, "the 80 waits were not all parked or refused: \(transport.activeBlockingRequests) parked")
    let done = try fixture.post("done", token: fixture.workerToken, item: handoffID, body: "Finished.")
    let doneProcessed = eventually(within: 10) { TransportFixture.replied(done) }
    if !doneProcessed {
        // Release the parked waits so a failure here cannot wedge later checks.
        _ = broker.handleDelegationResult(token: fixture.workerToken, handoffID: handoffID, text: "Finished.", succeeded: true)
    }
    try waitExpect(doneProcessed, "the worker's done was not processed while 80 waits were parked")
    try waitExpect(TransportFixture.status(done) == 200, "the worker's done failed: \(String(describing: TransportFixture.status(done)))")
    try waitExpect(eventually(within: 10) { waits.allSatisfy(TransportFixture.replied) }, "the parked waits did not all return after done")
    // Past the blocking limit a wait is refused at once rather than parked.
    let statuses = waits.map(TransportFixture.status)
    try waitExpect(statuses.filter { $0 == 503 }.count == waits.count - limit && statuses.filter { $0 == 200 }.count == limit,
                   "the \(limit) admitted waits did not all return the result and the rest were not refused: \(statuses)")
    try waitExpect(transport.activeBlockingRequests == 0, "blocking requests were still counted after every wait returned")
}

/// `parley wait` is a bounded long-poll: the broker answers "still waiting"
/// when its window passes, and the real shim asks again without printing
/// anything, so the agent still sees one blocking command and one result.
func checkWaitIsABoundedLongPollTheShimRepeats() throws {
    let fixture = try TransportFixture("longpoll")
    defer { fixture.cleanup() }
    let broker = RelayBroker(credentials: fixture.credentials, panes: { [fixture.lead, fixture.worker] },
                             paste: { _, _ in }, submit: { _, _ in }, livenessPollInterval: 0.05)
    let window: TimeInterval = 0.4
    let transport = RelayFileTransport(broker: broker, credentials: fixture.credentials, runtimeDirectory: fixture.transportDirectory,
                                       waitWindow: window)
    let shim = try RelayShim.install(in: fixture.directory, transportDirectory: fixture.transportDirectory).appendingPathComponent("parley")
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: fixture.transportDirectory, paneToken: fixture.leadToken)
    try transport.start()
    defer { transport.stop() }

    let delegated = broker.handleDelegate(token: fixture.leadToken, target: fixture.worker.id, text: "Slow work.", idempotencyKey: "longpoll-work")
    let handoffID = try waitRequire(delegated.body.handoffID, "the delegation returned no id")
    let polled = broker.waitForTrackedWork(token: fixture.leadToken, handoffID: handoffID, within: 0.2)
    try waitExpect(polled == RelayBroker.stillWaiting, "a bounded wait on open work did not return still waiting: \(polled)")
    try waitExpect(broker.handoffs().first { $0.id == handoffID }?.state == .waiting, "a still-waiting reply changed the delegation")

    final class Outcome: @unchecked Sendable { var output: CommandOutput?; var error: Error?; var seconds = 0.0 }
    let outcome = Outcome()
    let finished = DispatchSemaphore(value: 0)
    let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": fixture.leadToken]) { _, supplied in supplied }
    Thread {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            outcome.output = try ProcessCommandRunner(timeout: 20).run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shim.path, "wait", handoffID], environment: environment, input: nil)
        } catch { outcome.error = error }
        outcome.seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        finished.signal()
    }.start()
    Thread.sleep(forTimeInterval: window * 4)
    try waitExpect(broker.handleDelegationResult(token: fixture.workerToken, handoffID: handoffID, text: "Finished.", succeeded: true).status == 200,
                   "the worker could not report while the lead waited")
    try waitExpect(finished.wait(timeout: .now() + 15) == .success, "the shim's wait never returned")
    let output = try waitRequire(outcome.output, "the shim did not run: \(String(describing: outcome.error))")
    try waitExpect(output.status == 0 && output.stdoutText == "Finished.",
                   "the shim did not print exactly the result after several windows: status \(output.status), stdout \(output.stdoutText.debugDescription), stderr \(output.stderrText)")
    try waitExpect(outcome.seconds >= window * 3, "the shim returned before the work ended (\(outcome.seconds) s)")
}

/// A reply whose shim was killed is removed once it is old; a request still
/// in progress (no `ready` yet) is left alone.
func checkStaleRepliesAreRemoved() throws {
    let fixture = try TransportFixture("stale")
    defer { fixture.cleanup() }
    let broker = RelayBroker(credentials: fixture.credentials, panes: { [fixture.lead] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: fixture.credentials, runtimeDirectory: fixture.transportDirectory,
                                       staleResponseAge: 1)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: fixture.transportDirectory, paneToken: fixture.leadToken)
    try transport.start()
    defer { transport.stop() }
    let outbox = endpoint.appendingPathComponent("outbox", isDirectory: true)
    func reply(ready: Bool) throws -> URL {
        let reply = outbox.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: reply, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = reply.appendingPathComponent(ready ? "ready" : "accepted")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        return reply
    }
    let abandoned = try reply(ready: true)
    let inProgress = try reply(ready: false)
    try waitExpect(eventually(within: 5) { !FileManager.default.fileExists(atPath: abandoned.path) }, "an abandoned reply was never removed")
    try waitExpect(FileManager.default.fileExists(atPath: inProgress.path), "a reply still in progress was removed")
}

/// Agy's review of 469621d: `ask-many` still started each child Ask on the
/// shared pool, where it blocks until its target answers. With the pool full,
/// the children never start and the ask-many never returns. The relay must
/// not need the shared pool at all.
func checkAskManyDoesNotNeedTheSharedPool() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-askmany-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/\(id)", currentCommand: "x", isActive: false,
                      workspaceID: "@many", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Many", inputAvailable: true)
    }
    let source = pane("source", .claude), first = pane("first", .codex), second = pane("second", .agy)
    let sourceToken = try credentials.token(for: source.id)
    let targetTokens = [try credentials.token(for: first.id), try credentials.token(for: second.id)]
    let broker = RelayBroker(credentials: credentials, panes: { [source, first, second] }, paste: { _, _ in }, submit: { _, _ in },
                             consultationTimeout: 4, livenessPollInterval: 0.05)

    // Fill the shared pool with work that blocks, the way parked Asks do.
    let blocker = DispatchSemaphore(value: 0)
    let blockers = 100
    for _ in 0..<blockers { DispatchQueue.global(qos: .utility).async { blocker.wait() } }
    var released = false
    func release() { if !released { released = true; for _ in 0..<blockers { blocker.signal() } } }
    defer { release() }
    Thread.sleep(forTimeInterval: 0.3)

    final class Result: @unchecked Sendable { var response: RelayTextResponse? }
    let result = Result()
    let finished = DispatchSemaphore(value: 0)
    Thread {
        result.response = broker.handleAskMany(token: sourceToken, targets: "first,second", text: "Which is better?")
        finished.signal()
    }.start()
    // Each target answers from its own thread once its question is waiting.
    Thread {
        var answered = Set<Int>()
        let deadline = Date().addingTimeInterval(3)
        while answered.count < 2, Date() < deadline {
            for (index, token) in targetTokens.enumerated() where !answered.contains(index) {
                if broker.handleAnswer(token: token, consultationID: "current", text: "Answer \(index)").status == 200 { answered.insert(index) }
            }
            usleep(20_000)
        }
    }.start()
    let returned = finished.wait(timeout: .now() + 3) == .success
    release()
    if !returned { _ = finished.wait(timeout: .now() + 10) }
    try waitExpect(returned, "ask-many did not return while the shared pool was full")
    let response = try waitRequire(result.response, "ask-many returned nothing")
    try waitExpect(response.status == 200 && response.text.contains("Answer 0") && response.text.contains("Answer 1"),
                   "ask-many did not carry both answers: \(response.status) \(response.text)")
}

/// A burst of short requests is served, but never by more threads at once
/// than the transport's worker limit; the rest wait in the inbox.
func checkShortRequestBurstsAreBoundedInThreads() throws {
    let fixture = try TransportFixture("burst")
    defer { fixture.cleanup() }
    let broker = RelayBroker(credentials: fixture.credentials, panes: { [fixture.lead] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: fixture.credentials, runtimeDirectory: fixture.transportDirectory,
                                       maximumBlockingRequests: 2, maximumWorkerThreads: 4)
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: fixture.transportDirectory, paneToken: fixture.leadToken)
    try transport.start()
    defer { transport.stop() }
    let replies = try (0..<120).map { _ in try fixture.post("whoami", token: fixture.leadToken) }
    try waitExpect(eventually(within: 20) { replies.allSatisfy(TransportFixture.replied) }, "a burst of short requests was not all answered")
    try waitExpect(replies.allSatisfy { TransportFixture.status($0) == 200 }, "a request in the burst failed")
    try waitExpect(transport.peakWorkerThreads <= 4, "the burst ran on \(transport.peakWorkerThreads) threads at once, over the limit of 4")
    // The limit always stays above the blocking limit, so parked waits can
    // never take every thread from a done.
    let tight = RelayFileTransport(broker: broker, credentials: fixture.credentials, runtimeDirectory: fixture.transportDirectory,
                                   maximumBlockingRequests: 8, maximumWorkerThreads: 4)
    try waitExpect(tight.maximumWorkerThreadLimit == 9, "a thread limit at or below the blocking limit was accepted: \(tight.maximumWorkerThreadLimit)")
}

@MainActor let boundedWaitChecks: [(String, () throws -> Void)] = [
    ("ask-many does not need the shared pool", checkAskManyDoesNotNeedTheSharedPool),
    ("short request bursts are bounded in threads", checkShortRequestBurstsAreBoundedInThreads),
    ("parked waits never starve a done", checkParkedWaitsNeverStarveADone),
    ("wait is a bounded long-poll the shim repeats", checkWaitIsABoundedLongPollTheShimRepeats),
    ("stale replies are removed", checkStaleRepliesAreRemoved),
]
