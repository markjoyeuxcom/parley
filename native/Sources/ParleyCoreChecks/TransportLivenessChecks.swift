import Darwin
import Dispatch
import Foundation
import ParleyCore

private func livenessExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "TransportLiveness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func livenessEventually(within seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds > deadline { return false }
        usleep(20_000)
    }
    return true
}

/// The system clocks with offsets a check can move: a sleep moves wall and
/// monotonic time forward and leaves awake time alone; a clock step moves
/// wall time alone.
private final class SimulatedClocks: @unchecked Sendable {
    private let lock = NSLock()
    private var wallOffset: TimeInterval = 0
    private var monotonicOffset: UInt64 = 0
    /// While set, the next wall-clock read (on the transport's queue) waits here.
    private var hold: DispatchSemaphore?
    let held = DispatchSemaphore(value: 0)

    var clocks: RelayTransportClocks {
        RelayTransportClocks(
            wall: { [self] in
                if let hold = lock.withLock({ () -> DispatchSemaphore? in defer { self.hold = nil }; return self.hold }) {
                    held.signal()
                    hold.wait()
                }
                return Date().addingTimeInterval(lock.withLock { wallOffset })
            },
            monotonic: { [self] in RelayTransportClocks.system.monotonic() &+ lock.withLock { monotonicOffset } },
            awake: { RelayTransportClocks.system.awake() })
    }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock { wallOffset += seconds; monotonicOffset &+= UInt64(seconds * 1_000_000_000) }
    }

    func stepWall(_ seconds: TimeInterval) { lock.withLock { wallOffset += seconds } }

    /// Holds the transport's next tick until the returned semaphore is signalled.
    func holdNextTick() -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        lock.withLock { hold = release }
        return release
    }
}

/// One pane's endpoint with the real shim and no transport: the check plays
/// the broker, so it decides exactly when the heartbeat is fresh, stale or
/// gone, and when a reply appears.
private struct LivenessFixture {
    let directory: URL
    let credentials: RelayCredentials
    let token: String
    let transportDirectory: URL
    let endpoint: URL
    let shim: URL

    init(_ name: String) throws {
        directory = URL(fileURLWithPath: "/tmp/parley-\(name)-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        token = try credentials.token(for: "pane")
        transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
        endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
        shim = try RelayShim.install(in: directory, transportDirectory: transportDirectory).appendingPathComponent("parley")
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    var inbox: URL { endpoint.appendingPathComponent("inbox", isDirectory: true) }
    var heartbeat: URL { endpoint.appendingPathComponent("heartbeat") }

    /// A heartbeat last written `age` seconds ago, as the transport leaves it
    /// when its timer has not run since. Its content names the transport
    /// instance that wrote it, which changes only when a transport restarts.
    func writeHeartbeat(age: TimeInterval, instance: String = "fixture-instance") throws {
        let written = Date().addingTimeInterval(-age)
        try Data(instance.utf8).write(to: heartbeat, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: written], ofItemAtPath: heartbeat.path)
    }

    /// Request directories the shim finished writing (hidden entries are not requests).
    func readyRequests() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ready").path) }
    }

    func reply(to request: URL, status: Int, body: String) throws {
        let response = endpoint.appendingPathComponent("outbox", isDirectory: true).appendingPathComponent(request.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: response, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(String(status).utf8).write(to: response.appendingPathComponent("status"))
        try Data(body.utf8).write(to: response.appendingPathComponent("body"))
        try Data("ready".utf8).write(to: response.appendingPathComponent("ready"))
    }

    func run(_ arguments: [String]) -> ShimRun {
        ShimRun(shim: shim, arguments: arguments, token: token)
    }
}

private final class ShimRun: @unchecked Sendable {
    private let lock = NSLock()
    private var output: CommandOutput?
    private var failure: Error?
    private var elapsed = 0.0
    private let done = DispatchSemaphore(value: 0)

    init(shim: URL, arguments: [String], token: String) {
        let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": token]) { _, supplied in supplied }
        Thread { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var result: CommandOutput?
            var error: Error?
            do {
                result = try ProcessCommandRunner(timeout: 30).run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [shim.path] + arguments, environment: environment, input: nil)
            } catch let caught { error = caught }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            lock.withLock { output = result; failure = error; elapsed = seconds }
            done.signal()
        }.start()
    }

    var finished: Bool { lock.withLock { output != nil || failure != nil } }
    var stderr: String { lock.withLock { output?.stderrText ?? "" } }

