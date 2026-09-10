import Foundation

/// Host CLIs are trusted local applications. These rules constrain Codex tool
/// commands through Codex itself; they do not sandbox its parent or integrations.
public struct HostAgentPermissions: Sendable {
    public static let disclosure = "Host agents run as your account using the vendor’s permissions. Parley adds no outer sandbox. An unrestricted host process can read local records and other panes’ credentials; attribution is not an isolation guarantee. Use a reviewed container for stronger separation."
    public let filesystem: [String: String]
    public let workspaceRoots: [String]
    public let writable: Bool
    public let profileName: String

    public init(applicationDirectory: URL, protocolDirectory: URL, shimDirectory: URL,
                transportDirectory: URL, endpointDirectory: URL, profile: EffectivePermissionProfile,
                profileName: String = "parley_host") {
        var rules: [String: String] = [:]
        let applications = [applicationDirectory] + ParleyRuntime.controlDirectories()
        let transports = [transportDirectory] + applications.map { RelayFileTransport.runtimeDirectory(applicationDirectory: $0) }
        func add(_ path: URL, _ access: String) {
            rules[path.path] = access
            rules[path.resolvingSymlinksInPath().path] = access
        }
        for directory in applications + transports { add(directory, "deny") }
        add(protocolDirectory, "read")
        add(shimDirectory, "read")
        add(endpointDirectory, "write")
        filesystem = rules
        workspaceRoots = profile.approvedRoots.sorted()
        writable = profile.definition.rule(for: .projectWrite) == .allow
        self.profileName = profileName
    }

    /// One TOML table override: quoted path fragments in dotted CLI keys are
    /// not parsed as TOML keys by Codex. Keep all paths literal inside the value.
    public var configurationArguments: [String] {
        let files = filesystem.sorted { $0.key < $1.key }.map { "\(literal($0.key))=\(literal($0.value))" }.joined(separator: ",")
        let roots = workspaceRoots.map { "\(literal($0))=true" }.joined(separator: ",")
        let table = "{extends=\(literal(writable ? ":workspace" : ":read-only")),workspace_roots={\(roots)},filesystem={\(files)}}"
        return ["-c", "permissions.\(profileName)=\(table)", "-c", "default_permissions=\(literal(profileName))"]
    }

    public var launchArguments: [String] {
        configurationArguments + ["--ask-for-approval", "on-request"]
    }

    private func literal(_ value: String) -> String {
        // JSON basic-string escaping is valid for these TOML keys and values.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    /// Run away from the main actor. The synthetic private file contains no
    /// credential. No model, login, project mutation or permission bypass occurs.
    public static func preflight(applicationDirectory: URL, protocolDirectory: URL, shimDirectory: URL,
                                 transportDirectory: URL, folder: String, profile: EffectivePermissionProfile,
                                 environment: [String: String], runner: any CommandRunning = ProcessCommandRunner(timeout: 20)) throws {
        guard let executable = environment["PATH", default: "/usr/bin:/bin"].split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw PermissionProfileError.invalid("Codex is not installed on the resolved host PATH.")
        }
        let root = applicationDirectory.appendingPathComponent("host-preflights").appendingPathComponent(UUID().uuidString)
        let endpoint = root.appendingPathComponent("own-endpoint")
        try FileManager.default.createDirectory(at: endpoint, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let privateFile = root.appendingPathComponent("private-probe")
        let endpointFile = endpoint.appendingPathComponent("probe")
        try Data("private probe".utf8).write(to: privateFile)
        try Data("endpoint probe".utf8).write(to: endpointFile)
        let permissions = Self(applicationDirectory: applicationDirectory, protocolDirectory: protocolDirectory,
            shimDirectory: shimDirectory, transportDirectory: transportDirectory, endpointDirectory: endpoint, profile: profile)
        let script = """
        /usr/bin/true || exit 80
        if /bin/cat "$1" >/dev/null 2>&1; then exit 81; fi
        if (printf changed >"$1") 2>/dev/null; then exit 82; fi
        /bin/cat "$2" >/dev/null || exit 83
        printf checked >"$2" || exit 84
        """
        try CodexHostConfiguration.verify(executable: executable, arguments: permissions.configurationArguments,
            environment: environment, folder: folder, profileName: permissions.profileName)
        let output = try runner.run(executable: executable,
            arguments: ["sandbox", "-P", permissions.profileName, "-C", folder] + permissions.configurationArguments
                + ["--", "/bin/sh", "-c", script, "parley-host-preflight", privateFile.path, endpointFile.path],
            environment: environment, input: nil)
        guard output.status == 0,
              (try? Data(contentsOf: privateFile)) == Data("private probe".utf8),
              (try? Data(contentsOf: endpointFile)) == Data("checked".utf8) else {
            throw PermissionProfileError.invalid("Codex’s host tool preflight failed (exit \(output.status)). The native sandbox must run, deny Parley private files and allow its own endpoint. Check Codex’s permission configuration: legacy sandbox_mode or sandbox_workspace_write settings can override default_permissions. Parley changed no vendor settings. \(String(output.stderrText.prefix(1200)))")
        }
    }
}
