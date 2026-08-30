import Darwin
import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public let diagnostic: String?

    public init(
        stdout: Data = Data(),
        stderr: Data = Data(),
        status: Int32 = 0,
        diagnostic: String? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.diagnostic = diagnostic
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public protocol CommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?
    ) throws -> CommandOutput

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?,
        outputExpectation: CommandOutputExpectation
    ) throws -> CommandOutput
}

public enum CommandOutputExpectation: Sendable {
    case immediate
    case mayArriveAfterClientExit
}

public extension CommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?,
        outputExpectation: CommandOutputExpectation
    ) throws -> CommandOutput {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: input
        )
    }
}

public final class ProcessCommandRunner: CommandRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data? = nil
    ) throws -> CommandOutput {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: input,
            outputExpectation: .immediate
        )
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?,
        outputExpectation: CommandOutputExpectation
    ) throws -> CommandOutput {
        let started = DispatchTime.now().uptimeNanoseconds
        let stdin = try CommandPipe()
        let stdout = try CommandCaptureFile(label: "stdout")
        let stderr = try CommandCaptureFile(label: "stderr")
        var actions: posix_spawn_file_actions_t?
        let actionsStatus = posix_spawn_file_actions_init(&actions)
        guard actionsStatus == 0 else {
            throw commandPOSIXError(actionsStatus, operation: "posix_spawn_file_actions_init")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else {
            throw commandPOSIXError(attributesStatus, operation: "posix_spawnattr_init")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let closeUnmappedDescriptors = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        let flagsStatus = posix_spawnattr_setflags(&attributes, closeUnmappedDescriptors)
        guard flagsStatus == 0 else {
            throw commandPOSIXError(flagsStatus, operation: "isolate child file descriptors")
        }

        try addSpawnAction(
            posix_spawn_file_actions_adddup2(&actions, stdin.readDescriptor, STDIN_FILENO),
            operation: "redirect stdin"
        )
        try addSpawnAction(
            posix_spawn_file_actions_adddup2(&actions, stdout.descriptor, STDOUT_FILENO),
            operation: "redirect stdout"
        )
        try addSpawnAction(
            posix_spawn_file_actions_adddup2(&actions, stderr.descriptor, STDERR_FILENO),
            operation: "redirect stderr"
        )
        try addSpawnAction(
            posix_spawn_file_actions_addclose(&actions, stdin.writeDescriptor),
            operation: "close child stdin writer"
        )
        let argumentStrings = [executable.path] + arguments
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let argumentStorage = CStringArray(argumentStrings)
        let environmentStorage = CStringArray(environmentStrings)
        var processIdentifier = pid_t()
        let spawnStatus = executable.path.withCString { path in
            argumentStorage.withUnsafeMutablePointer { argumentPointer in
                environmentStorage.withUnsafeMutablePointer { environmentPointer in
                    posix_spawn(
                        &processIdentifier,
                        path,
                        &actions,
                        &attributes,
                        argumentPointer,
                        environmentPointer
                    )
                }
            }
        }
        guard spawnStatus == 0 else {
            throw commandPOSIXError(spawnStatus, operation: "start \(executable.path)")
        }

        stdin.closeRead()

        let writers = DispatchGroup()
        if let input {
            writers.enter()
            DispatchQueue.global(qos: .utility).async {
                writeCommandPipe(stdin.takeWrite(), data: input)
                writers.leave()
            }
        } else {
            stdin.closeWrite()
        }

        let wait = waitForCommand(processIdentifier, timeout: timeout)
        writers.wait()

        let capturedBeforeSettle = "\(stdout.byteCount())/\(stderr.byteCount())"
        if outputExpectation == .mayArriveAfterClientExit {
            waitForCapturedOutput(stdout: stdout, stderr: stderr, timeout: 0.2)
        }

        let outputData = stdout.data()
        var errorData = stderr.data()
        if wait.timedOut {
            if !errorData.isEmpty { errorData.append(Data("\n".utf8)) }
            errorData.append(Data("Command timed out after \(timeout) seconds".utf8))
        }
        return CommandOutput(
            stdout: outputData,
            stderr: errorData,
            status: wait.timedOut ? 124 : commandExitStatus(wait.status),
            diagnostic: [
                "wait=\(wait.reason)",
                "elapsedMs=\((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)",
                "capturedBeforeSettle=\(capturedBeforeSettle)",
                "captured=\(outputData.count)/\(errorData.count)",
            ].joined(separator: " ")
        )
    }
}

/// Captures one child stream without relying on pipe EOF. A tool may fork a
/// long-lived child that inherits stdout or stderr after the
/// short-lived client exits. An unlinked owner-only file can be read as soon
/// as that client is reaped, even while a descendant still holds its duplicate.
private final class CommandCaptureFile {
    let descriptor: Int32

    init(label: String) throws {
        var template = Array("/private/tmp/parley-command-\(label)-XXXXXX".utf8CString)
        let opened = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard opened >= 0 else {
            throw commandPOSIXError(errno, operation: "create command \(label) capture")
        }
        descriptor = opened
        _ = template.withUnsafeBufferPointer { buffer in
            Darwin.unlink(buffer.baseAddress!)
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func data() -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else { return Data() }
        return readCommandDescriptor(descriptor)
    }

    func byteCount() -> Int64 {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return 0 }
        return status.st_size
    }
}

private final class CommandPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var readFileDescriptor: Int32
    private var writeFileDescriptor: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        let status = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard status == 0 else {
            throw commandPOSIXError(errno, operation: "create command pipe")
        }
        readFileDescriptor = descriptors[0]
        writeFileDescriptor = descriptors[1]
        _ = fcntl(readFileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFileDescriptor, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        closeRead()
        closeWrite()
    }

    var readDescriptor: Int32 { lock.withLock { readFileDescriptor } }
    var writeDescriptor: Int32 { lock.withLock { writeFileDescriptor } }

    func takeRead() -> Int32 {
        lock.withLock {
            let descriptor = readFileDescriptor
            readFileDescriptor = -1
            return descriptor
        }
    }

    func takeWrite() -> Int32 {
        lock.withLock {
            let descriptor = writeFileDescriptor
            writeFileDescriptor = -1
            return descriptor
        }
    }

    func closeRead() {
        let descriptor = takeRead()
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    func closeWrite() {
        let descriptor = takeWrite()
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }
}

private final class CStringArray {
    private var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers.dropLast() {
            if let pointer { free(pointer) }
        }
    }

    func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private func addSpawnAction(_ status: Int32, operation: String) throws {
    guard status == 0 else { throw commandPOSIXError(status, operation: operation) }
}

private func commandPOSIXError(_ status: Int32, operation: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(status)))"]
    )
}