    func wait(_ seconds: Double) throws -> (output: CommandOutput, seconds: Double) {
        try livenessExpect(done.wait(timeout: .now() + seconds) == .success, "the shim did not return within \(seconds) s")
        return try lock.withLock {
            guard let output else { throw failure ?? NSError(domain: "TransportLiveness", code: 2) }
            return (output, elapsed)
        }
    }
}

/// Counts writes to one directory, the way the transport's inbox watcher sees them.
private final class DirectoryEvents: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var events = 0

    init(_ directory: URL) throws {
        let descriptor = open(directory.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        try livenessExpect(descriptor >= 0, "could not watch \(directory.path)")
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link], queue: .global())
        source.setEventHandler { [weak self] in self?.lock.withLock { self?.events += 1 } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    var count: Int { lock.withLock { events } }
    func cancel() { source.cancel() }
}

/// Observed on 23 September 2026: a `parley wait` failed with "the Parley
/// relay broker stopped before replying" the second the Mac woke from sleep.
/// The broker was fine. The wall clock had moved on and the transport's timer
/// had not yet run, so the heartbeat read stale once. A stale reading must
/// wake the transport and be waited out, before sending and while waiting.
func checkShimWaitsOutAStaleHeartbeatBeforeSending() throws {
    let fixture = try LivenessFixture("stale-send")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 60)
    let events = try DirectoryEvents(fixture.inbox)
    defer { events.cancel() }
    let run = fixture.run(["whoami"])
    try livenessExpect(livenessEventually(within: 4) { events.count > 0 || run.finished },
                       "the shim did not wake the transport through its inbox while the heartbeat was stale")
    try livenessExpect(!run.finished, "the shim gave up on a stale heartbeat reading at once: \(run.stderr)")
    try livenessExpect(fixture.readyRequests().isEmpty, "the shim sent a request while the heartbeat was stale")
    try fixture.writeHeartbeat(age: 0)
    var request: URL?
    try livenessExpect(livenessEventually(within: 3) { request = fixture.readyRequests().first; return request != nil },
                       "the shim never sent its request once the heartbeat was fresh")
    try fixture.reply(to: request!, status: 200, body: "{\"ok\":true}")
    let (output, _) = try run.wait(10)
    try livenessExpect(output.status == 0 && output.stdoutText == "{\"ok\":true}",
                       "the shim did not complete after the heartbeat recovered: status \(output.status), stderr \(output.stderrText)")
}

func checkShimWaitsOutAStaleHeartbeatWhileWaiting() throws {
    let fixture = try LivenessFixture("stale-wait")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 0)
    let run = fixture.run(["status"])
    var request: URL?
    try livenessExpect(livenessEventually(within: 3) { request = fixture.readyRequests().first; return request != nil },
                       "the shim never sent its request")
    try fixture.writeHeartbeat(age: 60)
    // Past the reading that used to end the wait, well inside the five the shim now allows.
    Thread.sleep(forTimeInterval: 1.8)
    try livenessExpect(!run.finished, "the shim reported the broker stopped on a stale heartbeat while waiting: \(run.stderr)")
    try fixture.writeHeartbeat(age: 0)
    try fixture.reply(to: request!, status: 200, body: "[]")
    let (output, _) = try run.wait(10)
    try livenessExpect(output.status == 0 && output.stdoutText == "[]",
                       "the shim did not collect its reply after the heartbeat recovered: status \(output.status), stderr \(output.stderrText)")
}

/// A container's shim compares a heartbeat the Mac wrote with the Linux VM's
/// clock, and the two can disagree by more than the three seconds a fresh
/// heartbeat is allowed. A heartbeat seen to change is a running transport
/// whatever either clock says.
func checkShimTrustsAnAdvancingHeartbeat() throws {
    let fixture = try LivenessFixture("advancing")
    defer { fixture.cleanup() }
    // Written just now by a clock a minute behind this one.
    try fixture.writeHeartbeat(age: 60)
    let run = fixture.run(["whoami"])
    Thread.sleep(forTimeInterval: 0.6)
    try fixture.writeHeartbeat(age: 59)
    var request: URL?
    try livenessExpect(livenessEventually(within: 3) { request = fixture.readyRequests().first; return request != nil || run.finished },
                       "the shim never sent although the heartbeat advanced")
    try livenessExpect(request != nil, "the shim refused a transport whose heartbeat advanced: \(run.stderr)")
    // It keeps advancing, a minute behind, while the shim waits for the reply.
    for age in stride(from: 58.0, through: 55.0, by: -1) {
        Thread.sleep(forTimeInterval: 1)
        try fixture.writeHeartbeat(age: age)
    }
    try livenessExpect(!run.finished, "the shim gave up on a transport whose heartbeat kept advancing: \(run.stderr)")
    try fixture.reply(to: request!, status: 200, body: "{}")
    let (output, _) = try run.wait(10)
    try livenessExpect(output.status == 0 && output.stdoutText == "{}", "the shim did not complete: status \(output.status), stderr \(output.stderrText)")
}

