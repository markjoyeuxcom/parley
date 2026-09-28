import Darwin
import Dispatch
import Foundation
import ParleyCore

private func processExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ProcessLow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A command whose child starts a descendant that ignores SIGTERM: the
/// descendant's pid is written to `pidFile`, then the child waits forever.
private func stubbornDescendantScript(_ pidFile: URL) -> [String] {
    ["-c", "/bin/sh -c 'trap \"\" TERM; exec /bin/sleep 60' & echo $! > \"$0\"; wait", pidFile.path]
}

private func descendantGone(_ pidFile: URL) throws -> (gone: Bool, pid: pid_t) {
    let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(text), pid > 1 else { throw NSError(domain: "ProcessLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "no descendant pid: \(text)"]) }
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if kill(pid, 0) != 0, errno == ESRCH { return (true, pid) }
        usleep(20_000)
    }
    return (false, pid)
}

/// Review of 22 September 2026 (96c795d7): a timeout killed only the direct
/// child, so a hook, filter or other descendant kept running after the
/// command was reported timed out. The command runs as its own process group
/// and the whole group is ended.
func checkTimeoutEndsTheWholeProcessGroup() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-pgroup-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let spawned = directory.appendingPathComponent("spawned.pid")
    let output = try ProcessCommandRunner(timeout: 0.8).run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: stubbornDescendantScript(spawned), environment: ["PATH": "/usr/bin:/bin"], input: nil)
    try processExpect(output.status == CommandExitStatus.timedOut, "the fixture did not time out: \(output.status)")
    let (spawnedGone, spawnedPID) = try descendantGone(spawned)
    if !spawnedGone { kill(spawnedPID, SIGKILL) }
    try processExpect(spawnedGone, "ProcessCommandRunner's timeout left a descendant running (pid \(spawnedPID))")

    let captured = directory.appendingPathComponent("captured.pid")
    _ = try ContextProcessCommandRunner(timeout: 0.8).run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: stubbornDescendantScript(captured), workingDirectory: directory, environment: ["PATH": "/usr/bin:/bin"])
    let (capturedGone, capturedPID) = try descendantGone(captured)
    if !capturedGone { kill(capturedPID, SIGKILL) }
    try processExpect(capturedGone, "a Command Result's timeout left a descendant running (pid \(capturedPID))")
}

/// Review of 22 September 2026 (96c795d7): the 1 MB limit on a Claude
/// settings file was checked on the symlink and the target read whole. The
/// project's `.claude` folder is writable by the agent, so its settings file
/// can also be a FIFO, whose open would block the reader (the launch review
/// reads it on the main actor) until a writer appeared.
func checkClaudeSettingsReadIsBoundedAndNonBlocking() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-claudesettings-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A small symlink to a settings file over the limit.
    let large = directory.appendingPathComponent("large.json")
    let padding = String(repeating: " ", count: ClaudeHostConfiguration.maximumSettingsBytes + 10)
    try "{\"sandbox\":{\"enabled\":true}\(padding)}".write(to: large, atomically: true, encoding: .utf8)
    let linked = directory.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: large)
    try processExpect(ClaudeHostConfiguration.enabled(in: linked, fileManager: .default) == nil,
                      "a settings file over the limit was read through a symlink")
    // Within the limit, through a symlink, still read (Claude follows it too).
    let small = directory.appendingPathComponent("small.json")
    try "{\"sandbox\":{\"enabled\":true}}".write(to: small, atomically: true, encoding: .utf8)
    let smallLink = directory.appendingPathComponent("small-link.json")
    try FileManager.default.createSymbolicLink(at: smallLink, withDestinationURL: small)
    try processExpect(ClaudeHostConfiguration.enabled(in: smallLink, fileManager: .default) == true, "a linked settings file within the limit was not read")

    // A FIFO: nothing to read, and it must not block.
    let fifo = directory.appendingPathComponent("fifo.json")
    try processExpect(mkfifo(fifo.path, 0o600) == 0, "could not make the FIFO fixture")
    final class Result: @unchecked Sendable { let lock = NSLock(); var done = false; var value: Bool?? }
    let result = Result()
    Thread.detachNewThread {
        let value = ClaudeHostConfiguration.enabled(in: fifo, fileManager: .default)
        result.lock.withLock { result.done = true; result.value = value }
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while !result.lock.withLock({ result.done }), DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
    let finished = result.lock.withLock { result.done }
    if !finished {
        // Release the blocked reader so the thread does not outlive the check.
        let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
        if writer >= 0 { close(writer) }
    }
    try processExpect(finished, "reading a FIFO settings file blocked")
    try processExpect(result.lock.withLock { result.value } == .some(nil), "a FIFO settings file produced a value")
}

