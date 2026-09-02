import Darwin
import Foundation
import ParleyCore

private enum PaneAnchorCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func anchorExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PaneAnchorCheckFailure.failed(message) }
}

private func anchorRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw PaneAnchorCheckFailure.failed(message) }
    return value
}

private func anchorDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-pane-anchor-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}

/// A live same-user child of this check process, started with an explicit
/// environment and no inherited variables, so the marker is the only claim.
private final class LiveChild {
    let pid: pid_t

    init(arguments: [String], environment: [String: String]) throws {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var childEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        childEnvironment.append(nil)
        defer {
            for argument in argv.dropLast() where argument != nil { free(argument) }
            for variable in childEnvironment.dropLast() where variable != nil { free(variable) }
        }
        // Each fixture child starts its own session with no controlling TTY, so
        // attribution rests on the marker and parent chain alone wherever the
        // checks run, instead of on whatever terminal launched them.
        var attributes = posix_spawnattr_t(bitPattern: 0)
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            throw PaneAnchorCheckFailure.failed("could not prepare a detached fixture session")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var child = pid_t()
        let status = arguments[0].withCString { path in
            argv.withUnsafeMutableBufferPointer { buffer in
                childEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(&child, path, nil, &attributes, buffer.baseAddress!, environmentBuffer.baseAddress!)
                }
            }
        }
        guard status == 0 else { throw PaneAnchorCheckFailure.failed("could not spawn a live child process (\(status))") }
        pid = child
    }

    /// This check binary sleeping: a non-platform executable whose environment
    /// the kernel shows to other same-user processes.
    static func readableRoot(marker: String?) throws -> LiveChild {
        var environment = ["PARLEY_ANCHOR_SLEEP_CHILD": "1", "PATH": "/usr/bin:/bin"]
        if let marker { environment["PARLEY_PANE_ID"] = marker }
        return try LiveChild(arguments: [CommandLine.arguments[0]], environment: environment)
    }

    /// `/bin/sh` staying alive as the root with this check binary sleeping
    /// beneath it: the platform shell hides its environment, the child does not.
    static func hiddenRoot(marker: String) throws -> LiveChild {
        try LiveChild(
            arguments: ["/bin/sh", "-c", "\(shellQuoted(CommandLine.arguments[0])); :"],
            environment: ["PARLEY_ANCHOR_SLEEP_CHILD": "1", "PATH": "/usr/bin:/bin", "PARLEY_PANE_ID": marker]
        )
    }

    /// A platform binary with no marker at all.
    static func unmarkedPlatformRoot() throws -> LiveChild {
        try LiveChild(arguments: ["/bin/sleep", "120"], environment: ["PATH": "/usr/bin:/bin"])
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    deinit {
        Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

private func rawProcess(
    pid: Int32,
    parent: Int32,
    tty: UInt64?,
    name: String = "zsh",
    startedAt: Date = Date(timeIntervalSince1970: 100)
) -> TaskManagerRawProcess {
    TaskManagerRawProcess(
        pid: pid, parentPID: parent, processGroupID: pid, ttyDevice: tty,
        name: name, residentBytes: 1, totalCPUTimeNanoseconds: 0, startedAt: startedAt
    )
}

private func paneDescriptor(
    _ id: String,
    started: Bool = true,
    foregroundPID: Int32? = nil,
    ttyDevice: UInt64? = nil
) -> TaskManagerPaneDescriptor {
    TaskManagerPaneDescriptor(
        paneID: id, workspaceID: "@anchor", workspaceName: "Anchor",
        paneName: id, kind: .shell, workingDirectory: "/private/anchor",
        isSelected: false, isStarted: started, foregroundPID: foregroundPID,
        ttyName: nil, ttyDevice: ttyDevice
    )
}

private func fakeLsof(in directory: URL, name: String, body: String) throws -> URL {
    let file = directory.appendingPathComponent(name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}

private func paneSnapshot(_ id: String, in snapshot: TaskManagerSnapshot) -> TaskManagerPaneSnapshot? {
    snapshot.workspaces.flatMap(\.panes).first(where: { $0.paneID == id })
}

/// A freshly forked fixture child is still a copy of its platform parent until
/// it has exec'd, so the marker becomes readable a few milliseconds after
/// spawn. Resample until the named panes are anchored or the timeout passes.
private func sampleUntilAnchored(
    _ sampler: TaskManagerSampler,
    applicationPID: Int32,
    descriptors: [TaskManagerPaneDescriptor],
    expecting paneIDs: Set<String>,
    timeout: TimeInterval = 5
) -> TaskManagerSnapshot {
    let deadline = Date().addingTimeInterval(timeout)
    var sample = sampler.sample(applicationPID: applicationPID, paneDescriptors: descriptors)
    while Date() < deadline {
        let anchored = Set(sample.workspaces.flatMap(\.panes).filter { $0.anchorSource == .paneMarker }.map(\.paneID))
        if paneIDs.isSubset(of: anchored) { return sample }
        Thread.sleep(forTimeInterval: 0.05)
        sample = sampler.sample(applicationPID: applicationPID, paneDescriptors: descriptors)
    }
    return sample
}

func checkPaneRootResolverOwnsOnlyMarkedLaunchTrees() throws {
    let app: Int32 = 500
    let login: Int32 = 520 // privileged intermediate: absent from the visible list
    let raw = [
        rawProcess(pid: app, parent: 1, tty: nil, name: "Parley"),
        rawProcess(pid: 501, parent: app, tty: 11),          // readable marker %1
        rawProcess(pid: 502, parent: app, tty: 12),          // %2, first claimant
        rawProcess(pid: 503, parent: app, tty: 13),          // %2, second claimant: ambiguous
        rawProcess(pid: 504, parent: app, tty: 14),          // no marker, no children
        rawProcess(pid: 505, parent: 501, tty: 11),          // child of a readable root: never consulted
        rawProcess(pid: 506, parent: 1, tty: 15),            // outside the application tree
        rawProcess(pid: 507, parent: app, tty: 16),          // marker for a pane that does not exist
        rawProcess(pid: 508, parent: app, tty: 17),          // hidden environment (platform shell)
        rawProcess(pid: 509, parent: 508, tty: 17, name: "uv"), // its child carries %7
        rawProcess(pid: 521, parent: login, tty: 18, name: "claude"), // beneath the invisible login
        rawProcess(pid: 530, parent: 999, tty: 19),          // beneath an unknown invisible parent
        rawProcess(pid: 540, parent: app, tty: 20),          // hidden; descendant claims %8
        rawProcess(pid: 541, parent: app, tty: 21),          // hidden; descendant also claims %8
        rawProcess(pid: 542, parent: 540, tty: 20, name: "python"),
        rawProcess(pid: 543, parent: 541, tty: 21, name: "python"),
    ]
    let markers: [Int32: String] = [
        501: "%1", 502: "%2", 503: "%2", 505: "%3", 506: "%4", 507: "%ghost",
        509: "%7", 521: "%9", 530: "%10", 542: "%8", 543: "%8",
    ]
    var asked: [Int32] = []
    var parentQueries: [Int32] = []
    let roots = PaneProcessAnchorProjection.roots(
        applicationPID: app,
        paneIDs: ["%1", "%2", "%3", "%4", "%7", "%8", "%9", "%10"],
        rawProcesses: raw,
        markerValue: { pid in
            asked.append(pid)
            return markers[pid]
        },
        parentPID: { pid in
            parentQueries.append(pid)
            return pid == login ? app : (pid == 999 ? 1 : nil)
        }
    )
    try anchorExpect(roots["%1"] == PaneProcessRoot(paneID: "%1", pid: 501, ttyDevice: 11), "a marked app-owned launch root was not attributed to its pane")
    try anchorExpect(roots["%2"] == nil, "an ambiguous pane marker was attributed instead of rejected")
    try anchorExpect(roots["%3"] == nil, "a descendant of a readable root re-anchored a different pane")
    try anchorExpect(roots["%4"] == nil, "a process outside the application tree anchored a pane")
    try anchorExpect(roots["%ghost"] == nil, "a marker for an unknown pane produced a root")
    try anchorExpect(roots["%7"] == PaneProcessRoot(paneID: "%7", pid: 508, ttyDevice: 17), "a hidden-environment root was not anchored through its marked descendant")
    try anchorExpect(roots["%9"] == PaneProcessRoot(paneID: "%9", pid: 521, ttyDevice: 18), "a pane beneath the privileged login intermediate was not anchored")
    try anchorExpect(roots["%10"] == nil, "a process beneath an unrelated invisible parent anchored a pane")
    try anchorExpect(roots["%8"] == nil, "two hidden roots claiming one pane through descendants were not rejected as ambiguous")
    try anchorExpect(!asked.contains(505) && !asked.contains(506) && !asked.contains(530), "the resolver read environments beyond the application's launch trees: \(asked.sorted())")
    try anchorExpect(Set(parentQueries) == Set([login, 999]), "the resolver asked the kernel about parents of visible processes: \(parentQueries.sorted())")

    let descriptors = [
        paneDescriptor("%1"),
        paneDescriptor("%2"),
        paneDescriptor("%5", foregroundPID: 900, ttyDevice: 90),
        paneDescriptor("%6", started: false),
    ]
    let anchored = PaneProcessAnchorProjection.anchored(
        descriptors,
        roots: [
            "%1": PaneProcessRoot(paneID: "%1", pid: 501, ttyDevice: 11),
            "%5": PaneProcessRoot(paneID: "%5", pid: 950, ttyDevice: 95),
            "%6": PaneProcessRoot(paneID: "%6", pid: 960, ttyDevice: 96),
        ]
    )
    let first = try anchorRequire(anchored.first(where: { $0.paneID == "%1" }), "anchored descriptor disappeared")
    try anchorExpect(first.foregroundPID == 501 && first.ttyDevice == 11 && first.anchorSource == .paneMarker, "the marker root did not anchor an unanchored pane")
    let second = try anchorRequire(anchored.first(where: { $0.paneID == "%2" }), "ambiguous descriptor disappeared")
    try anchorExpect(second.foregroundPID == nil && second.ttyDevice == nil && second.anchorSource == .unavailable, "a pane without a root did not stay honestly unavailable")
    let ghostty = try anchorRequire(anchored.first(where: { $0.paneID == "%5" }), "Ghostty-anchored descriptor disappeared")
    try anchorExpect(ghostty.foregroundPID == 900 && ghostty.ttyDevice == 90 && ghostty.anchorSource == .ghostty, "a marker root overrode Ghostty's own foreground PID or TTY")
    let stopped = try anchorRequire(anchored.first(where: { $0.paneID == "%6" }), "stopped descriptor disappeared")
    try anchorExpect(stopped.foregroundPID == nil && stopped.ttyDevice == nil, "a stopped pane was anchored to a process")

    // Live kernel reads: a readable root, a platform root that hides its
    // environment, an unmarked platform root and one ambiguous pane.
    let readable = try LiveChild.readableRoot(marker: "%live")
    let hidden = try LiveChild.hiddenRoot(marker: "%shell")
    let unmarked = try LiveChild.unmarkedPlatformRoot()
    let duplicateA = try LiveChild.readableRoot(marker: "%dup")
    let duplicateB = try LiveChild.readableRoot(marker: "%dup")
    let me = ProcessInfo.processInfo.processIdentifier
    try anchorExpect(ProcessEnvironmentMarker.value("PARLEY_PANE_ID", forProcess: readable.pid) == "%live", "the marker was not read from a live same-user child")
    try anchorExpect(ProcessEnvironmentMarker.value("PATH", forProcess: readable.pid) == "/usr/bin:/bin", "a second key could not be read; parsing skipped the environment block")
    try anchorExpect(ProcessEnvironmentMarker.value("PARLEY_PANE_ID", forProcess: unmarked.pid) == nil, "an unmarked child reported a marker")
    // Whether /bin/sh exposes its environment varies by macOS release; the
    // shell-tree pane must anchor either way (directly or through its child).
    let shellExposesEnvironment = ProcessEnvironmentMarker.value("PARLEY_PANE_ID", forProcess: hidden.pid) == "%shell"
    _ = shellExposesEnvironment
    try anchorExpect(ProcessKernelFacts.isAlive(readable.pid), "a running child was reported dead")
    try anchorExpect(!ProcessKernelFacts.isAlive(2_147_000_000), "an impossible pid was reported alive")
    try anchorExpect(ProcessKernelFacts.parentPID(ofProcess: readable.pid) == me, "kern.proc.pid did not report this process as the child's parent")
    try anchorExpect(ProcessKernelFacts.parentPID(ofProcess: me) == getppid(), "kern.proc.pid disagreed with getppid for this process")

    let sample = sampleUntilAnchored(
        TaskManagerSampler(),
        applicationPID: me,
        descriptors: [paneDescriptor("%live"), paneDescriptor("%shell"), paneDescriptor("%dup"), paneDescriptor("%absent")],
        expecting: ["%live", "%shell"]
    )
    let livePane = try anchorRequire(paneSnapshot("%live", in: sample), "the readable pane disappeared from Task Manager")
    try anchorExpect(livePane.anchorSource == .paneMarker && livePane.processes.contains(where: { $0.pid == readable.pid }), "a readable marked root was not attributed by the live resolver")
    let shellPane = try anchorRequire(paneSnapshot("%shell", in: sample), "the hidden-root pane disappeared from Task Manager")
    try anchorExpect(shellPane.anchorSource == .paneMarker, "a shell-tree pane was not anchored, neither from the shell's own environment nor through its marked child")
    try anchorExpect(shellPane.processes.contains(where: { $0.pid == hidden.pid }), "the platform shell root itself was not attributed to its pane")
    try anchorExpect(shellPane.processes.contains(where: { $0.parentPID == hidden.pid }), "the marked child beneath the platform shell was not attributed to its pane")
    let duplicatePane = try anchorRequire(paneSnapshot("%dup", in: sample), "the ambiguous pane disappeared from Task Manager")
    try anchorExpect(duplicatePane.anchorSource == .unavailable && duplicatePane.processes.isEmpty, "an ambiguous live marker was attributed instead of left unavailable")
    let absentPane = try anchorRequire(paneSnapshot("%absent", in: sample), "the unanchored pane disappeared from Task Manager")
    try anchorExpect(absentPane.anchorSource == .unavailable && absentPane.processes.isEmpty, "a pane with no marked process invented attribution")
    try anchorExpect(!livePane.processes.contains(where: { $0.pid == unmarked.pid }), "an unmarked platform root was attributed to a marked pane")
    try anchorExpect(!shellPane.processes.contains(where: { $0.pid == readable.pid }), "one pane's root was attributed to another pane")
    _ = duplicateA
    _ = duplicateB
}

func checkPaneAnchorFallbackFeedsTaskManagerAndPorts() throws {
    let directory = try anchorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = ProcessInfo.processInfo.processIdentifier
    let child = try LiveChild.readableRoot(marker: "%fallback")
    let descriptors = [paneDescriptor("%fallback"), paneDescriptor("%other")]

    let taskManager = sampleUntilAnchored(
        TaskManagerSampler(),
        applicationPID: app,
        descriptors: descriptors,
        expecting: ["%fallback"]
    )
    let pane = try anchorRequire(paneSnapshot("%fallback", in: taskManager), "Task Manager lost the marked pane")
    try anchorExpect(pane.processes.contains(where: { $0.pid == child.pid }), "Task Manager did not attribute the marked child through the fallback anchor")
    try anchorExpect(pane.anchorSource == .paneMarker, "Task Manager did not report the fallback anchor source")
    let other = try anchorRequire(paneSnapshot("%other", in: taskManager), "Task Manager lost the unanchored pane")
    try anchorExpect(other.processes.isEmpty && other.anchorSource == .unavailable, "an unanchored pane invented processes or an anchor")

    let lsof = try fakeLsof(in: directory, name: "lsof-status1", body: "printf 'p\(child.pid)\\nf3\\nn*:8123\\n'\nexit 1")
    let resolver = PaneListeningPortResolver(executable: lsof, timeout: 2)
    let snapshot = try anchorRequire(
        resolver.sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: Date(timeIntervalSince1970: 300)),
        "port sampling reported failure for a completed lsof run"
    )
    try anchorExpect(snapshot.portsByPaneID["%fallback"] == [8123], "the listener was not attributed to the marker-anchored pane: \(snapshot.portsByPaneID)")
    try anchorExpect(snapshot.portsByPaneID["%other"] == [], "an unanchored pane received a listener")
}

func checkListeningPortSamplingIsHonestAboutFailures() throws {
    let directory = try anchorDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = ProcessInfo.processInfo.processIdentifier
    let child = try LiveChild.unmarkedPlatformRoot()
    let descriptors = [paneDescriptor("%ports", foregroundPID: child.pid, ttyDevice: nil)]
    let sampledAt = Date(timeIntervalSince1970: 400)

    let statusOne = try fakeLsof(in: directory, name: "lsof-one", body: "printf 'p\(child.pid)\\nf3\\nn[::1]:8123\\nn127.0.0.1:8123\\n'\nexit 1")
    let fromStatusOne = try anchorRequire(
        PaneListeningPortResolver(executable: statusOne, timeout: 2).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt),
        "lsof exit status 1 with usable output was treated as a failed inspection"
    )
    try anchorExpect(fromStatusOne.portsByPaneID["%ports"] == [8123], "usable lsof output was discarded because a listed pid had vanished")

    let statusOneEmpty = try fakeLsof(in: directory, name: "lsof-one-empty", body: "exit 1")
    try anchorExpect(
        PaneListeningPortResolver(executable: statusOneEmpty, timeout: 2).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt) == nil,
        "lsof exit status 1 with no machine output was accepted as an empty sample; a permission or general failure could clear a valid prior snapshot"
    )
    let statusOneNoise = try fakeLsof(in: directory, name: "lsof-one-noise", body: "printf 'lsof: WARNING: something\\n'\nexit 1")
    try anchorExpect(
        PaneListeningPortResolver(executable: statusOneNoise, timeout: 2).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt) == nil,
        "lsof exit status 1 without a process record was accepted as an empty sample"
    )

    let statusZeroEmpty = try fakeLsof(in: directory, name: "lsof-empty", body: "exit 0")
    let empty = try anchorRequire(
        PaneListeningPortResolver(executable: statusZeroEmpty, timeout: 2).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt),
        "an empty successful lsof run was reported as a failure"
    )
    try anchorExpect(empty.portsByPaneID["%ports"] == [] && empty.sampledAt == sampledAt, "an empty lsof run did not yield a fresh empty snapshot")

    let statusTwo = try fakeLsof(in: directory, name: "lsof-two", body: "printf 'p\(child.pid)\\nn*:9\\n'\nexit 2")
    try anchorExpect(
        PaneListeningPortResolver(executable: statusTwo, timeout: 2).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt) == nil,
        "an lsof error status other than 1 was accepted as a sample"
    )

    let slow = try fakeLsof(in: directory, name: "lsof-slow", body: "sleep 5\nprintf 'p\(child.pid)\\nn*:8123\\n'")
    try anchorExpect(
        PaneListeningPortResolver(executable: slow, timeout: 0.3).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt) == nil,
        "a timed-out inspection produced a snapshot instead of nil"
    )
    try anchorExpect(
        PaneListeningPortResolver(executable: directory.appendingPathComponent("missing-lsof"), timeout: 1).sample(applicationPID: app, paneDescriptors: descriptors, sampledAt: sampledAt) == nil,
        "a missing lsof executable produced a snapshot instead of nil"
    )

    let oldest = Date(timeIntervalSince1970: 1_000)
    let owned: [String: [TaskManagerRawProcess]] = [
        "%bound": (1...300).map { index in
            rawProcess(pid: Int32(1_000 + index), parent: 999, tty: 5, name: "p\(index)", startedAt: oldest.addingTimeInterval(TimeInterval(index)))
        },
    ]
    let inspected = PaneListeningPortProjection.inspectedProcessIDs(ownedProcesses: owned)
    try anchorExpect(inspected.count == PaneListeningPortProjection.maximumInspectedProcesses, "the inspected process bound drifted")
    try anchorExpect(inspected.first == 1_300, "the bounded process list did not start with the newest process")
    try anchorExpect(inspected.contains(1_300) && !inspected.contains(1_001), "the bound kept the oldest processes and dropped the newest")
    let arguments = try anchorRequire(PaneListeningPortProjection.commandArguments(ownedProcesses: owned), "bounded processes produced no lsof arguments")
    try anchorExpect(arguments[3].hasPrefix("1300,"), "lsof was not asked about the newest process first")
    let newest = PaneListeningPortProjection.snapshot(ownedProcesses: owned, lsofOutput: "p1300\nn*:5173\np1001\nn*:3000\n", sampledAt: sampledAt)
    try anchorExpect(newest.portsByPaneID["%bound"] == [5173], "a listener on the newest process was lost to the inspection bound")
}