/// A transport restart (core recovery) discards every request its shims are
/// still waiting on, and a request leaves the filesystem while it is being
/// processed, so the shim cannot see that its request is gone; with the new
/// transport's heartbeat advancing it waited forever (0b58a71e; the
/// container transport check hung this way). The heartbeat names the
/// transport instance, and a shim whose instance changes reports it.
func checkShimReportsATransportRestart() throws {
    let fixture = try LivenessFixture("restart")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 0, instance: "instance-before")
    let run = fixture.run(["status"])
    var request: URL?
    try livenessExpect(livenessEventually(within: 3) { request = fixture.readyRequests().first; return request != nil },
                       "the shim never sent its request")
    // The restart: the request is discarded and a new instance writes heartbeats.
    try FileManager.default.removeItem(at: request!)
    let restartedAt = DispatchTime.now().uptimeNanoseconds
    final class Beating: @unchecked Sendable { let lock = NSLock(); var on = true }
    let beating = Beating()
    Thread {
        while beating.lock.withLock({ beating.on }) {
            try? fixture.writeHeartbeat(age: 0, instance: "instance-after")
            Thread.sleep(forTimeInterval: 0.5)
        }
    }.start()
    defer { beating.lock.withLock { beating.on = false } }
    let (output, _) = try run.wait(12)
    let afterRestart = Double(DispatchTime.now().uptimeNanoseconds - restartedAt) / 1_000_000_000
    try livenessExpect(output.status == 2 && output.stderrText.contains("the Parley relay broker restarted before replying"),
                       "a shim whose request a restart discarded did not report it: status \(output.status), stderr \(output.stderrText)")
    try livenessExpect(afterRestart < 4, "reporting the restart took \(afterRestart) s")
}

/// The real transport names its instance in every heartbeat, the same
/// instance for as long as it runs and a new one after a restart.
func checkTransportHeartbeatNamesItsInstance() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-instance-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: try credentials.token(for: "pane"))
    let heartbeat = endpoint.appendingPathComponent("heartbeat")
    func content() -> String? { try? String(contentsOf: heartbeat, encoding: .utf8) }
    func written() -> Date? { (try? FileManager.default.attributesOfItem(atPath: heartbeat.path))?[.modificationDate] as? Date }
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    let first = content()
    let firstWritten = written() ?? .distantPast
    try livenessExpect(livenessEventually(within: 3) { (written() ?? .distantPast) > firstWritten }, "the heartbeat was not rewritten")
    try livenessExpect(first != nil && content() == first, "one transport wrote two instances: \(String(describing: first)) then \(String(describing: content()))")
    transport.stop()
    try transport.start()
    defer { transport.stop() }
    try livenessExpect(content() != nil && content() != first, "a restarted transport kept its instance: \(String(describing: content()))")
}