private func readCommandDescriptor(_ descriptor: Int32) -> Data {
    guard descriptor >= 0 else { return Data() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            data.append(buffer, count: Int(count))
        } else if count == 0 {
            return data
        } else if errno != EINTR {
            return data
        }
    }
}

private func writeCommandPipe(_ descriptor: Int32, data: Data) {
    guard descriptor >= 0 else { return }
    defer { _ = Darwin.close(descriptor) }
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    data.withUnsafeBytes { bytes in
        guard let start = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

private func waitForCapturedOutput(
    stdout: CommandCaptureFile,
    stderr: CommandCaptureFile,
    timeout: TimeInterval
) {
    guard stdout.byteCount() == 0, stderr.byteCount() == 0 else { return }
    let deadline = DispatchTime.now().uptimeNanoseconds
        &+ UInt64(max(0, timeout) * 1_000_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        usleep(5_000)
        if stdout.byteCount() > 0 || stderr.byteCount() > 0 { return }
    }
}

private func waitForCommand(
    _ processIdentifier: pid_t,
    timeout: TimeInterval
) -> (status: Int32, timedOut: Bool, reason: String) {
    let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
    var status = Int32()
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier { return (status, false, "reaped") }
        if result < 0, errno != EINTR { return (status, false, "wait-error-\(errno)") }
        usleep(10_000)
    }

    _ = kill(processIdentifier, SIGTERM)
    let terminationDeadline = DispatchTime.now().uptimeNanoseconds &+ 1_000_000_000
    while DispatchTime.now().uptimeNanoseconds < terminationDeadline {
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier { return (status, true, "terminated-after-timeout") }
        if result < 0, errno != EINTR { return (status, true, "timeout-wait-error-\(errno)") }
        usleep(10_000)
    }
    _ = kill(processIdentifier, SIGKILL)
    while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
    return (status, true, "killed-after-timeout")
}

private func commandExitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal == 0 { return (status >> 8) & 0xff }
    if signal == 0x7f { return 1 }
    return 128 + signal
}

public enum EnvironmentResolver {
    public static let fallbackUTF8Locale = "C.UTF-8"

    /// Gives GUI-launched command-line tools a UTF-8 character locale without
    /// replacing a locale the user deliberately supplied. Finder and other
    /// Launch Services entry points commonly omit all three effective locale
    /// variables even though the same tools receive one from Terminal.
    public static func applyingUTF8LocaleFallback(
        to environment: [String: String]
    ) -> [String: String] {
        let hasExplicitCharacterLocale = ["LC_ALL", "LC_CTYPE", "LANG"].contains { key in
            environment[key]?.isEmpty == false
        }
        guard !hasExplicitCharacterLocale else { return environment }

        var resolved = environment
        resolved["LANG"] = fallbackUTF8Locale
        return resolved
    }

    /// Resolves the login PATH for a GUI-launched app.
    ///
    /// This is a narrow exception to argv-only process execution: a fixed
    /// command with no interpolated content, sentinel-delimited output and an
    /// absolute shell path. Agent commands still reach the terminal as argv
    /// arrays and never through a shell.
    public static func resolved() -> [String: String] {
        var environment = applyingUTF8LocaleFallback(to: ProcessInfo.processInfo.environment)
        let runner = ProcessCommandRunner(timeout: 5)
        let marker = "__PARLEY_PATH__"
        let command = "printf '\n__PARLEY_PATH__%s__PARLEY_PATH__\n' \"$PATH\""

        if let output = try? runner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", command],
            environment: environment,
            input: nil
        ), output.status == 0 {
            let text = output.stdoutText
            if let start = text.range(of: marker),
               let end = text.range(of: marker, range: start.upperBound..<text.endIndex) {
                let path = String(text[start.upperBound..<end.lowerBound])
                if !path.isEmpty { environment["PATH"] = path }
            }
        }

        return environment
    }
}