/// The launch review's ticket policy read up to four Claude settings files
/// on every evaluation, about five times per render, on the main actor. The
/// review reads them once per vendor, folder and container choice.
func checkClaudeSandboxFactIsReadOncePerChoice() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-sandboxcache-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "{\"sandbox\":{\"enabled\":true}}".write(to: directory.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    let cache = ClaudeSandboxFactCache()
    for _ in 0..<10 {
        let fact = cache.fact(kind: .claude, folder: directory.path, inContainer: false)
        try processExpect(fact?.enabled == true, "the cached fact is wrong: \(String(describing: fact))")
    }
    try processExpect(cache.reads == 1, "ten evaluations read the settings \(cache.reads) times")
    try processExpect(cache.fact(kind: .claude, folder: directory.path, inContainer: true) == nil, "a container pane was given a host sandbox fact")
    try processExpect(cache.fact(kind: .codex, folder: directory.path, inContainer: false) == nil, "a Codex pane was given a Claude sandbox fact")
    _ = cache.fact(kind: .claude, folder: directory.path, inContainer: false)
    try processExpect(cache.reads == 1, "returning to the same folder read the settings again (\(cache.reads))")
    _ = cache.fact(kind: .claude, folder: directory.appendingPathComponent(".claude").path, inContainer: false)
    try processExpect(cache.reads == 2, "a different folder was not read (\(cache.reads))")
}

/// Review of 22 September 2026 (96c795d7): the observation read the worker's
/// lease, then its ticket files. A worker that took its lease and claimed its
/// ticket in between read as "not running, ticket consumed", which the
/// coordinator reports as a worker that ended without a result (and says not
/// to resend). The worker starts here at exactly that moment.
func checkWorkerStartingMidObservationIsNotAFailure() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-workerobs-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    let runID = UUID().uuidString
    let job = directory.appendingPathComponent(runID)
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ticket = job.appendingPathComponent("ticket.json")
    FileManager.default.createFile(atPath: ticket.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o600])
    var lease: Int32 = -1
    defer { if lease >= 0 { close(lease) } }
    let observation = try ApprovedCommandWorker.observation(runID: runID, directory: directory, betweenReads: {
        // The worker: lease first, then the atomic claim of its ticket.
        lease = open(job.appendingPathComponent("worker.lock").path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        _ = rename(ticket.path, job.appendingPathComponent("consumed.json").path)
    })
    try processExpect(lease >= 0, "the fixture worker could not take its lease")
    try processExpect(observation.running || !observation.consumed,
                      "a worker that started mid-observation read as ended without a result (running \(observation.running), consumed \(observation.consumed))")
}

/// Runs `script` through ProcessCommandRunner on a thread and hands back the
/// child's pid (the script writes `$$` to its first argument) while it runs.
private func withRunningChild(_ script: String, in directory: URL, timeout: TimeInterval = 5,
                              _ body: (pid_t) throws -> Void) throws {
    let pidFile = directory.appendingPathComponent("child-\(UUID().uuidString.prefix(8)).pid")
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = try? ProcessCommandRunner(timeout: timeout).run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, pidFile.path], environment: ["PATH": "/usr/bin:/bin"], input: nil)
        finished.signal()
    }
    defer { _ = finished.wait(timeout: .now() + timeout + 5) }
    var pid: pid_t = 0
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    while pid <= 1, DispatchTime.now().uptimeNanoseconds < deadline {
        pid = pid_t(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        usleep(10_000)
    }
    try processExpect(pid > 1, "the child never reported its pid")
    try body(pid)
}

/// The fresh-context review of e1dccee: in a process group of its own but in
/// Parley's session, a child that wants the terminal (the `zsh -lic` PATH
/// discovery at launch opens /dev/tty to take the foreground) was stopped by
/// SIGTTOU whenever Parley had a controlling terminal (`npm run dev`), stalling
/// launch for the whole timeout. A command runs in a session of its own, with
/// no controlling terminal to reach.
func checkCommandsRunInTheirOwnSession() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-session-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try withRunningChild("echo $$ > \"$0\"; /bin/sleep 1", in: directory) { pid in
        let session = getsid(pid)
        try processExpect(session == pid, "the command runs in session \(session), not its own (\(pid)); Parley's is \(getsid(0))")
    }
}

