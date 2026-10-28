import Darwin
import Foundation

/// An argv-only child of the fixed worker running in the new Ghostty pane.
/// Pipes capture the two output streams; no extra PTY or terminal renderer exists.
public enum ApprovedCommandProcess {
    public static func run(_ command: ReviewedCommand, environment: [String: String],
                           shouldCancel: () -> Bool = { false },
                           stdoutMirror: (Data) -> Void = { _ in },
                           stderrMirror: (Data) -> Void = { _ in },
                           now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                           pause: (UInt32) -> Void = { usleep($0) },
                           observe: (id_t, UnsafeMutablePointer<siginfo_t>) -> Int32 = { waitid(P_PID, $0, $1, WEXITED | WNOHANG | WNOWAIT) },
                           wait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { waitpid($0, $1, $2) }) throws -> ReviewedCommandRunResult {
        if shouldCancel() { return ReviewedCommandRunResult(exitStatus: nil, stdout: Data(), stderr: Data(), cancelled: true, detail: "Cancelled before the command was spawned.") }
        let output = try makePipe()
        var outputWriterOpen = true
        defer { close(output.0); if outputWriterOpen { close(output.1) } }
        let error = try makePipe()
        var errorWriterOpen = true
        defer { close(error.0); if errorWriterOpen { close(error.1) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // Same clean signal state as ProcessCommandRunner: an approved command
        // must not inherit a blocked mask from whichever thread spawned it.
        var defaultedSignals = sigset_t()
        sigfillset(&defaultedSignals)
        var clearedMask = sigset_t()
        sigemptyset(&clearedMask)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaultedSignals))
        try checked(posix_spawnattr_setsigmask(&attributes, &clearedMask))
        // A session of its own, so no controlling terminal. In the pane's
        // session a command that asks on /dev/tty (git's HTTPS username
        // prompt) was stopped by SIGTTIN and read as running for up to a day;
        // now the open fails and the command reports it. The session's
        // process group id is the pid, so kill(-pid) still reaches the group.
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_adddup2(&actions, output.1, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, error.1, STDERR_FILENO))
        try checked(posix_spawn_file_actions_addchdir_np(&actions, command.folder))

        var argv = command.argv.map { strdup($0) } + [nil]
        // Never lend the requester's or worker's coordination authority to the
        // command. Its permissions are those of the person-approved Shell run.
        var env = InheritedSessionEnvironment.removing(from: environment.filter { !$0.key.hasPrefix("PARLEY_") })
        env["PWD"] = command.folder
        var envp = env.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { a in
            envp.withUnsafeMutableBufferPointer { e in
                posix_spawn(&pid, command.argv[0], &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        try checked(spawned)
        close(output.1)
        outputWriterOpen = false
        close(error.1)
        errorWriterOpen = false
        var cleanupAttempted = false
        defer {
            if !cleanupAttempted {
                // The unreaped direct child reserves the process-group id.
                // Never target an id after it may have been recycled.
                _ = kill(-pid, SIGKILL)
                var status: Int32 = 0
                _ = BoundedReap.run(pid, status: &status, now: now, wait: wait, pause: pause)
            }
        }

        var buffers = [Data(), Data()]
        var openStreams = [true, true]
        let descriptors = [output.0, error.0]
        var truncated = false
        var cancelledAt: UInt64?
        var exitedAt: UInt64?
        var killedAt: UInt64?
        let deadline = now() &+ 24 * 60 * 60 * 1_000_000_000
        while true {
            let instant = now()
            if (shouldCancel() || instant >= deadline), cancelledAt == nil {
                cancelledAt = instant
                _ = kill(-pid, SIGTERM)
            }
            if let cancelledAt, instant &- cancelledAt >= 500_000_000, killedAt == nil {
                _ = kill(-pid, SIGKILL)
                killedAt = instant
            }
            var info = siginfo_t()
            let observed = observe(id_t(pid), &info)
            if observed == 0 && info.si_pid == pid && exitedAt == nil { exitedAt = instant }
            if observed != 0 && errno != EINTR {
                // ECHILD means the identity is no longer reserved; do not send
                // a cleanup signal to a potentially recycled process group.
                if errno == ECHILD { cleanupAttempted = true }
                try checked(errno)
            }
            for index in 0..<2 where openStreams[index] {
                // Bound work per poll so a noisy process cannot starve Cancel.
                for _ in 0..<8 {
                    var bytes = [UInt8](repeating: 0, count: 8_192)
                    let count = Darwin.read(descriptors[index], &bytes, bytes.count)
                    if count > 0 {
                        let data = Data(bytes.prefix(count))
                        if index == 0 { stdoutMirror(data) } else { stderrMirror(data) }
                        let room = max(0, 32_768 - buffers[index].count)
                        buffers[index].append(data.prefix(room))
                        if count > room { truncated = true }
                    } else {
                        if count == 0 { openStreams[index] = false }
                        else if errno != EAGAIN && errno != EINTR { openStreams[index] = false; truncated = true }
                        break
                    }
                }
            }
            if let exitedAt {
                // Descendants retaining a pipe cannot hold completion forever.
                if !openStreams.contains(true) || instant &- exitedAt >= 500_000_000 {
                    if openStreams.contains(true) { truncated = true }
                    break
                }
            }
            if let killedAt, instant &- killedAt >= BoundedReap.bound {
                truncated = true
                break
            }
            pause(10_000)
        }
        // Terminate descendants still in this owned group before reaping the
        // root, preserving the identity used for cancellation and cleanup.
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        let reap = BoundedReap.run(pid, status: &status, now: now, wait: wait, pause: pause)
        cleanupAttempted = true
        guard reap == "killed-after-timeout" else {
            return ReviewedCommandRunResult(exitStatus: nil, stdout: buffers[0], stderr: buffers[1], outputTruncated: true,
                cancelled: cancelledAt != nil, detail: "The command's exit could not be observed after bounded cleanup (\(reap)); completion is unknown.")
        }
        let signal = status & 0x7f
        return ReviewedCommandRunResult(exitStatus: signal == 0 ? (status >> 8) & 0xff : nil,
            terminationSignal: signal == 0 ? nil : signal,
            stdout: buffers[0], stderr: buffers[1], outputTruncated: truncated,
            cancelled: cancelledAt != nil,
            detail: cancelledAt == nil ? nil : "The owned command was cancelled; captured output may be incomplete.")
    }

    private static func makePipe() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { try checked(errno); throw ReviewedCommandRunError.invalid("Could not open output pipe.") }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        let flags = fcntl(descriptors[0], F_GETFL, 0)
        _ = fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK)
        return (descriptors[0], descriptors[1])
    }
    private static func checked(_ code: Int32) throws {
        if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil) }
    }
}
