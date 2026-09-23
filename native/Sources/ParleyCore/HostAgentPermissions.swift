import Foundation

/// Host CLIs are trusted local applications. These rules constrain Codex tool
/// commands through Codex itself; they do not sandbox its parent or integrations.
public struct HostAgentPermissions: Sendable {
    public static let disclosure = "Host agents run as your account using the vendor’s permissions. Parley adds no outer sandbox. An unrestricted host process can read local records and other panes’ credentials; attribution is not an isolation guarantee. Use a reviewed container for stronger separation."
    public let filesystem: [String: String]
    public let workspaceRoots: [String]
    public let writable: Bool
    public let profileName: String
    /// Who answers Codex's escalation prompts. The vendor reviewer is Codex's
    /// own auto review inside the same sandbox; it is not a bypass.
    public let approvals: PermissionApprovalHandling
    /// Whether the profile allows network access. Codex's built-in `:workspace`
    /// and `:read-only` profiles have no network, so an allowing profile has
    /// to say so in the table or Codex refuses every network command and the
    /// review's "Allowed by profile" would be false.
    public let networkAllowed: Bool

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
        // Explicitly allow the shim's pre-connect stat of this exact socket,
        // even when its parent transport directory is denied.
        add(RelayTicketServer.socketURL(transportDirectory: transportDirectory), "read")
        filesystem = rules
        workspaceRoots = profile.approvedRoots.sorted()
        writable = profile.definition.rule(for: .projectWrite) == .allow
        self.profileName = profileName
        approvals = profile.approvals
        networkAllowed = profile.definition.rule(for: .networkAccess) == .allow
    }

    /// One TOML table override: quoted path fragments in dotted CLI keys are
    /// not parsed as TOML keys by Codex. Keep all paths literal inside the value.
    public var configurationArguments: [String] {
        let files = filesystem.sorted { $0.key < $1.key }.map { "\(literal($0.key))=\(literal($0.value))" }.joined(separator: ",")
        let roots = workspaceRoots.map { "\(literal($0))=true" }.joined(separator: ",")
        let network = networkAllowed ? ",network={enabled=true}" : ""
        let table = "{extends=\(literal(writable ? ":workspace" : ":read-only")),workspace_roots={\(roots)},filesystem={\(files)}\(network)}"
        return ["-c", "permissions.\(profileName)=\(table)", "-c", "default_permissions=\(literal(profileName))"]
    }

    /// The host Codex launch takes these, not the generic launch plan, so the
    /// approvals choice has to be carried here or it never reaches Codex.
    public var launchArguments: [String] {
        configurationArguments + ["--ask-for-approval", "on-request"]
            + (approvals == .vendorReviewer ? ["-c", "approvals_reviewer=auto_review"] : [])
    }

    private func literal(_ value: String) -> String { TOMLString.basic(value) }

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
        let privateHeld = (try? Data(contentsOf: privateFile)) == Data("private probe".utf8)
        let endpointWritten = (try? Data(contentsOf: endpointFile)) == Data("checked".utf8)
        guard output.status == 0, privateHeld, endpointWritten else {
            throw PermissionProfileError.invalid(failureMessage(
                status: output.status, privateHeld: privateHeld, endpointWritten: endpointWritten,
                stderr: output.stderrText, diagnostic: output.diagnostic))
        }
    }

    /// The configuration query already ran and accepted the applicable
    /// settings, so this never blames legacy sandbox keys it has just cleared.
    /// It names what was actually observed instead.
    public static func failureMessage(status: Int32, privateHeld: Bool, endpointWritten: Bool,
                               stderr: String, diagnostic: String?) -> String {
        let cause: String
        switch status {
        case CommandExitStatus.timedOut:
            cause = "Codex did not finish the sandbox probe before Parley’s timeout. Nothing indicates your Codex configuration is wrong: the configuration query just before this accepted it."
        case CommandExitStatus.unobserved:
            cause = "Parley could not observe the sandbox probe’s exit, so its result is unknown. This is a Parley fault, not a Codex configuration problem."
        case 80:
            cause = "The sandbox refused to run an ordinary command."
        case 81, 82:
            cause = "The sandbox ran but did not deny Parley’s private files, so the permission rules were not applied as written."
        case 83, 84:
            cause = "The sandbox ran but denied this pane’s own relay endpoint, which it must be able to read and write."
        default:
            cause = privateHeld && endpointWritten
                ? "Codex reported a sandbox failure."
                : "The sandbox ran but its filesystem rules did not hold."
        }
        var message = "Codex’s host tool preflight failed (exit \(status)). \(cause) Parley changed no vendor settings."
        if let diagnostic { message += " [\(diagnostic)]" }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { message += " \(String(trimmed.prefix(1200)))" }
        return message
    }
}