/// A timeout's SIGTERM gives the whole group its grace second: the direct
/// child exiting at once used to cut every descendant's grace to about 10 ms
/// (a `git` child killed while removing its index.lock).
func checkDescendantsKeepTheirSigtermGrace() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-grace-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("cleaned-up")
    // The descendant cleans up for 0.3 s after SIGTERM; its parent exits at once.
    let descendant = "trap '/bin/sleep 0.3; echo done > \"$1\"; exit 0' TERM; while :; do /bin/sleep 0.05; done"
    let output = try ProcessCommandRunner(timeout: 0.8).run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "/bin/sh -c \"$1\" sh \"$0\" & wait", marker.path, descendant], environment: ["PATH": "/usr/bin:/bin"], input: nil)
    try processExpect(output.status == CommandExitStatus.timedOut, "the fixture did not time out: \(output.status)")
    try processExpect(FileManager.default.fileExists(atPath: marker.path), "a descendant was killed before its SIGTERM cleanup finished")
}

/// With the files read before the lease, a worker that started, failed its
/// claim, wrote its failure and exited inside the window read as still
/// waiting for its ticket, losing the real failure. When the lease says the
/// worker is not running, the files are final: they are read again.
func checkWorkerFailureInsideTheWindowIsKept() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-workerfail-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    let runID = UUID().uuidString
    let job = directory.appendingPathComponent(runID)
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ticket = job.appendingPathComponent("ticket.json")
    FileManager.default.createFile(atPath: ticket.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o600])
    let observation = try ApprovedCommandWorker.observation(runID: runID, directory: directory, betweenReads: {
        // A whole worker inside the window: claim, fail, record why, exit.
        _ = rename(ticket.path, job.appendingPathComponent("consumed.json").path)
        FileManager.default.createFile(atPath: job.appendingPathComponent("failure.txt").path,
                                       contents: Data("The approved command ticket changed before execution; nothing was run.".utf8),
                                       attributes: [.posixPermissions: 0o600])
    })
    try processExpect(!observation.running && observation.failure?.contains("nothing was run") == true && !observation.ticketPending,
                      "a worker that failed inside the window lost its failure (ticket pending \(observation.ticketPending), failure \(String(describing: observation.failure)))")
}

/// The Codex configuration query killed only its direct child: a launcher
/// (npm's `codex` is Node around the native binary) could leave its child
/// running.
func checkCodexConfigQueryEndsItsGroup() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-codexgroup-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("descendant.pid")
    let fake = directory.appendingPathComponent("codex")
    try """
    #!/bin/sh
    /bin/sh -c 'trap "" TERM; exec /bin/sleep 60' &
    echo $! > "\(pidFile.path)"
    exec /bin/sleep 60
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
    _ = try? CodexHostConfiguration.read(executable: fake, arguments: [], environment: ["PATH": "/usr/bin:/bin"], folder: directory.path, timeout: 1)
    let (gone, pid) = try descendantGone(pidFile)
    if !gone { kill(pid, SIGKILL) }
    try processExpect(gone, "the Codex configuration query left its launcher's child running (pid \(pid))")
}

/// The launch's PATH discovery runs an interactive login zsh. It must finish,
/// promptly, whether or not Parley has a controlling terminal (this only
/// bites with one: run the suite under `script -q /dev/null` to exercise it).
/// An empty ZDOTDIR keeps the person's own shell configuration out of it.
func checkInteractiveLoginShellCompletes() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-zsh-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let started = DispatchTime.now().uptimeNanoseconds
    let output = try ProcessCommandRunner(timeout: 5).run(executable: URL(fileURLWithPath: "/bin/zsh"),
        arguments: ["-lic", "print -r -- parley-ok"],
        environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path, "ZDOTDIR": directory.path, "TERM": "dumb"], input: nil)
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    try processExpect(output.status == 0 && output.stdoutText.contains("parley-ok"),
                      "an interactive login shell did not complete: status \(output.status) after \(seconds) s, stderr \(output.stderrText.prefix(200))")
    try processExpect(seconds < 3, "an interactive login shell took \(seconds) s")
}

@MainActor let processLowChecks: [(String, () throws -> Void)] = [
    ("an interactive login shell completes", checkInteractiveLoginShellCompletes),
    ("commands run in their own session", checkCommandsRunInTheirOwnSession),
    ("descendants keep their sigterm grace", checkDescendantsKeepTheirSigtermGrace),
    ("a worker failure inside the observation window is kept", checkWorkerFailureInsideTheWindowIsKept),
    ("the codex config query ends its process group", checkCodexConfigQueryEndsItsGroup),
    ("a worker starting mid-observation is not a failure", checkWorkerStartingMidObservationIsNotAFailure),
    ("the claude sandbox fact is read once per review choice", checkClaudeSandboxFactIsReadOncePerChoice),
    ("claude settings reads are bounded and never block", checkClaudeSettingsReadIsBoundedAndNonBlocking),
    ("a timeout ends the whole process group", checkTimeoutEndsTheWholeProcessGroup),
]
