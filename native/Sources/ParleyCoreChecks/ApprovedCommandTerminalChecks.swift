import Darwin
import Foundation
import ParleyCore

private func terminalExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ApprovedCommandTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026, e061e24b: an approved command ran in a
/// background process group that kept the pane's controlling terminal. A
/// command that asks on /dev/tty (git's HTTPS username prompt) was stopped by
/// SIGTTIN and read as running for up to a day, and the person's typed reply
/// stayed queued until the login shell the worker execs after Cancel ran it
/// as a command, a password landing in shell history. The command now runs
/// in a session of its own, with no controlling terminal, and typed input
/// still queued is discarded before the shell starts.
func checkApprovedCommandsRunWithoutTheirPaneTerminal() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    // The command reports its own pid; its session is read while it runs.
    let reporter = try ReviewedCommand(argv: ["/bin/sh", "-c", "echo $$; exec /bin/sleep 1"], folder: folder, sourceFolder: folder)
    var childSession: pid_t?
    var childPID: pid_t?
    var reported = ""
    _ = try ApprovedCommandProcess.run(reporter, environment: ["PATH": "/usr/bin:/bin"], stdoutMirror: { data in
        reported += String(decoding: data, as: UTF8.self)
        guard childPID == nil, let line = reported.split(separator: "\n").first, let pid = pid_t(line) else { return }
        childPID = pid
        childSession = getsid(pid)
    })
    let pid = try childPID.map { $0 } ?? { throw NSError(domain: "ApprovedCommandTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "the command did not report its pid: \(reported)"]) }()
    try terminalExpect(childSession == pid,
                       "the approved command is not the leader of its own session (sid \(String(describing: childSession)), pid \(pid), ours \(getsid(0)))")

    // A prompt on /dev/tty fails at once instead of stopping the command.
    let started = Date()
    let prompt = try ReviewedCommand(argv: ["/bin/sh", "-c", "read answer < /dev/tty"], folder: folder, sourceFolder: folder)
    let prompted = try ApprovedCommandProcess.run(prompt, environment: ["PATH": "/usr/bin:/bin"],
                                                  shouldCancel: { Date().timeIntervalSince(started) > 5 })
    try terminalExpect(!prompted.cancelled && prompted.exitStatus != 0,
                       "a /dev/tty prompt did not fail at once: cancelled \(prompted.cancelled), exit \(String(describing: prompted.exitStatus))")
}

/// What the person typed into the pane while the command ran is discarded
/// before the login shell starts, and the worker learns that it was there.
func checkQueuedTerminalInputIsDiscardedBeforeTheShell() throws {
    var controller: Int32 = -1, terminal: Int32 = -1
    guard openpty(&controller, &terminal, nil, nil, nil) == 0 else {
        throw NSError(domain: "ApprovedCommandTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty failed: \(errno)"])
    }
    defer { close(controller); close(terminal) }
    try terminalExpect(!ApprovedCommandWorker.discardQueuedTerminalInput(terminal), "an empty terminal reported discarded input")
    let typed = "hunter2\n"
    _ = typed.withCString { write(controller, $0, strlen($0)) }
    var available: Int32 = 0
    for _ in 0..<100 where available == 0 {
        _ = ioctl(terminal, ApprovedCommandWorker.bytesQueuedRequest, &available)
        usleep(10_000)
    }
    try terminalExpect(available > 0, "the typed reply never reached the terminal")
    try terminalExpect(ApprovedCommandWorker.discardQueuedTerminalInput(terminal), "queued input was not reported as discarded")
    available = -1
    _ = ioctl(terminal, ApprovedCommandWorker.bytesQueuedRequest, &available)
    try terminalExpect(available == 0, "typed input was still queued for the shell: \(available) bytes")
    try terminalExpect(!ApprovedCommandWorker.discardQueuedTerminalInput(STDIN_FILENO) || isatty(STDIN_FILENO) == 1,
                       "a non-terminal stdin reported discarded input")
}

@MainActor let approvedCommandTerminalChecks: [(String, () throws -> Void)] = [
    ("approved commands run without their pane terminal", checkApprovedCommandsRunWithoutTheirPaneTerminal),
    ("queued terminal input is discarded before the shell", checkQueuedTerminalInputIsDiscardedBeforeTheShell),
]
