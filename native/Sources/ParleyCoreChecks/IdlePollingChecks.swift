import Foundation
import ParleyCore

private func pollExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "IdlePolling", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Waits for the transport's quiet streak to back the timer off. The streak
/// is counted in ticks, and a loaded CI runner delivers utility-priority
/// timer ticks late, so a check waits for the state rather than a fixed time.
private func waitUntilIdle(_ transport: RelayFileTransport, timeout: TimeInterval = 8) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while transport.currentPollInterval != TransportPollSchedule.idleInterval {
        try pollExpect(Date() < deadline, "the transport did not back off within \(timeout) s (interval \(transport.currentPollInterval), ticks \(transport.tickCount))")
        Thread.sleep(forTimeInterval: 0.05)
    }
}

private func pollPane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/tmp", currentCommand: kind.rawValue,
        isActive: false, workspaceID: "workspace", relayEnabled: true, workspaceName: "Idle", inputAvailable: true,
        automationPolicy: .askAndDelegate)
}

@MainActor
let idlePollingChecks: [(String, () throws -> Void)] = [
    ("idle polling: the relay poll policy skips unchanged ticks and still forces a periodic fetch", {
        typealias Policy = RelayPollPolicy
        try pollExpect(Policy.shouldFetch(revision: 5, lastApplied: nil, ticksSinceFetch: 0), "a first tick did not fetch")
        try pollExpect(!Policy.shouldFetch(revision: 5, lastApplied: 5, ticksSinceFetch: 1), "an unchanged tick fetched")
        try pollExpect(Policy.shouldFetch(revision: 6, lastApplied: 5, ticksSinceFetch: 1), "a changed revision did not fetch")
        try pollExpect(!Policy.shouldFetch(revision: 5, lastApplied: 5, ticksSinceFetch: Policy.forcedFetchEveryTicks - 1), "the safety net fired early")
        try pollExpect(Policy.shouldFetch(revision: 5, lastApplied: 5, ticksSinceFetch: Policy.forcedFetchEveryTicks), "the safety net did not force a fetch")
        try pollExpect(Policy.forcedFetchEveryTicks >= 5 && Policy.forcedFetchEveryTicks <= 30, "the safety net cadence drifted outside 5–30 ticks")
    }),
    ("idle polling: every broker mutation the relay poll reads advances the state revision", {
        let directory = URL(fileURLWithPath: "/tmp/parley-rev-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        let source = pollPane("rev-source", .claude, "Source")
        let target = pollPane("rev-target", .codex, "Target")
        let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in },
            contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json")))
        let token = try credentials.token(for: source.id)
        let start = broker.stateRevision()
        try pollExpect(broker.stateRevision() == start, "reading the revision changed it")
        let relayed = broker.handle(token: token, target: target.id, text: "hello", idempotencyKey: "idle-poll-revision-1")
        try pollExpect(relayed.status == 200, "relay fixture failed: \(relayed)")
        let afterRelay = broker.stateRevision()
        try pollExpect(afterRelay > start, "a relay did not advance the revision")
        // A repeated idempotent submission changes nothing the poll reads.
        _ = broker.handle(token: token, target: target.id, text: "hello", idempotencyKey: "idle-poll-revision-1")
        let afterRepeat = broker.stateRevision()
        let draft = broker.handleContextDraft(token: token, name: "Draft", path: "/tmp/draft.txt", text: "context")
        try pollExpect(draft.status == 200 || draft.status == 201, "context draft fixture failed: \(draft.text)")
        let afterDraft = broker.stateRevision()
        try pollExpect(afterDraft > afterRepeat, "staging a context draft did not advance the revision")
        let object = (try? JSONSerialization.jsonObject(with: Data(draft.text.utf8))) as? [String: Any]
        guard let draftID = (object?["draftID"] ?? object?["id"]) as? String else {
            throw NSError(domain: "IdlePolling", code: 2, userInfo: [NSLocalizedDescriptionKey: "no draft id in \(draft.text)"])
        }
        try pollExpect(broker.discardContextDraft(token: token, draftID: draftID).status == 200, "discard fixture failed")
        try pollExpect(broker.stateRevision() > afterDraft, "discarding a context draft did not advance the revision")
        _ = try broker.recordActivity(RelayActivityEventRequest(kind: .paneRestarted, workspaceID: "workspace", workspaceName: "Idle",
            paneID: source.id, paneName: source.displayName, paneKind: source.kind, detail: "fixture"))
        try pollExpect(broker.stateRevision() > afterDraft, "activity recording did not advance the revision")
    }),
    ("idle polling: the transport schedule backs off when quiet and returns to 50 ms on activity", {
        typealias Schedule = TransportPollSchedule
        var schedule = Schedule()
        try pollExpect(schedule.interval == Schedule.activeInterval, "the transport did not start active")
        for _ in 0..<(Schedule.quietTicksBeforeBackoff - 1) { schedule.observe(activity: false) }
        try pollExpect(schedule.interval == Schedule.activeInterval, "the transport backed off before the quiet streak completed")
        schedule.observe(activity: false)
        try pollExpect(schedule.interval == Schedule.idleInterval, "the transport did not back off after the quiet streak")
        schedule.observe(activity: true)
        try pollExpect(schedule.interval == Schedule.activeInterval, "activity did not restore the active interval")
        schedule.wake()
        try pollExpect(schedule.interval == Schedule.activeInterval, "a wake did not keep the active interval")
        try pollExpect(Schedule.activeInterval == .milliseconds(50) && Schedule.idleInterval == .milliseconds(250), "intervals drifted from 50 ms active / 250 ms idle")
    }),
    ("idle polling: a request directory abandoned without its ready marker returns the transport to normal cadence and is discarded", {
        let directory = URL(fileURLWithPath: "/tmp/parley-abandon-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        let source = pollPane("abandon-source", .claude, "Source")
        let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in })
        let token = try credentials.token(for: source.id)
        let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
        let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
        let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory, abandonedRequestAge: 2.0)
        try transport.start()
        defer { transport.stop() }
        try waitUntilIdle(transport)
        // A writer that created its request directory and then died.
        let abandoned = endpoint.appendingPathComponent("inbox", isDirectory: true).appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        // Let the bounded fast follow-up window pass.
        Thread.sleep(forTimeInterval: RelayFileTransport.pendingFollowUpWindow + 0.15)
        let ticksAfterFollowUp = transport.tickCount
        // After the window the directory is polled at normal cadence and the
        // quiet streak backs the timer off again: a spinning transport would
        // service around two hundred ticks in the next second; a healthy one
        // about ten at 50 ms and then a few at 250 ms.
        Thread.sleep(forTimeInterval: 1.0)
        let ticksInQuietSecond = transport.tickCount - ticksAfterFollowUp
        print("  ticks in the second after an abandoned request: \(ticksInQuietSecond)")
        try pollExpect(ticksInQuietSecond <= 25, "the transport kept spinning on an abandoned request (\(ticksInQuietSecond) ticks in one second)")
        try pollExpect(FileManager.default.fileExists(atPath: abandoned.path), "the request directory was discarded before its age limit")
        try waitUntilIdle(transport, timeout: 3)
        // Past the age limit the directory is discarded (the removal itself wakes the watcher once).
        Thread.sleep(forTimeInterval: 1.0)
        try pollExpect(!FileManager.default.fileExists(atPath: abandoned.path), "the abandoned request directory was not discarded after its age limit")
    }),
    ("idle polling: an idle transport answers a request through its inbox watcher, not its backed-off timer", {
        let directory = URL(fileURLWithPath: "/tmp/parley-wake-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        let source = pollPane("wake-source", .claude, "Source")
        let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in })
        let token = try credentials.token(for: source.id)
        let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
        let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
        let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
        let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
        try transport.start()
        defer { transport.stop() }
        // A request written the way the shim writes it, timed from its `ready`
        // marker to the transport's `ready` reply: the transport's own latency,
        // without /bin/sh startup or the shim's 50 ms reply poll.
        func directRequest() throws -> Double {
            let id = UUID().uuidString.lowercased()
            let request = endpoint.appendingPathComponent("inbox", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: request, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (name, value) in [("command", "whoami"), ("token", token), ("target", ""), ("item", ""), ("idempotency-key", "idle-poll-\(id.prefix(8))"), ("body", "")] {
                let file = request.appendingPathComponent(name)
                try Data(value.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            let ready = request.appendingPathComponent("ready")
            let replied = endpoint.appendingPathComponent("outbox", isDirectory: true).appendingPathComponent(id, isDirectory: true).appendingPathComponent("ready")
            let started = DispatchTime.now().uptimeNanoseconds
            try Data("ready".utf8).write(to: ready)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ready.path)
            while !FileManager.default.fileExists(atPath: replied.path) {
                try pollExpect(DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000, "the transport did not answer a direct request within 2 s")
                usleep(1_000)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            try? FileManager.default.removeItem(at: replied.deletingLastPathComponent())
            return elapsed
        }
        try waitUntilIdle(transport)
        let wakesBefore = transport.watcherWakeCount
        var idle: [Double] = []
        for _ in 0..<5 {
            try waitUntilIdle(transport) // back to idle between requests
            idle.append(try directRequest())
        }
        try pollExpect(transport.watcherWakeCount >= wakesBefore + 5, "the inbox watcher did not wake the transport for each idle request (\(transport.watcherWakeCount - wakesBefore) wakes)")
        var active: [Double] = []
        for _ in 0..<5 { active.append(try directRequest()) }
        let idleMedian = idle.sorted()[2], activeMedian = active.sorted()[2]
        // One shim round trip for the record: /bin/sh startup plus the shim's own 50 ms reply poll.
        let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": token]) { _, supplied in supplied }
        let shim = shimDirectory.appendingPathComponent("parley").path
        let shimStarted = DispatchTime.now().uptimeNanoseconds
        let shimResult = try ProcessCommandRunner(timeout: 5).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [shim, "whoami"], environment: environment, input: nil)
        let shimMs = Double(DispatchTime.now().uptimeNanoseconds - shimStarted) / 1_000_000
        try pollExpect(shimResult.status == 0, "whoami failed through the transport: \(shimResult.stderrText)")
        print(String(format: "  transport latency, ready to reply: idle median %.1f ms (watcher), active median %.1f ms; one shim round trip %.0f ms", idleMedian, activeMedian, shimMs))
        // A backed-off timer alone would average 125 ms and reach 250 ms.
        try pollExpect(idleMedian < 100, "an idle transport made a request wait on its backed-off poll (median \(idleMedian) ms)")
        try pollExpect(idle.max()! < 250, "an idle request waited a full backed-off cadence (max \(idle.max()!) ms)")
    }),
]