func checkListeningPortRefreshStateRetainsAndForces() throws {
    var state = PaneListeningPortRefreshState()
    let start = Date(timeIntervalSince1970: 500)
    try anchorExpect(state.shouldAttempt(now: start, inputSignature: ["a"], forced: false), "a fresh state refused its first inspection")
    state.beginAttempt(at: start, inputSignature: ["a"])
    try anchorExpect(!state.shouldAttempt(now: start.addingTimeInterval(5), inputSignature: ["a"], forced: false), "an in-flight inspection was started twice")
    let produced = PaneListeningPortSnapshot(sampledAt: start, portsByPaneID: ["%1": [8123]])
    state.finishAttempt(with: produced)
    try anchorExpect(state.snapshot == produced, "a produced snapshot was not published")
    try anchorExpect(!state.shouldAttempt(now: start.addingTimeInterval(5), inputSignature: ["a"], forced: false), "the throttle was ignored inside the interval")
    try anchorExpect(state.shouldAttempt(now: start.addingTimeInterval(5), inputSignature: ["a"], forced: true), "a manual refresh did not force an inspection inside the interval")
    try anchorExpect(state.shouldAttempt(now: start.addingTimeInterval(5), inputSignature: ["b"], forced: false), "a changed pane anchor did not force an inspection")
    try anchorExpect(state.shouldAttempt(now: start.addingTimeInterval(PaneListeningPortRefreshPolicy.interval), inputSignature: ["a"], forced: false), "the interval did not reopen inspection")

    let retry = start.addingTimeInterval(12)
    state.beginAttempt(at: retry, inputSignature: ["a"])
    state.finishAttempt(with: nil)
    try anchorExpect(state.snapshot == produced, "a failed inspection replaced the previous snapshot")
    try anchorExpect(state.snapshot.sampledAt == start, "a failed inspection advanced the published freshness")
    try anchorExpect(state.lastAttemptAt == retry, "a failed inspection did not count as an attempt for throttling")
    try anchorExpect(!state.isRefreshing, "a failed inspection left the state refreshing")
    try anchorExpect(!state.shouldAttempt(now: retry.addingTimeInterval(1), inputSignature: ["a"], forced: false), "a failed inspection was retried in a hot loop")
    try anchorExpect(state.shouldAttempt(now: retry.addingTimeInterval(1), inputSignature: ["a"], forced: true), "a manual refresh could not retry after a failed inspection")
}

