import Foundation
import CryptoKit
import Darwin

public struct ApprovedCommandTicket: Codable, Sendable {
    public let resultKey: Data
    public let runID: String
    public let command: ReviewedCommand
    public let sourceFolder: String
    public let shellExecutable: String
    public let ownerPID: Int32
    public let expiresAt: Date
}



public struct ApprovedCommandWorkerObservation: Sendable {
    public let running: Bool
    public let ticketPending: Bool
    public let consumed: Bool
    public let failure: String?
}

private struct AuthenticatedCommandResult: Codable {
    let payload: Data
    let authentication: Data
}
private final class CommandResultKeys: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: SymmetricKey] = [:]
}

// Signal handlers perform no allocation or Foundation work.
nonisolated(unsafe) private var commandWorkerInterrupted: sig_atomic_t = 0
private func interruptCommandWorker(_ signal: Int32) { commandWorkerInterrupted = signal }

/// One transient child of Ghostty, using its existing PTY. This is not an app
/// instance: the entry point dispatches here before constructing any UI/core.
public enum ApprovedCommandWorker {
    private static let resultKeys = CommandResultKeys()
    public static let argument = "--parley-approved-command-worker"
    public static func stage(run: ReviewedCommandRun, directory: URL, shellExecutable: String, ownerPID: Int32) throws -> URL {
        guard run.state == .running, UUID(uuidString: run.id) != nil,
              shellExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shellExecutable) else {
            throw ReviewedCommandRunError.invalid("Only a natively approved running request can create a worker ticket.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try privateDirectory(directory)
        let job = directory.appendingPathComponent(run.id, isDirectory: true)
        guard mkdir(job.path, 0o700) == 0 else { throw posixError() }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let ticket = ApprovedCommandTicket(resultKey: keyData, runID: run.id, command: run.command, sourceFolder: run.sourceFolder,
            shellExecutable: shellExecutable, ownerPID: ownerPID, expiresAt: Date().addingTimeInterval(120))
        let path = job.appendingPathComponent("ticket.json")
        try writeNew(JSONEncoder().encode(ticket), to: path)
        resultKeys.lock.withLock { resultKeys.values[job.path] = key }
        return path
    }

    public static func consume(_ ticket: URL) throws -> ApprovedCommandTicket {
        let value = try claim(ticket)
        try validate(value)
        return value
    }

    private static func claim(_ ticket: URL) throws -> ApprovedCommandTicket {
        guard ticket.lastPathComponent == "ticket.json" else { throw ReviewedCommandRunError.invalid("Invalid worker ticket name.") }
        let job = ticket.deletingLastPathComponent()
        try privateDirectory(job)
        _ = try readPrivate(ticket, limit: 100_000)
        let consumed = job.appendingPathComponent("consumed.json")
        // Atomic claim: a second worker can never consume the same approval.
        guard renamex_np(ticket.path, consumed.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
        var redacted = false
        defer {
            if !redacted {
                _ = unlink(consumed.path)
                try? writeNew(Data(), to: consumed)
            }
        }
        let value = try JSONDecoder().decode(ApprovedCommandTicket.self, from: readPrivate(consumed, limit: 100_000))
        guard value.resultKey.count == 32, value.runID == job.lastPathComponent else { throw ReviewedCommandRunError.invalid("Invalid worker ticket identity.") }
        // Remove the signing key before any approved child can start. Retain
        // an empty atomic-claim marker so the ticket can never be replayed.
        guard unlink(consumed.path) == 0 else { throw posixError() }
        try writeNew(Data(), to: consumed)
        redacted = true
        return value
    }

    private static func validate(_ value: ApprovedCommandTicket) throws {
        guard value.resultKey.count == 32, UUID(uuidString: value.runID) != nil,
              value.expiresAt > Date(), value.ownerPID > 1, kill(value.ownerPID, 0) == 0,
              value.shellExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: value.shellExecutable) else {
            throw ReviewedCommandRunError.invalid("The worker ticket expired or its application owner is unavailable.")
        }
        let checked = try ReviewedCommand(argv: value.command.argv, folder: value.command.folder, sourceFolder: value.sourceFolder)
        guard checked == value.command else { throw ReviewedCommandRunError.invalid("The approved working folder changed before launch.") }
    }

    @discardableResult
    public static func cancel(runID: String, directory: URL) throws -> Bool {
        guard UUID(uuidString: runID) != nil else { return true }
        let job = directory.appendingPathComponent(runID)
        guard FileManager.default.fileExists(atPath: job.path) else { return true }
        try privateDirectory(job)
        // Atomic race with claim: if this rename wins, argv can never run.
        let ticket = job.appendingPathComponent("ticket.json")
        let cancelled = job.appendingPathComponent("cancelled.json")
        if renamex_np(ticket.path, cancelled.path, UInt32(RENAME_EXCL)) == 0 {
            resultKeys.lock.withLock { _ = resultKeys.values.removeValue(forKey: job.path) }
            guard unlink(cancelled.path) == 0 else { throw posixError() }
            try writeNew(Data(), to: cancelled)
            return true
        }
        let renameError = errno
        if FileManager.default.fileExists(atPath: cancelled.path) { return true }
        if renameError != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError)) }
        let path = job.appendingPathComponent("cancel")
        if !FileManager.default.fileExists(atPath: path.path) { try writeNew(Data(), to: path) }
        return false
    }

    public static func result(runID: String, directory: URL) throws -> ReviewedCommandRunResult? {
        guard UUID(uuidString: runID) != nil else { return nil }
        let job = directory.appendingPathComponent(runID)
        let path = job.appendingPathComponent("result.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        try privateDirectory(job)
        guard let key = resultKeys.lock.withLock({ resultKeys.values[job.path] }) else {
            throw ReviewedCommandRunError.invalid("No live application authority exists for this result; history cannot restore a run.")
        }
        let envelope = try JSONDecoder().decode(AuthenticatedCommandResult.self, from: readPrivate(path, limit: 200_000))
        guard HMAC<SHA256>.isValidAuthenticationCode(envelope.authentication,
            authenticating: authenticatedBytes(runID: runID, payload: envelope.payload), using: key) else {
            throw ReviewedCommandRunError.invalid("The command result was altered or did not come from its approved worker.")
        }
        return try JSONDecoder().decode(ReviewedCommandRunResult.self, from: envelope.payload)
    }


    /// A kernel lease releases on death and on exec to the ordinary Shell.
    /// The command child cannot inherit it through CLOEXEC_DEFAULT.
    public static func observation(runID: String, directory: URL) throws -> ApprovedCommandWorkerObservation {
        guard UUID(uuidString: runID) != nil else { throw ReviewedCommandRunError.invalid("Invalid run identity.") }
        let job = directory.appendingPathComponent(runID)
        guard FileManager.default.fileExists(atPath: job.path) else {
            return ApprovedCommandWorkerObservation(running: false, ticketPending: false, consumed: false, failure: nil)
        }
        try privateDirectory(job)
        let running = try workerIsRunning(runID: runID, directory: directory)
        let failurePath = job.appendingPathComponent("failure.txt")
        var failure: String?
        if FileManager.default.fileExists(atPath: failurePath.path) {
            let raw = try readPrivate(failurePath, limit: 8_000)
            failure = ReviewedCommandRunResult(exitStatus: nil, stdout: Data(), stderr: raw).stderr
        }
        return ApprovedCommandWorkerObservation(running: running,
            ticketPending: FileManager.default.fileExists(atPath: job.appendingPathComponent("ticket.json").path),
            consumed: FileManager.default.fileExists(atPath: job.appendingPathComponent("consumed.json").path),
            failure: failure)
    }

    public static func workerIsRunning(runID: String, directory: URL) throws -> Bool {
        guard UUID(uuidString: runID) != nil else { throw ReviewedCommandRunError.invalid("Invalid run identity.") }
        let job = directory.appendingPathComponent(runID)
        guard FileManager.default.fileExists(atPath: job.path) else { return false }
        try privateDirectory(job)
        let lockPath = job.appendingPathComponent("worker.lock")
        var running = false
        if FileManager.default.fileExists(atPath: lockPath.path) {
            let descriptor = open(lockPath.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            if descriptor >= 0 { close(descriptor) }
            else if errno == EWOULDBLOCK || errno == EAGAIN { running = true }
            else { throw posixError() }
        }
        return running
    }

    public static func removeAbandoned(in directory: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var warnings: [String] = []
        do {
            try privateDirectory(directory)
            for job in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where UUID(uuidString: job.lastPathComponent) != nil {
                do { _ = try discard(runID: job.lastPathComponent, directory: directory) }
                catch {
                    if warnings.count < 8 { warnings.append("Skipped command-run cleanup for \(job.lastPathComponent): \(error.localizedDescription)") }
                }
            }
        } catch {
            warnings.append("Command-run cleanup could not inspect its storage: \(error.localizedDescription)")
        }
        return warnings
    }

    private static func acquireLease(_ job: URL) throws -> Int32 {
        try privateDirectory(job)
        var descriptor: Int32 = -1
        let deadline = Date().addingTimeInterval(1)
        repeat {
            descriptor = open(job.appendingPathComponent("worker.lock").path,
                O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor >= 0 { break }
            let code = errno
            guard (code == EWOULDBLOCK || code == EAGAIN) && Date() < deadline else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            usleep(5_000)
        } while true
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            close(descriptor)
            throw ReviewedCommandRunError.invalid("Invalid worker lease.")
        }
        return descriptor
    }

    public static func execute(ticketPath: String) -> Never {
        let path = URL(fileURLWithPath: ticketPath)
        let job = path.deletingLastPathComponent()
        var shell: String?
        var lease: Int32 = -1
        do {
            lease = try acquireLease(job)
            let ticket = try claim(path)
            shell = ticket.shellExecutable
            commandWorkerInterrupted = 0
            for value in [SIGHUP, SIGTERM, SIGINT] { signal(value, interruptCommandWorker) }
            signal(SIGPIPE, SIG_IGN)
            signal(SIGCHLD, SIG_DFL)
            for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
            }
            let result: ReviewedCommandRunResult
            do {
                try validate(ticket)
                result = try ApprovedCommandProcess.run(ticket.command,
                    environment: ProcessInfo.processInfo.environment,
                    shouldCancel: {
                        commandWorkerInterrupted != 0 || kill(ticket.ownerPID, 0) != 0
                            || FileManager.default.fileExists(atPath: job.appendingPathComponent("cancel").path)
                    }, stdoutMirror: { mirror($0, to: STDOUT_FILENO) },
                    stderrMirror: { mirror($0, to: STDERR_FILENO) })
            } catch {
                result = ReviewedCommandRunResult(exitStatus: nil, stdout: Data(), stderr: Data(),
                    detail: "The approved process could not run: \(error.localizedDescription)")
            }
            let temporary = job.appendingPathComponent("result.pending")
            let payload = try JSONEncoder().encode(result)
            let authentication = HMAC<SHA256>.authenticationCode(
                for: authenticatedBytes(runID: ticket.runID, payload: payload), using: SymmetricKey(data: ticket.resultKey))
            let envelope = AuthenticatedCommandResult(payload: payload, authentication: Data(authentication))
            try writeNew(JSONEncoder().encode(envelope), to: temporary)
            guard renamex_np(temporary.path, job.appendingPathComponent("result.json").path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            mirror(Data("\r\n[Parley captured command result: exit \(result.exitStatus.map(String.init) ?? "unavailable"), signal \(result.terminationSignal.map(String.init) ?? "none"). Returning to Shell.]\r\n".utf8), to: STDOUT_FILENO)
            if commandWorkerInterrupted != 0 || kill(ticket.ownerPID, 0) != 0 { exit(0) }
            _ = chdir(ticket.command.folder)
        } catch {
            if lease >= 0 {
                let detail = ReviewedCommandRunResult(exitStatus: nil, stdout: Data(), stderr: Data(), detail: error.localizedDescription).detail ?? "The worker could not publish its result."
                try? writeNew(Data(detail.utf8), to: job.appendingPathComponent("failure.txt"))
            }
            mirror(Data("Parley approved command could not start: \(error.localizedDescription)\r\n".utf8), to: STDERR_FILENO)
        }
        guard let shell else { exit(1) }
        // The one-use command is over. The same retained Ghostty pane now owns
        // an ordinary human login shell, with no reusable execution ticket.
        for value in [SIGHUP, SIGTERM, SIGINT, SIGPIPE] { signal(value, SIG_DFL) }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) & ~O_NONBLOCK)
        }
        var environment = ProcessInfo.processInfo.environment
        let shellMetadata: Set<String> = ["PARLEY_PANE", "PARLEY_PANE_ID", "PARLEY_PANE_KIND", "PARLEY_APP_PID", "PARLEY_RUNTIME"]
        for key in environment.keys where key.hasPrefix("PARLEY_") && !shellMetadata.contains(key) { environment.removeValue(forKey: key) }
        let arguments: [String] = [shell, "-l"]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { $0.withCString { strdup($0) } } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { values in
            _ = execve(shell, args.baseAddress!, values.baseAddress!)
        } }
        exit(1)
    }

    @discardableResult
    public static func discard(runID: String, directory: URL) throws -> Bool {
        guard UUID(uuidString: runID) != nil else { return false }
        guard try !workerIsRunning(runID: runID, directory: directory) else { return false }
        let job = directory.appendingPathComponent(runID)
        resultKeys.lock.withLock { _ = resultKeys.values.removeValue(forKey: job.path) }
        guard FileManager.default.fileExists(atPath: job.path) else { return true }
        try privateDirectory(job)
        try FileManager.default.removeItem(at: job)
        return true
    }

    private static func authenticatedBytes(runID: String, payload: Data) -> Data {
        Data((runID + "\0").utf8) + payload
    }

    private static func mirror(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if errno != EINTR { break }
            }
        }
    }
    private static func privateDirectory(_ path: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              path.standardizedFileURL.path == path.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ReviewedCommandRunError.invalid("The command worker directory must be an owner-only real directory.")
        }
    }
    private static func readPrivate(_ path: URL, limit: Int) throws -> Data {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else {
            throw ReviewedCommandRunError.invalid("Invalid private command worker file.")
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw posixError() }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= limit else { throw ReviewedCommandRunError.invalid("Command worker file exceeds its bound.") }
        }
    }
    private static func writeNew(_ data: Data, to path: URL) throws {
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if errno != EINTR { throw posixError() }
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
