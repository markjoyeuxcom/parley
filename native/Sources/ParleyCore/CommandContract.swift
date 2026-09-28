import Foundation

/// What running a command means, separated from how any one operating system
/// does it.
///
/// This file carries no platform import on purpose. It is the first slice of
/// ParleyCore's domain vocabulary lifted out of a file that needs Darwin, so
/// the contract a caller depends on is not tied to the spawn implementation
/// behind it. Interpreting an OS wait status stays with the implementation;
/// what belongs here is the vocabulary every runner must honour.

public struct CommandOutput: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public let diagnostic: String?
    /// The signal that ended the process, when one did; `status` is then the
    /// shell's 128 + N. Nil for a normal exit or when not recorded.
    public let terminationSignal: Int32?

    public init(
        stdout: Data = Data(),
        stderr: Data = Data(),
        status: Int32 = 0,
        diagnostic: String? = nil,
        terminationSignal: Int32? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.diagnostic = diagnostic
        self.terminationSignal = terminationSignal
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

/// How a spawned command's exit was actually observed.
///
/// `unobserved` means the child was reaped by something else in this process,
/// so no exit status of ours exists. That is not success and must never be
/// reported as one: a caller checking `status == 0` would otherwise treat a
/// command it never saw finish as a clean run.
public enum CommandWaitOutcome: Equatable, Sendable {
    case reaped
    case timedOut
    case unobserved
}

/// The status a caller sees, given how the exit was observed.
///
/// A runner decides the outcome and, when it reaped the child, supplies the
/// exit status it read. Turning an operating system's wait encoding into that
/// number is the runner's job, not this contract's: the two reserved codes
/// below are the only values this file knows how to produce itself.
public enum CommandExitStatus {
    /// The deadline passed and the child was signalled. Matches timeout(1).
    public static let timedOut: Int32 = 124
    /// The wait itself failed, so no exit status was observed.
    public static let unobserved: Int32 = 125

    public static func resolve(outcome: CommandWaitOutcome, exitStatus: Int32) -> Int32 {
        switch outcome {
        case .reaped: return exitStatus
        case .timedOut: return timedOut
        case .unobserved: return unobserved
        }
    }
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