func checkSoakPaneEvidenceFailsClosed() throws {
    func observation(_ index: Int, pid: Int32? = 1_000, alive: Bool = true, tty: UInt64? = 10) -> SoakPaneObservation {
        SoakPaneObservation(index: index, pid: pid.map { $0 + Int32(index) }, isAlive: alive, ttyDevice: tty.map { $0 + UInt64(index) })
    }
    let healthy = (0..<8).map { observation($0) }
    try anchorExpect(SoakPaneEvidence.evaluate(healthy, expectedPanes: 8) == .ready, "eight live shells with distinct TTYs were not accepted")
    try anchorExpect(SoakPaneEvidence.evaluate(Array(healthy.prefix(7)), expectedPanes: 8) != .ready, "a missing pane passed the readiness gate")
    var missingPID = healthy; missingPID[3] = observation(3, pid: nil)
    try anchorExpect(SoakPaneEvidence.evaluate(missingPID, expectedPanes: 8) != .ready, "a pane without a shell pid passed the readiness gate")
    var dead = healthy; dead[2] = observation(2, alive: false)
    try anchorExpect(SoakPaneEvidence.evaluate(dead, expectedPanes: 8) != .ready, "a dead shell passed the readiness gate")
    var noTTY = healthy; noTTY[5] = observation(5, tty: nil)
    try anchorExpect(SoakPaneEvidence.evaluate(noTTY, expectedPanes: 8) != .ready, "a shell without a controlling TTY passed the readiness gate")
    var shared = healthy; shared[6] = SoakPaneObservation(index: 6, pid: 1_006, isAlive: true, ttyDevice: 10)
    try anchorExpect(SoakPaneEvidence.evaluate(shared, expectedPanes: 8) != .ready, "two panes sharing one TTY passed the readiness gate")
    if case let .failed(reason) = SoakPaneEvidence.evaluate(noTTY, expectedPanes: 8) {
        try anchorExpect(reason.contains("5"), "the readiness failure did not name the failing pane")
    }

    // The kernel facts the soak relies on, exercised on this process.
    let me = ProcessInfo.processInfo.processIdentifier
    try anchorExpect(ProcessKernelFacts.isAlive(me), "the soak liveness probe reported this process dead")
    try anchorExpect(ProcessKernelFacts.parentPID(ofProcess: me) == getppid(), "the soak parent probe disagreed with getppid")
}
