import Darwin
import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), status: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
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
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()
        let output = LockedData()
        let errors = LockedData()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        let stdin = input.map { data -> Pipe in
            let pipe = Pipe()
            process.standardInput = pipe
            return pipe
        }

        process.terminationHandler = { _ in finished.signal() }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.set(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            readers.wait()
            throw error
        }
        if let input, let stdin {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }

        let deadline = DispatchTime.now() + timeout
        let timedOut = finished.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        process.waitUntilExit()
        readers.wait()

        var errorData = errors.value
        if timedOut {
            if !errorData.isEmpty { errorData.append(Data("\n".utf8)) }
            errorData.append(Data("Command timed out after \(timeout) seconds".utf8))
        }
        return CommandOutput(
            stdout: output.value,
            stderr: errorData,
            status: timedOut ? 124 : process.terminationStatus
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.withLock { storage }
    }

    func set(_ data: Data) {
        lock.withLock { storage = data }
    }
}

public enum EnvironmentResolver {
    /// Resolves the login PATH for a GUI-launched app.
    ///
    /// This is a narrow exception to argv-only process execution: a fixed
    /// command with no interpolated content, sentinel-delimited output and an
    /// absolute shell path. Agent commands still reach tmux as argv arrays and
    /// never through a shell.
    public static func resolved() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
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