/// Tolerance must not turn a real stop into a hang: a heartbeat that stays
/// stale, or goes away because the transport stopped, is still reported,
/// and a missing endpoint is reported at once. "Not running" still means
/// nothing was sent.
func checkShimStillReportsAStoppedBroker() throws {
    let neverFresh = try LivenessFixture("stopped-send")
    defer { neverFresh.cleanup() }
    try neverFresh.writeHeartbeat(age: 60)
    let stopped = try LivenessFixture("stopped-wait")
    defer { stopped.cleanup() }
    try stopped.writeHeartbeat(age: 0)
    // Agy's review of MR !110: after the clock steps back, a dead broker's last
    // heartbeat is dated in the future and read as fresh forever.
    let future = try LivenessFixture("stopped-future")
    defer { future.cleanup() }
    try future.writeHeartbeat(age: -3600)
    let refused = neverFresh.run(["whoami"])
    let waiting = stopped.run(["status"])
    let stranded = future.run(["status"])
    try livenessExpect(livenessEventually(within: 3) { !stopped.readyRequests().isEmpty }, "the waiting shim never sent its request")
    // What RelayFileTransport.stop() does.
    try FileManager.default.removeItem(at: stopped.heartbeat)

    let (refusal, refusalSeconds) = try refused.wait(15)
    try livenessExpect(refusal.status == 2 && refusal.stderrText.contains("the Parley relay broker is not running"),
                       "a heartbeat that never recovered was not reported: status \(refusal.status), stderr \(refusal.stderrText)")
    try livenessExpect(refusalSeconds < 10, "reporting a stopped broker took \(refusalSeconds) s")
    try livenessExpect(neverFresh.readyRequests().isEmpty, "a refused command still sent its request")
    // Nor anything else: the body it staged before the refusal is gone too.
    let refusedLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: neverFresh.inbox.path)) ?? []
    try livenessExpect(refusedLeftovers.isEmpty, "a refused command left entries in its inbox: \(refusedLeftovers)")
    let (abandoned, abandonedSeconds) = try waiting.wait(15)
    try livenessExpect(abandoned.status == 2 && abandoned.stderrText.contains("the Parley relay broker stopped before replying"),
                       "a transport that stopped was not reported: status \(abandoned.status), stderr \(abandoned.stderrText)")
    try livenessExpect(abandonedSeconds < 12, "reporting a transport that stopped took \(abandonedSeconds) s")
    // `post` runs in a pipeline subshell, where the script's EXIT trap never
    // fires (in macOS sh or dash): the shim must clean up itself, or a broker
    // that comes back acts on a request the agent was told had failed.
    try livenessExpect(stopped.readyRequests().isEmpty, "a shim that reported the broker stopped left its request in the inbox")
    let (outlived, outlivedSeconds) = try stranded.wait(15)
    try livenessExpect(outlived.status == 2 && outlived.stderrText.contains("the Parley relay broker stopped before replying"),
                       "a dead broker whose heartbeat is dated in the future was not reported: status \(outlived.status), stderr \(outlived.stderrText)")
    try livenessExpect(outlivedSeconds < 12, "reporting a dead broker with a future heartbeat took \(outlivedSeconds) s")

    let gone = try LivenessFixture("stopped-gone")
    defer { gone.cleanup() }
    try FileManager.default.removeItem(at: gone.endpoint)
    let (missing, missingSeconds) = try gone.run(["whoami"]).wait(10)
    try livenessExpect(missing.status == 2 && missing.stderrText.contains("the Parley relay broker is not running"),
                       "a missing endpoint was not reported: status \(missing.status), stderr \(missing.stderrText)")
    // At once, against the five seconds a stale heartbeat is given.
    try livenessExpect(missingSeconds < 3, "a missing endpoint took \(missingSeconds) s to report")

    // An endpoint pruned while the shim waits for a fresh heartbeat (its pane
    // restarted or closed) is final at once, as it is while waiting for a reply.
    let vanishing = try LivenessFixture("stopped-vanish")
    defer { vanishing.cleanup() }
    try vanishing.writeHeartbeat(age: 60)
    let vanishRun = vanishing.run(["whoami"])
    Thread.sleep(forTimeInterval: 0.6)
    let removedAt = DispatchTime.now().uptimeNanoseconds
    try FileManager.default.removeItem(at: vanishing.endpoint)
    let (vanished, _) = try vanishRun.wait(10)
    let afterRemoval = Double(DispatchTime.now().uptimeNanoseconds - removedAt) / 1_000_000_000
    try livenessExpect(vanished.status == 2 && vanished.stderrText.contains("the Parley relay broker is not running"),
                       "an endpoint removed during the wait was not reported: status \(vanished.status), stderr \(vanished.stderrText)")
    try livenessExpect(afterRemoval < 3, "an endpoint removed during the wait took \(afterRemoval) s to report")
}

/// The transport decided a heartbeat was due by comparing wall-clock times,
/// so a clock stepped backwards stopped every heartbeat until the clock
/// caught up, and every shim then read the broker as stopped.
func checkTransportHeartbeatSurvivesAClockStepBack() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-clockstep-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "pane")
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
    let simulated = SimulatedClocks()
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory,
                                       clocks: simulated.clocks)
    try transport.start()
    defer { transport.stop() }
    let heartbeat = endpoint.appendingPathComponent("heartbeat")
    func written() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: heartbeat.path))?[.modificationDate] as? Date
    }
    try livenessExpect(livenessEventually(within: 3) { written() != nil }, "the transport wrote no heartbeat")
    simulated.stepWall(-3600)
    let stepped = Date()
    try livenessExpect(livenessEventually(within: 4) { (written() ?? .distantPast) > stepped },
                       "the heartbeat stopped after the wall clock stepped back an hour")
}

