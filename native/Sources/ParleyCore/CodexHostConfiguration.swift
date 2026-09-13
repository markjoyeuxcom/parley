import Darwin
import Foundation

/// A bounded, transient stdio config query. This never opens a thread, runs a
/// model, changes vendor configuration, or connects to a vendor daemon.
enum CodexHostConfiguration {
    /// Reads Codex's resolved configuration for one folder through a transient
    /// `codex app-server --stdio`. Config replies may include private
    /// settings: callers read the keys they need and never log the reply.
    static func read(executable: URL, arguments: [String], environment: [String: String], folder: String) throws -> [String: Any] {
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
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw PermissionProfileError.invalid("Could not prepare the Codex configuration check.")
        }
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: deadline)
        defer {
            try? input.fileHandleForWriting.close()
            // EOF ends this stdio server; the deadline also bounds cleanup.
            process.waitUntilExit()
            deadline.cancel()
            try? output.fileHandleForReading.close()
        }
        var buffer = Data()
        var total = 0
        func send(_ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object)
            bytes.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        func response(id: Int) throws -> [String: Any] {
            while true {
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
                    let bytes = output.fileHandleForReading.availableData
                    total += bytes.count
                    guard !bytes.isEmpty, total <= 200_000 else {
                        throw PermissionProfileError.invalid("Codex did not return a bounded configuration reply before the check ended.")
                    }
                    buffer.append(bytes)
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
