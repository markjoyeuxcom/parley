import Foundation

public final class TmuxController {
    public let tmuxExecutable: URL
    public let socketPath: URL
    public let configPath: URL
    public let applicationDirectory: URL
    public let protocolDirectory: URL
    public let sessionName: String
    public let environment: [String: String]

    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let pause: (TimeInterval) -> Void
    private var relayRuntime: RelayRuntime?

    public init(
        tmuxExecutable: URL? = nil,
        applicationDirectory: URL? = nil,
        sessionName: String = "parley",
        environment: [String: String]? = nil,
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        let resolvedEnvironment = environment ?? EnvironmentResolver.resolved()
        guard let executable = tmuxExecutable ?? Self.findTmux(environment: resolvedEnvironment, fileManager: fileManager) else {
            throw ParleyTmuxError.tmuxNotFound
        }

        let directory = applicationDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)

        self.tmuxExecutable = executable
        self.applicationDirectory = directory
        self.socketPath = directory.appendingPathComponent("tmux.sock")
        self.configPath = directory.appendingPathComponent("tmux.conf")
        self.sessionName = sessionName
        self.environment = resolvedEnvironment
        self.runner = runner
        self.fileManager = fileManager
        self.pause = pause

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        protocolDirectory = try AgentProtocol.install(in: directory, fileManager: fileManager)
        try writeConfiguration()
    }

    public func configureRelay(_ runtime: RelayRuntime) {
        relayRuntime = runtime
    }

    public static func findTmux(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        if let override = environment["PARLEY_TMUX"], override.hasPrefix("/") {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }

        let candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("tmux") }
            + [
                URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
                URL(fileURLWithPath: "/usr/local/bin/tmux"),
                URL(fileURLWithPath: "/usr/bin/tmux"),
            ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func bootstrap(cwd: String) throws {
        try requireDirectory(cwd)
        let hasSession = try runTmux(["has-session", "-t", exactSession], allowFailure: true).status == 0
        if hasSession {
            // Migration is metadata-only. Existing panes and the processes
            // inside them are deliberately left untouched.
            for workspace in try listWorkspaces(fallbackFolder: cwd) {
                try setWorkspaceMetadata(
                    windowID: workspace.id,
                    name: workspace.name,
                    folder: workspace.defaultFolder
                )
            }
            return
        }

        let result = try runTmux([
            "new-session", "-d", "-P", "-F", "#{window_id}\u{1f}#{pane_id}",
            "-s", sessionName, "-c", cwd, "-n", "agents",
        ])
        let identifiers = result.stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        if identifiers.count == 2 {
            let windowID = identifiers[0]
            let paneID = identifiers[1]
            try setMetadata(paneID: paneID, kind: .shell, name: "Shell")
            try setWorkspaceMetadata(
                windowID: windowID,
                name: workspaceName(folder: cwd),
                folder: cwd
            )
        }
    }

    public func attachArguments() -> [String] {
        ["-S", socketPath.path, "-f", configPath.path, "attach-session", "-t", exactSession]
    }

    public func listPanes() throws -> [TmuxPane] {
        let separator = "\u{1f}"
        let format = [
            "#{pane_id}",
            "#{@parley-kind}",
            "#{@parley-name}",
            "#{pane_title}",
            "#{pane_current_path}",
            "#{pane_current_command}",
            "#{pane_active}",
            "#{window_id}",
            "#{@parley-return-to}",
            "#{@parley-relay}",
            "#{@parley-protocol}",
            "#{window_active}",
            "#{@parley-workspace-name}",
        ].joined(separator: separator)
        let output = try runTmux(["list-panes", "-s", "-t", exactSession, "-F", format]).stdoutText

        return output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 13, let kind = PaneKind(rawValue: fields[1]) else { return nil }
            return TmuxPane(
                id: fields[0],
                kind: kind,
                customName: fields[2].isEmpty ? nil : fields[2],
                terminalTitle: fields[3],
                cwd: fields[4],
                currentCommand: fields[5],
                isActive: fields[6] == "1" && fields[11] == "1",
                windowID: fields[7],
                returnToPaneID: fields[8].isEmpty ? nil : fields[8],
                relayEnabled: fields[9] == "1",
                protocolVersion: fields[10].isEmpty ? nil : fields[10],
                workspaceName: fields[12].isEmpty ? nil : fields[12]
            )
        }
    }

    public func listWorkspaces() throws -> [TmuxWorkspace] {
        try listWorkspaces(fallbackFolder: nil)
    }

    @discardableResult
    public func createWorkspace(folder: String, name: String? = nil) throws -> TmuxWorkspace {
        try requireDirectory(folder)
        let resolvedName = workspaceName(folder: folder, proposed: name)
        let result = try runTmux([
            "new-window", "-d", "-P", "-F", "#{window_id}\u{1f}#{pane_id}",
            "-t", "\(exactSession):", "-c", folder, "-n", resolvedName,
        ])
        let identifiers = result.stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map(String.init)
        guard identifiers.count == 2, !identifiers[0].isEmpty, !identifiers[1].isEmpty else {
            throw ParleyTmuxError.commandFailed("tmux did not return the new workspace ids")
        }
        let windowID = identifiers[0]
        let paneID = identifiers[1]
        do {
            try setMetadata(paneID: paneID, kind: .shell, name: "Shell")
            try setWorkspaceMetadata(windowID: windowID, name: resolvedName, folder: folder)
            try selectWorkspace(windowID)
        } catch {
            _ = try? runTmux(["kill-window", "-t", windowID], allowFailure: true)
            throw error
        }
        return TmuxWorkspace(id: windowID, name: resolvedName, defaultFolder: folder, isActive: true)
    }

    public func selectWorkspace(_ windowID: String) throws {
        _ = try runTmux(["select-window", "-t", windowID])
    }

    public func renameWorkspace(_ windowID: String, name: String) throws {
        guard try listWorkspaces().contains(where: { $0.id == windowID }) else {
            throw ParleyTmuxError.workspaceNotFound(windowID)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParleyTmuxError.commandFailed("Workspace names cannot be empty.")
        }
        _ = try runTmux(["rename-window", "-t", windowID, trimmed])
        _ = try runTmux(["set-option", "-w", "-t", windowID, "@parley-workspace-name", trimmed])
    }

    public func setWorkspaceFolder(_ windowID: String, folder: String) throws {
        try requireDirectory(folder)
        guard try listWorkspaces().contains(where: { $0.id == windowID }) else {
            throw ParleyTmuxError.workspaceNotFound(windowID)
        }
        _ = try runTmux(["set-option", "-w", "-t", windowID, "@parley-workspace-folder", folder])
    }

    public func closeWorkspace(_ windowID: String) throws {
        let workspaces = try listWorkspaces()
        guard workspaces.contains(where: { $0.id == windowID }) else {
            throw ParleyTmuxError.workspaceNotFound(windowID)
        }
        guard workspaces.count > 1 else { throw ParleyTmuxError.cannotCloseLastWorkspace }
        let paneIDs = try listPanes().filter { $0.windowID == windowID }.map(\.id)
        _ = try runTmux(["kill-window", "-t", windowID])
        for paneID in paneIDs {
            try relayRuntime?.credentials.forget(paneID)
        }
    }

    public func activePane() throws -> TmuxPane? {
        try listPanes().first(where: \.isActive)
    }

    @discardableResult
    public func createPane(kind: PaneKind, cwd: String, direction: SplitDirection) throws -> TmuxPane {
        try requireDirectory(cwd)
        guard let target = try activePane() else { throw ParleyTmuxError.paneNotFound("active") }

        let arguments = [
            "split-window", "-d", "-P", "-F", "#{pane_id}",
            direction == .horizontal ? "-h" : "-v", "-t", target.id,
            "-c", cwd, "/bin/sleep", "30",
        ]

        let paneID = try runTmux(arguments).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneID.isEmpty else { throw ParleyTmuxError.commandFailed("tmux did not return the new pane id") }
        do {
            try setMetadata(paneID: paneID, kind: kind, name: kind.label)
            _ = try runTmux(try respawnArguments(paneID: paneID, kind: kind, cwd: cwd))
            try setRelayMetadata(paneID: paneID, enabled: kind.isAgent && relayRuntime != nil)
            try setProtocolMetadata(paneID: paneID, kind: kind)
            try selectPane(paneID)
        } catch {
            _ = try? runTmux(["kill-pane", "-t", paneID], allowFailure: true)
            try? relayRuntime?.credentials.forget(paneID)
            throw error
        }
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        return pane
    }

    public func selectPane(_ paneID: String) throws {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        _ = try runTmux(["select-window", "-t", pane.windowID])
        _ = try runTmux(["select-pane", "-t", paneID])
    }

    public func renamePane(_ paneID: String, name: String) throws {
        guard try listPanes().contains(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-name", trimmed])
        _ = try runTmux(["select-pane", "-t", paneID, "-T", trimmed])
    }

    public func restartPane(_ paneID: String) throws {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        _ = try runTmux(try respawnArguments(paneID: paneID, kind: pane.kind, cwd: pane.cwd))
        try setRelayMetadata(paneID: paneID, enabled: pane.kind.isAgent && relayRuntime != nil)
        try setProtocolMetadata(paneID: paneID, kind: pane.kind)
    }

    public func closePane(_ paneID: String) throws {
        let panes = try listPanes()
        guard panes.contains(where: { $0.id == paneID }) else { throw ParleyTmuxError.paneNotFound(paneID) }
        guard panes.count > 1 else { throw ParleyTmuxError.cannotCloseLastPane }
        _ = try runTmux(["kill-pane", "-t", paneID])
        try relayRuntime?.credentials.forget(paneID)
    }

    public func zoomActivePane() throws {
        guard let pane = try activePane() else { throw ParleyTmuxError.paneNotFound("active") }
        _ = try runTmux(["resize-pane", "-Z", "-t", pane.id])
    }

    public func balancePanes() throws {
        guard let pane = try activePane() else { throw ParleyTmuxError.paneNotFound("active") }
        _ = try runTmux(["select-layout", "-t", pane.windowID, "tiled"])
    }

    public func capturePane(_ paneID: String) throws -> String {
        guard try listPanes().contains(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        // Visible screen only. History is never inserted implicitly into an
        // Ask/Return editor; the person explicitly requests this capture.
        let output = try runTmux(["capture-pane", "-p", "-J", "-t", paneID]).stdoutText
        return RelayText.clean(output)
    }

    public func ask(from requesterID: String, to consultantID: String, text: String? = nil) throws {
        let panes = try listPanes()
        guard let requester = panes.first(where: { $0.id == requesterID }) else {
            throw ParleyTmuxError.paneNotFound(requesterID)
        }
        guard let consultant = panes.first(where: { $0.id == consultantID }) else {
            throw ParleyTmuxError.paneNotFound(consultantID)
        }
        guard requester.kind.isAgent, consultant.kind.isAgent else { throw ParleyTmuxError.notAgentPane }
        guard requester.kind != consultant.kind else { throw ParleyTmuxError.sameVendor }

        let captured = if let text { text } else { try capturePane(requesterID) }
        let body = RelayText.clean(captured)
        guard !body.isEmpty else { throw ParleyTmuxError.noRelayText }
        try paste("\(requester.displayName) asked:\n\n\(body)", into: consultantID, submit: true)
        _ = try runTmux(["set-option", "-p", "-t", consultantID, "@parley-return-to", requesterID])
        try selectPane(consultantID)
    }

    public func returnAnswer(from consultantID: String, text: String? = nil) throws {
        let panes = try listPanes()
        guard let consultant = panes.first(where: { $0.id == consultantID }) else {
            throw ParleyTmuxError.paneNotFound(consultantID)
        }
        guard let requesterID = consultant.returnToPaneID else { throw ParleyTmuxError.noReturnRoute }
        guard let requester = panes.first(where: { $0.id == requesterID }) else {
            throw ParleyTmuxError.paneNotFound(requesterID)
        }

        let captured = if let text { text } else { try capturePane(consultantID) }
        let body = RelayText.clean(captured)
        guard !body.isEmpty else { throw ParleyTmuxError.noRelayText }
        try paste("\(consultant.displayName) answered:\n\n\(body)", into: requester.id, submit: true)
        _ = try runTmux(["set-option", "-p", "-u", "-t", consultantID, "@parley-return-to"])
        try selectPane(requester.id)
    }

    public func paste(_ text: String, into paneID: String, submit: Bool) throws {
        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else { throw ParleyTmuxError.noRelayText }
        let submitKey: String?
        var submitDelay: TimeInterval = 0
        var restorePaneID: String?
        defer {
            if let restorePaneID {
                pause(0.1)
                try? selectPane(restorePaneID)
            }
        }
        if submit {
            let panes = try listPanes()
            guard let pane = panes.first(where: { $0.id == paneID }) else {
                throw ParleyTmuxError.paneNotFound(paneID)
            }
            // Copilot must make the folder-trust decision before input is sent.
            // Once trusted, Enter starts the turn; C-q merely queues the prompt
            // and can leave an idle consultation waiting for a person.
            if pane.kind == .copilot {
                let visible = try capturePane(paneID)
                if visible.localizedCaseInsensitiveContains("Confirm folder trust")
                    || visible.localizedCaseInsensitiveContains("Do you trust the files in this folder?") {
                    throw ParleyTmuxError.copilotTrustRequired
                }
                // Copilot deliberately ignores keyboard events after tmux has
                // sent focus-out. Bracketed paste still lands, which makes this
                // look like a broken Enter. Briefly focus the target, submit,
                // then put the person back in whichever pane they were using.
                if let active = panes.first(where: \.isActive), active.id != paneID {
                    try selectPane(paneID)
                    restorePaneID = active.id
                    pause(0.1)
                }
                submitKey = "Enter"
                submitDelay = 0.25
            } else {
                submitKey = "Enter"
            }
        } else {
            submitKey = nil
        }
        let buffer = "parley-\(UUID().uuidString.lowercased())"
        _ = try runTmux(["load-buffer", "-b", buffer, "-"], input: Data(cleaned.utf8))
        do {
            // -p asks tmux to wrap the body in bracketed-paste markers only
            // when the receiving CLI requested them; -r preserves newlines.
            _ = try runTmux(["paste-buffer", "-d", "-p", "-r", "-b", buffer, "-t", paneID])
        } catch {
            _ = try? runTmux(["delete-buffer", "-b", buffer], allowFailure: true)
            throw error
        }
        if let submitKey {
            if submitDelay > 0 { pause(submitDelay) }
            _ = try runTmux(["send-keys", "-t", paneID, submitKey])
        }
    }

    private var exactSession: String { "=\(sessionName)" }

    private func listWorkspaces(fallbackFolder: String?) throws -> [TmuxWorkspace] {
        let separator = "\u{1f}"
        let format = [
            "#{window_id}",
            "#{window_name}",
            "#{window_active}",
            "#{@parley-workspace-name}",
            "#{@parley-workspace-folder}",
            "#{pane_current_path}",
        ].joined(separator: separator)
        let output = try runTmux(["list-windows", "-t", exactSession, "-F", format]).stdoutText
        return output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6 else { return nil }
            let folder = !fields[4].isEmpty
                ? fields[4]
                : (!fields[5].isEmpty ? fields[5] : (fallbackFolder ?? "/"))
            let name = !fields[3].isEmpty
                ? fields[3]
                : workspaceName(folder: folder, proposed: fields[1] == "agents" ? nil : fields[1])
            return TmuxWorkspace(id: fields[0], name: name, defaultFolder: folder, isActive: fields[2] == "1")
        }
    }

    private func workspaceName(folder: String, proposed: String? = nil) -> String {
        let trimmed = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let component = URL(fileURLWithPath: folder).standardizedFileURL.lastPathComponent
        return component.isEmpty ? "Workspace" : component
    }

    private func setWorkspaceMetadata(windowID: String, name: String, folder: String) throws {
        _ = try runTmux(["set-option", "-w", "-t", windowID, "@parley-workspace-name", name])
        _ = try runTmux(["set-option", "-w", "-t", windowID, "@parley-workspace-folder", folder])
        _ = try runTmux(["rename-window", "-t", windowID, name])
    }

    private func respawnArguments(paneID: String, kind: PaneKind, cwd: String) throws -> [String] {
        var arguments = [
            "respawn-pane", "-k", "-t", paneID, "-c", cwd,
            "-e", "PARLEY_PANE=1",
            "-e", "PARLEY_PANE_ID=\(paneID)",
            "-e", "PARLEY_PANE_KIND=\(kind.rawValue)",
            "-e", "PARLEY_APP_PID=\(ProcessInfo.processInfo.processIdentifier)",
        ]

        if kind.isAgent {
            // Agents get the narrow relay capability, not the tmux discovery
            // variables. The authenticated broker exposes attributed relay,
            // explicit unsent paste, and correlated Ask—not raw tmux control.
            if let relayRuntime {
                let token = try relayRuntime.credentials.token(for: paneID)
                let path = "\(relayRuntime.shimDirectory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
                arguments.append(contentsOf: [
                    "-e", "PARLEY_RELAY_INFO=\(relayRuntime.infoFile.path)",
                    "-e", "PARLEY_RELAY_TOKEN=\(token)",
                    "-e", "PATH=\(path)",
                ])
            }
            arguments.append(contentsOf: ["-e", "PARLEY_PROTOCOL_VERSION=\(AgentProtocol.version)"])
            for (key, value) in AgentProtocol.environment(
                for: kind,
                protocolDirectory: protocolDirectory,
                inherited: environment
            ).sorted(by: { $0.key < $1.key }) {
                arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
            }
            arguments.append(contentsOf: ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE"])
        }
        arguments.append(contentsOf: AgentProtocol.command(for: kind, protocolDirectory: protocolDirectory))
        return arguments
    }

    private func setMetadata(paneID: String, kind: PaneKind, name: String) throws {
        _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-kind", kind.rawValue])
        _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-name", name])
        _ = try runTmux(["select-pane", "-t", paneID, "-T", name])
    }

    private func setRelayMetadata(paneID: String, enabled: Bool) throws {
        if enabled {
            _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-relay", "1"])
        } else {
            _ = try runTmux(["set-option", "-p", "-u", "-t", paneID, "@parley-relay"], allowFailure: true)
        }
    }

    private func setProtocolMetadata(paneID: String, kind: PaneKind) throws {
        if kind.isAgent {
            _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-protocol", AgentProtocol.version])
        } else {
            _ = try runTmux(["set-option", "-p", "-u", "-t", paneID, "@parley-protocol"], allowFailure: true)
        }
    }

    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ParleyTmuxError.invalidDirectory(path)
        }
    }

    private func runTmux(
        _ command: [String],
        input: Data? = nil,
        allowFailure: Bool = false
    ) throws -> CommandOutput {
        let arguments = ["-S", socketPath.path, "-f", configPath.path] + command
        let output = try runner.run(
            executable: tmuxExecutable,
            arguments: arguments,
            environment: environment,
            input: input
        )
        if output.status != 0, !allowFailure {
            let detail = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ParleyTmuxError.commandFailed(detail.isEmpty ? "tmux command failed: \(command.first ?? "unknown")" : detail)
        }
        return output
    }

    private func writeConfiguration() throws {
        let configuration = """
        set-option -g mouse on
        set-option -g focus-events on
        set-option -g escape-time 0
        set-option -g history-limit 10000
        set-option -g renumber-windows on
        set-option -g set-clipboard external
        set-option -g status-position top
        set-option -g status-style 'bg=#202124,fg=#aeb1b7'
        set-option -g pane-border-style 'fg=#3b3d42'
        set-option -g pane-active-border-style 'fg=#5e8cff'
        set-option -g status-left '#[bold] Parley #[default] '
        set-option -g status-right '#{pane_current_path} '
        set-window-option -g mode-keys vi
        set-window-option -g automatic-rename off
        set-window-option -g allow-rename off
        """
        try configuration.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