/// After the Mac wakes, the wall clock has moved on by the whole sleep while
/// every process was frozen. A request a shim was still writing, and a reply
/// a shim had not yet collected, then looked abandoned at the transport's
/// first tick and were deleted from under the shim: the request failed, and
/// a `parley wait` whose reply went polled for it forever.
func checkWakeDoesNotAgeOutRequestsInUse() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-wakeage-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "pane")
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
    let simulated = SimulatedClocks()
    let pane = WorkbenchPane(id: "pane", kind: .claude, customName: "pane", terminalTitle: "", cwd: "/private/pane", currentCommand: "x",
                             isActive: false, workspaceID: "@wake", relayEnabled: true, protocolVersion: AgentProtocol.version,
                             workspaceName: "Wake", inputAvailable: true)
    let broker = RelayBroker(credentials: credentials, panes: { [pane] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory,
                                       clocks: simulated.clocks)
    try transport.start()
    defer { transport.stop() }

    // A shim part-way through writing a request, and a reply nobody has collected yet.
    let request = endpoint.appendingPathComponent("inbox").appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: request, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for (name, value) in [("command", "whoami"), ("token", token), ("target", ""), ("item", ""), ("idempotency-key", "wake-age"), ("body", "")] {
        try Data(value.utf8).write(to: request.appendingPathComponent(name))
    }
    let reply = endpoint.appendingPathComponent("outbox").appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: reply, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for name in ["status", "body", "ready"] { try Data("200".utf8).write(to: reply.appendingPathComponent(name)) }
    Thread.sleep(forTimeInterval: 0.5)

    // The Mac slept for an hour: wall and monotonic time moved, awake time did not.
    simulated.sleep(3600)
    Thread.sleep(forTimeInterval: 2.2)
    try livenessExpect(FileManager.default.fileExists(atPath: request.path), "a request still being written was deleted as abandoned after a wake")
    try livenessExpect(FileManager.default.fileExists(atPath: reply.path), "an uncollected reply was deleted as stale at the first tick after a wake")

    // The shim finishes its request, and it is served.
    try Data("ready".utf8).write(to: request.appendingPathComponent("ready"))
    let served = endpoint.appendingPathComponent("outbox").appendingPathComponent(request.lastPathComponent).appendingPathComponent("ready")
    try livenessExpect(livenessEventually(within: 3) { FileManager.default.fileExists(atPath: served.path) },
                       "the request finished after the wake was never served")
}

/// `stop()` cancelled the timer and removed the heartbeats, but a tick
/// already running could write a heartbeat afterwards, telling every shim
/// that a stopped transport was alive (the container transport check caught
/// it intermittently). A tick is held mid-flight here while `stop()` runs.
func checkStoppedTransportLeavesNoHeartbeat() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-stoprace-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: try credentials.token(for: "pane"))
    let heartbeat = endpoint.appendingPathComponent("heartbeat")
    let simulated = SimulatedClocks()
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory,
                                       clocks: simulated.clocks)
    try transport.start()
    try livenessExpect(FileManager.default.fileExists(atPath: heartbeat.path), "the transport started without a heartbeat")

    let release = simulated.holdNextTick()
    try livenessExpect(simulated.held.wait(timeout: .now() + 3) == .success, "no tick ran")
    simulated.sleep(10) // the held tick will find a heartbeat due
    let stopped = DispatchSemaphore(value: 0)
    Thread { transport.stop(); stopped.signal() }.start()
    Thread.sleep(forTimeInterval: 0.3)
    release.signal()
    try livenessExpect(stopped.wait(timeout: .now() + 5) == .success, "stop() never returned")
    Thread.sleep(forTimeInterval: 0.3)
    try livenessExpect(!FileManager.default.fileExists(atPath: heartbeat.path), "a tick running during stop() wrote a heartbeat after it")
}

/// Every start or restart rotates the pane's capability and prepares a new
/// endpoint, and every stop or close forgets it, but only `start()` removed
/// endpoints. A long session kept every retired one, heartbeated and watched,
/// and past 256 the listing began dropping live panes.
func checkRetiredEndpointsArePruned() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-prune-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentialsFile = directory.appendingPathComponent("relay-tokens.json")
    let credentials = try RelayCredentials(file: credentialsFile)
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: try credentials.token(for: "pane"))
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { transport.stop() }
    func endpoints() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: transportDirectory.path)) ?? []).filter { $0.count == 48 })
    }

    // Five restarts of one pane, and a second pane that is then closed.
    var current = ""
    for _ in 0..<5 {
        current = try credentials.rotate("pane")
        _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: current)
    }
    let closed = try credentials.token(for: "closed")
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: closed)
    try credentials.forget("closed")
    try livenessExpect(livenessEventually(within: 4) { endpoints() == [current] },
                       "retired endpoints were kept: \(endpoints().count) endpoints for one live pane")
    let live = transportDirectory.appendingPathComponent(current).appendingPathComponent("heartbeat")
    try livenessExpect(livenessEventually(within: 3) { FileManager.default.fileExists(atPath: live.path) }, "the live endpoint lost its heartbeat")

    // Credentials that cannot be read prune nothing: unknown is not retired.
    let unknown = String(repeating: "c", count: 48)
    _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: unknown)
    try Data("not json".utf8).write(to: credentialsFile)
    Thread.sleep(forTimeInterval: 2.2)
    try livenessExpect(endpoints() == [current, unknown], "endpoints were pruned while the credentials could not be read: \(endpoints())")
}

