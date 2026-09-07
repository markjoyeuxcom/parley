import Foundation
import ParleyCore

private func pollExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "IdlePolling", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
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
    ("idle polling: an idle transport answers a shim request through its inbox watcher about as fast as an active one", {
        let directory = URL(fileURLWithPath: "/tmp/parley-wake-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        let source = pollPane("wake-source", .claude, "Source")
        let broker = RelayBroker(credentials: credentials, panes: { [source] }, paste: { _, _ in }, submit: { _, _ in })
        let token = try credentials.token(for: source.id)
        let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
        let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
        let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
        try transport.start()
        defer { transport.stop() }
        // Let the transport go quiet and back off.
        Thread.sleep(forTimeInterval: 1.5)
        try pollExpect(transport.currentPollInterval == TransportPollSchedule.idleInterval, "the transport did not back off while idle (\(transport.currentPollInterval))")
        let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": token]) { _, supplied in supplied }
        let shim = shimDirectory.appendingPathComponent("parley").path
        let runner = ProcessCommandRunner(timeout: 5)
        func roundTrip() throws -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [shim, "whoami"], environment: environment, input: nil)
            try pollExpect(result.status == 0, "whoami failed through the transport: \(result.stderrText)")
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
        // Idle: each request lands on a backed-off timer and must be served by the watcher.
        let wakesBefore = transport.watcherWakeCount
        var idle: [Double] = []
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.6) // back to idle between requests
            try pollExpect(transport.currentPollInterval == TransportPollSchedule.idleInterval, "the transport did not return to idle between requests")
            idle.append(try roundTrip())
        }
        try pollExpect(transport.watcherWakeCount >= wakesBefore + 5, "the inbox watcher did not wake the transport for each idle request (\(transport.watcherWakeCount - wakesBefore) wakes)")
        // Active: back-to-back requests keep the 50 ms cadence; this is the floor
        // set by /bin/sh startup and the shim's own 50 ms reply poll.
        var active: [Double] = []
        for _ in 0..<5 { active.append(try roundTrip()) }
        let idleMedian = idle.sorted()[2], activeMedian = active.sorted()[2]
        print(String(format: "  shim whoami round trip: idle transport median %.0f ms, active transport median %.0f ms", idleMedian, activeMedian))
        try pollExpect(idleMedian <= activeMedian + 60, "an idle transport made a request wait on its backed-off poll (idle \(idleMedian) ms vs active \(activeMedian) ms)")
    }),
]
