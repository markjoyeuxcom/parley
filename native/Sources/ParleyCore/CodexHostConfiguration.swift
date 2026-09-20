import Darwin
import Foundation

/// A bounded, transient stdio config query. This never opens a thread, runs a
/// model, changes vendor configuration, or connects to a vendor daemon.
public enum CodexHostConfiguration {
    /// Reads Codex's resolved configuration for one folder through a transient
    /// `codex app-server --stdio`. Config replies may include private
    /// settings: callers read the keys they need and never log the reply.
    public static func read(executable: URL, arguments: [String], environment: [String: String], folder: String,
                            timeout: TimeInterval = 15) throws -> [String: Any] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"] + arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Config replies may include private settings. Never surface the raw reply or logs.
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting.fileDescriptor
        let reader = output.fileHandleForReading.fileDescriptor
        guard fcntl(writer, F_SETNOSIGPIPE, 1) == 0,
              fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK) == 0 else {
            throw PermissionProfileError.invalid("Could not prepare the Codex configuration check.")
        }
        try process.run()
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, timeout) * 1_000_000_000)
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            // Foundation owns reaping. Neither an unreapable child nor a
            // descendant holding stdout may extend this configuration query.
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            let cleanupDeadline = DispatchTime.now().uptimeNanoseconds &+ BoundedReap.bound
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < cleanupDeadline { usleep(5_000) }
        }
        var buffer = Data()
        var total = 0
        func requireTime() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw PermissionProfileError.invalid("Codex did not return a bounded configuration reply before the check timed out.")
            }
        }
        func send(_ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object)
            bytes.append(0x0a)
            try bytes.withUnsafeBytes { contents in
                var offset = 0
                while offset < contents.count {
                    try requireTime()
                    let count = Darwin.write(writer, contents.baseAddress!.advanced(by: offset), contents.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EINTR || errno == EAGAIN) { usleep(5_000) }
                    else { throw PermissionProfileError.invalid("Codex closed the read-only configuration check.") }
                }
            }
        }
        func response(id: Int) throws -> [String: Any] {
            while true {
                try requireTime()
                if let newline = buffer.firstIndex(of: 0x0a) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if object["id"] as? Int == id {
                        guard let result = object["result"] as? [String: Any] else {
                            throw PermissionProfileError.invalid("Codex refused the read-only configuration check.")
                        }
                        return result
                    }
                } else {
                    var bytes = [UInt8](repeating: 0, count: 8_192)
                    let count = Darwin.read(reader, &bytes, bytes.count)
                    if count < 0 && (errno == EINTR || errno == EAGAIN) { usleep(5_000); continue }
                    total += max(0, count)
                    guard count > 0, total <= 200_000 else {
                        throw PermissionProfileError.invalid("Codex did not return a bounded configuration reply before the check ended.")
                    }
                    buffer.append(contentsOf: bytes.prefix(count))
                }
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "parley-host-preflight", "version": AgentProtocol.version]]])
        _ = try response(id: 1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "config/read", "params": ["includeLayers": false, "cwd": folder]])
        let reply = try response(id: 2)
        guard let config = reply["config"] as? [String: Any] else {
            throw PermissionProfileError.invalid("Codex returned no configuration for the folder.")
        }
        return config
    }

    static func verify(executable: URL, arguments: [String], environment: [String: String], folder: String, profileName: String) throws {
        let config = try read(executable: executable, arguments: arguments, environment: environment, folder: folder)
        guard config["default_permissions"] as? String == profileName,
              config["sandbox_mode"] == nil || config["sandbox_mode"] is NSNull,
              config["sandbox_workspace_write"] == nil || config["sandbox_workspace_write"] is NSNull else {
            throw PermissionProfileError.invalid("Codex’s configuration conflicts with Parley’s native permission profile. Remove legacy sandbox_mode and sandbox_workspace_write settings from the applicable vendor configuration before starting this host pane. Parley changed no vendor settings.")
        }
    }

    /// The person's own `approvals_reviewer` setting for this folder, or nil
    /// when Codex resolves none. `auto_review` means Codex sends sandbox
    /// escalations to its automatic reviewer and shows no prompt, whatever
    /// the person chooses in Parley's review; the review states that.
    static func approvalsReviewer(executable: URL, environment: [String: String], folder: String) throws -> String? {
        let config = try read(executable: executable, arguments: [], environment: environment, folder: folder)
        guard let value = config["approvals_reviewer"], !(value is NSNull) else { return nil }
        return value as? String ?? String(describing: value)
    }
}