/// Review of 22 September 2026 (db7c3b52): the shim created its request
/// folder before reading stdin, so a producer slower than the transport's
/// abandonment age lost its request: the transport removed the folder as a
/// writer that had crashed, and the shim then failed writing into it.
func checkSlowProducerKeepsItsRequest() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-slowbody-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "source")
    _ = try credentials.token(for: "target")
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/\(id)", currentCommand: kind.rawValue,
                      isActive: false, workspaceID: "@slow", relayEnabled: true, protocolVersion: AgentProtocol.version,
                      workspaceName: "Slow", inputAvailable: true)
    }
    final class Delivered: @unchecked Sendable { let lock = NSLock(); var text: String? }
    let delivered = Delivered()
    let broker = RelayBroker(credentials: credentials, panes: { [pane("source", .claude), pane("target", .codex)] },
                             paste: { _, _ in }, submit: { _, text in delivered.lock.withLock { delivered.text = text } })
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    for token in try credentials.allTokens() {
        _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: token)
    }
    let shim = try RelayShim.install(in: directory, transportDirectory: transportDirectory).appendingPathComponent("parley")
    // Abandonment after half a second of awake time, so a two-second producer is "slow".
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory, abandonedRequestAge: 0.5)
    try transport.start()
    defer { transport.stop() }

    let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": sourceToken]) { _, supplied in supplied }
    let output = try ProcessCommandRunner(timeout: 20).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "{ /bin/sleep 2; /usr/bin/printf 'slow report'; } | /bin/sh \"$0\" relay target", shim.path],
        environment: environment, input: nil)
    try livenessExpect(output.status == 0, "a slow producer's relay failed: status \(output.status), stderr \(output.stderrText)")
    try livenessExpect(delivered.lock.withLock { delivered.text }?.hasSuffix("slow report") == true,
                       "the relay did not deliver the slow producer's text: \(String(describing: delivered.lock.withLock { delivered.text }))")
    let inbox = transportDirectory.appendingPathComponent(sourceToken).appendingPathComponent("inbox")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
    try livenessExpect(leftovers.isEmpty, "the relay left entries in the inbox: \(leftovers)")
}

/// Runs the fixture's shim with `producer` piped into it.
private func runShim(_ fixture: LivenessFixture, _ arguments: [String], producer: String, timeout: TimeInterval = 20) throws -> (output: CommandOutput, seconds: Double) {
    let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": fixture.token]) { _, supplied in supplied }
    let started = DispatchTime.now().uptimeNanoseconds
    let output = try ProcessCommandRunner(timeout: timeout).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "\(producer) | /bin/sh \"$0\" \"$@\"", fixture.shim.path] + arguments,
        environment: environment, input: nil)
    return (output, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000)
}

/// The fresh-context review of the staged body: reading stdin first meant a
/// shim with no running broker read an endless producer forever. Liveness is
/// checked before stdin is read, and again after.
func checkShimReadsStdinOnlyForARunningBroker() throws {
    let fixture = try LivenessFixture("endless")
    defer { fixture.cleanup() }
    // The endpoint remains after Parley quits; the heartbeat does not.
    let (output, seconds) = try runShim(fixture, ["relay", "target"], producer: "/usr/bin/yes")
    try livenessExpect(output.status == 2 && output.stderrText.contains("the Parley relay broker is not running"),
                       "an endless producer with no broker was not refused: status \(output.status), stderr \(output.stderrText.prefix(300))")
    try livenessExpect(seconds < 12, "refusing took \(seconds) s")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path)) ?? []
    try livenessExpect(leftovers.isEmpty, "the refusal left entries in the inbox: \(leftovers)")
}

/// A heartbeat whose instance cannot be read gives no baseline to notice a
/// restart by; sending then could hang the way 0b58a71e did.
func checkShimSendsNothingWithoutAnInstance() throws {
    let fixture = try LivenessFixture("noinstance")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 0, instance: "")
    let (output, _) = try fixture.run(["whoami"]).wait(15)
    try livenessExpect(output.status == 2 && output.stderrText.contains("the Parley relay broker is not running"),
                       "a heartbeat with no instance was taken as a running broker: status \(output.status), stderr \(output.stderrText)")
    try livenessExpect(fixture.readyRequests().isEmpty, "a request was sent with no instance to watch")
}

/// A request still in the inbox when the new instance appears was written
/// after that transport's start discarded the old ones, so it will be
/// processed: the shim keeps waiting rather than reporting a restart.
func checkShimKeepsWaitingForARequestTheRestartKept() throws {
    let fixture = try LivenessFixture("restart-kept")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 0, instance: "instance-before")
    let run = fixture.run(["status"])
    var request: URL?
    try livenessExpect(livenessEventually(within: 3) { request = fixture.readyRequests().first; return request != nil },
                       "the shim never sent its request")
    final class Beating: @unchecked Sendable { let lock = NSLock(); var on = true }
    let beating = Beating()
    Thread {
        while beating.lock.withLock({ beating.on }) {
            try? fixture.writeHeartbeat(age: 0, instance: "instance-after")
            Thread.sleep(forTimeInterval: 0.5)
        }
    }.start()
    defer { beating.lock.withLock { beating.on = false } }
    Thread.sleep(forTimeInterval: 2.5)
    try livenessExpect(!run.finished, "the shim reported a restart although its request was still waiting to be processed: \(run.stderr)")
    try fixture.reply(to: request!, status: 200, body: "[]")
    let (output, _) = try run.wait(10)
    try livenessExpect(output.status == 0 && output.stdoutText == "[]", "the shim did not collect its reply: status \(output.status), stderr \(output.stderrText)")
}

/// A shim killed while its producer runs, or its wake entry, leaves hidden
/// scratch in its inbox, which the tick never lists. It is removed once it
/// has not changed for the reply age in awake time; a body still growing is not.
func checkTransportSweepsDeadShimScratch() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-scratch-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: try credentials.token(for: "pane"))
    let inbox = endpoint.appendingPathComponent("inbox")
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory, staleResponseAge: 1)
    try transport.start()
    defer { transport.stop() }
    let dead = inbox.appendingPathComponent(".body-\(UUID().uuidString.lowercased())")
    let growing = inbox.appendingPathComponent(".body-\(UUID().uuidString.lowercased())")
    let wake = inbox.appendingPathComponent(".wake-99999")
    try Data("abandoned".utf8).write(to: dead)
    try Data("a".utf8).write(to: growing)
    try FileManager.default.createDirectory(at: wake, withIntermediateDirectories: false)
    let handle = try FileHandle(forWritingTo: growing)
    defer { try? handle.close() }
    var gone = false
    let deadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        try handle.seekToEnd(); try handle.write(contentsOf: Data("a".utf8))
        if !FileManager.default.fileExists(atPath: dead.path) && !FileManager.default.fileExists(atPath: wake.path) { gone = true; break }
        Thread.sleep(forTimeInterval: 0.3)
    }
    try livenessExpect(gone, "a dead shim's staged body or wake entry was never removed")
    try livenessExpect(FileManager.default.fileExists(atPath: growing.path), "a body still being written was removed")
}

/// Core recovery restarts the transport while shims wait. A reply the old
/// transport finished belongs to a live shim, which collects it; only
/// half-finished work is discarded.
func checkRestartKeepsFinishedReplies() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-keepreply-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportDirectory, paneToken: try credentials.token(for: "pane"))
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    transport.stop()
    let outbox = endpoint.appendingPathComponent("outbox")
    func reply(_ files: [String]) throws -> URL {
        let folder = outbox.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in files { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }
    let finished = try reply(["status", "body", "ready"])
    let unfinished = try reply(["accepted", "handoff-id"])
    try transport.start()
    defer { transport.stop() }
    try livenessExpect(FileManager.default.fileExists(atPath: finished.path), "a restart discarded a finished reply a shim may still collect")
    try livenessExpect(!FileManager.default.fileExists(atPath: unfinished.path), "a restart kept an unfinished reply")
}

/// Agy's review of MR !112: a shim interrupted (Ctrl-C, a tool timeout's
/// SIGTERM) while its producer was still writing left the staged body for
/// the ten-minute scratch sweep. The pipeline runs in a process group of its
/// own here, so the signal reaches it and nothing else.
func checkInterruptedShimRemovesItsStagedBody() throws {
    let fixture = try LivenessFixture("interrupted")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 0)
    let pidFile = fixture.directory.appendingPathComponent("pipeline.pid")
    let environment = ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": fixture.token]) { _, supplied in supplied }
    final class Finished: @unchecked Sendable { let lock = NSLock(); var done = false }
    let finished = Finished()
    Thread {
        // `set -m` gives the background pipeline its own process group.
        _ = try? ProcessCommandRunner(timeout: 30).run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            // `$!` is the pipeline's last process; its group is led by the first.
            arguments: ["-c", "set -m; { /usr/bin/printf 'partial'; /bin/sleep 20; } | /bin/sh \"$0\" relay target & /bin/ps -o pgid= -p $! > \"$1\"; wait",
                        fixture.shim.path, pidFile.path],
            environment: environment, input: nil)
        finished.lock.withLock { finished.done = true }
    }.start()
    func staged() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path)) ?? []).filter { $0.hasPrefix(".body-") }
    }
    try livenessExpect(livenessEventually(within: 5) { !staged().isEmpty && FileManager.default.fileExists(atPath: pidFile.path) },
                       "the shim never staged its body")
    var leader = ""
    _ = livenessEventually(within: 2) {
        leader = ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !leader.isEmpty
    }
    guard let group = Int32(leader), group > 1, group != getpgrp() else {
        throw NSError(domain: "TransportLiveness", code: 3, userInfo: [NSLocalizedDescriptionKey: "no separate process group for the pipeline: \(leader)"])
    }
    defer {
        kill(-group, SIGKILL)
        _ = livenessEventually(within: 5) { finished.lock.withLock { finished.done } }
    }
    kill(-group, SIGTERM)
    try livenessExpect(livenessEventually(within: 3) { staged().isEmpty }, "an interrupted shim left its staged body in the inbox: \(staged())")
    try livenessExpect(fixture.readyRequests().isEmpty, "an interrupted shim sent its request")
}

/// The reply the old transport finished is still in the outbox when the new
/// instance appears; the shim collects it, because it looks for its reply
/// before it compares instances (Agy's review of MR !112 asked for the real
/// shim here, not only the kept folder).
func checkShimCollectsAReplyFinishedBeforeARestart() throws {
    let fixture = try LivenessFixture("reply-restart")
    defer { fixture.cleanup() }
    try fixture.writeHeartbeat(age: 0, instance: "instance-before")
    let run = fixture.run(["status"])
    var request: URL?
    try livenessExpect(livenessEventually(within: 3) { request = fixture.readyRequests().first; return request != nil },
                       "the shim never sent its request")
    // The old worker finished; then the restart: request gone, new instance.
    try fixture.reply(to: request!, status: 200, body: "{\"finished\":true}")
    try FileManager.default.removeItem(at: request!)
    try fixture.writeHeartbeat(age: 0, instance: "instance-after")
    let (output, _) = try run.wait(10)
    try livenessExpect(output.status == 0 && output.stdoutText == "{\"finished\":true}",
                       "the shim did not collect the reply finished before the restart: status \(output.status), stderr \(output.stderrText)")
}

@MainActor let transportLivenessChecks: [(String, () throws -> Void)] = [
    ("an interrupted shim removes its staged body", checkInterruptedShimRemovesItsStagedBody),
    ("the shim collects a reply finished before a restart", checkShimCollectsAReplyFinishedBeforeARestart),
    ("the shim reads stdin only for a running broker", checkShimReadsStdinOnlyForARunningBroker),
    ("the shim sends nothing without an instance to watch", checkShimSendsNothingWithoutAnInstance),
    ("the shim keeps waiting for a request the restart kept", checkShimKeepsWaitingForARequestTheRestartKept),
    ("the transport sweeps a dead shim's scratch", checkTransportSweepsDeadShimScratch),
    ("a transport restart keeps finished replies", checkRestartKeepsFinishedReplies),
    ("a slow producer keeps its request", checkSlowProducerKeepsItsRequest),
    ("the shim waits out a stale heartbeat before sending", checkShimWaitsOutAStaleHeartbeatBeforeSending),
    ("the shim waits out a stale heartbeat while waiting for a reply", checkShimWaitsOutAStaleHeartbeatWhileWaiting),
    ("the shim still reports a stopped broker", checkShimStillReportsAStoppedBroker),
    ("the shim trusts a heartbeat it sees advancing whatever the clocks say", checkShimTrustsAnAdvancingHeartbeat),
    ("the shim reports a transport restart instead of waiting forever", checkShimReportsATransportRestart),
    ("the transport heartbeat names its instance", checkTransportHeartbeatNamesItsInstance),
    ("the transport heartbeat survives a wall clock step back", checkTransportHeartbeatSurvivesAClockStepBack),
    ("a wake does not age out requests and replies still in use", checkWakeDoesNotAgeOutRequestsInUse),
    ("a stopped transport leaves no heartbeat", checkStoppedTransportLeavesNoHeartbeat),
    ("retired transport endpoints are pruned", checkRetiredEndpointsArePruned),
]
