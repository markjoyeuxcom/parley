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
    private let permissionProfileStore: PermissionProfileStore
    private var relayRuntime: RelayRuntime?

    public init(
        tmuxExecutable: URL? = nil,
        applicationDirectory: URL? = nil,
        sessionName: String = "parley",
        environment: [String: String]? = nil,
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        prepareRuntimeFiles: Bool = true
    ) throws {
        let resolvedEnvironment = Self.scrubInheritedCapabilities(
            environment ?? EnvironmentResolver.resolved()
        )
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
        self.permissionProfileStore = PermissionProfileStore(
            file: directory.appendingPathComponent("permission-profiles.json"),
            fileManager: fileManager
        )

        if prepareRuntimeFiles {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            protocolDirectory = try AgentProtocol.install(in: directory, fileManager: fileManager)
            try writeConfiguration()
        } else {
            protocolDirectory = directory.appendingPathComponent("agent-protocol", isDirectory: true)
            let required = [configPath, protocolDirectory.appendingPathComponent("AGENTS.md")]
            guard required.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
                throw ParleyTmuxError.commandFailed(
                    "The Production runtime is not prepared. Start the installed Parley app once before attaching Development."
                )
            }
        }
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

    public func bootstrap(cwd: String, createIfMissing: Bool = true) throws {
        try requireDirectory(cwd)
        let hasSession = try runTmux(["has-session", "-t", exactSession], allowFailure: true).status == 0
        if hasSession {
            try configureEmbeddedPresentation()
            try retainExitedPanes()
            // Migration is metadata-only. Existing panes and the processes
            // inside them are deliberately left untouched.
            for workspace in try listWorkspaces(fallbackFolder: cwd) {
                try setWorkspaceMetadata(
                    windowID: workspace.id,
                    name: workspace.name,
                    folder: workspace.defaultFolder,
                    automationPolicy: workspace.automationPolicy
                )
            }
            return
        }
        guard createIfMissing else {
            throw ParleyTmuxError.commandFailed(
                "The Production tmux session is not running. Start the installed Parley app before attaching Development."
            )
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
            try setStartedMetadata(paneID: paneID, started: true)
            try setWorkspaceMetadata(
                windowID: windowID,
                name: workspaceName(folder: cwd),
                folder: cwd,
                automationPolicy: .askAndDelegate
            )
        }
        try configureEmbeddedPresentation()
        try retainExitedPanes()
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
            "#{bracket_paste_flag}",
            "#{@parley-started}",
            "#{pane_dead}",
            "#{pane_dead_status}",
            "#{@parley-lead}",
            "#{@parley-automation-policy}",
            "#{@parley-permission-selection}",
            "#{@parley-permission-enforcement}",
            "#{@parley-role}",
        ].joined(separator: separator)
        let output = try runTmux(["list-panes", "-s", "-t", exactSession, "-F", format]).stdoutText

        return output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 15, let kind = PaneKind(rawValue: fields[1]) else { return nil }
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
                workspaceName: fields[12].isEmpty ? nil : fields[12],
                bracketedPasteActive: fields[13] == "1",
                isDead: fields.count > 15 && fields[15] == "1",
                exitStatus: fields.count > 16 ? Int(fields[16]) : nil,
                isStarted: fields[14].isEmpty || fields[14] == "1",
                isWorkspaceLead: fields.count > 17 && fields[17] == "1",
                role: fields.count > 21 && !fields[21].isEmpty ? fields[21] : nil,
                automationPolicy: fields.count > 18
                    ? (WorkspaceAutomationPolicy(rawValue: fields[18]) ?? .askAndDelegate)
                    : .askAndDelegate,
                permissionSelection: fields.count > 19
                    ? PermissionProfileSelection(tmuxMetadataValue: fields[19])
                    : nil,
                permissionEnforcement: fields.count > 20
                    ? PermissionEnforcementLevel(rawValue: fields[20])
                    : nil
            )
        }
    }

    public func listWorkspaces() throws -> [TmuxWorkspace] {
        try listWorkspaces(fallbackFolder: nil)
    }

    public func captureWorkspaceLayout(workspaceID: String) throws -> SavedWorkspaceLayout {
        guard let workspace = try listWorkspaces().first(where: { $0.id == workspaceID }) else {
            throw ParleyTmuxError.workspaceNotFound(workspaceID)
        }
        let workspacePanes = try listPanes().filter { $0.windowID == workspaceID }
        let layout = try runTmux([
            "display-message", "-p", "-t", workspaceID, "#{window_layout}",
        ]).stdoutText
        return SavedWorkspaceLayout(
            name: workspace.name,
            defaultFolder: workspace.defaultFolder,
            root: try TmuxLayoutParser.savedNode(layout: layout, panes: workspacePanes),
            automationPolicy: workspace.automationPolicy
        )
    }

    /// Builds the complete replacement in a new tmux window before ending any
    /// existing process. Shell leaves start; agent leaves remain inert sleeps
    /// with no credential, relay flag or protocol stamp until Start is chosen.
    @discardableResult
    public func restoreWorkspaceLayout(
        _ layout: SavedWorkspaceLayout,
        replacing replacedWorkspaceID: String? = nil
    ) throws -> TmuxWorkspace {
        try requireDirectory(layout.defaultFolder)
        for leaf in layout.root.leaves { try requireDirectory(leaf.folder) }
        if let replacedWorkspaceID,
           !(try listWorkspaces().contains(where: { $0.id == replacedWorkspaceID })) {
            throw ParleyTmuxError.workspaceNotFound(replacedWorkspaceID)
        }
        if try listWorkspaces().contains(where: {
            $0.id != replacedWorkspaceID
                && $0.name.caseInsensitiveCompare(layout.name) == .orderedSame
        }) {
            throw ParleyTmuxError.commandFailed("A workspace named \(layout.name) already exists.")
        }
        let replacedPaneIDs: [String] = if let replacedWorkspaceID {
            try listPanes().filter { $0.windowID == replacedWorkspaceID }.map(\.id)
        } else {
            []
        }

        let temporaryName = "Restoring-\(UUID().uuidString.prefix(8))"
        let created = try createWorkspace(folder: layout.defaultFolder, name: temporaryName)
        do {
            let initialPane = try requirePane(in: created.id)
            try configureRestoredNode(layout.root, in: initialPane.id)
            try setWorkspaceMetadata(
                windowID: created.id,
                name: layout.name,
                folder: layout.defaultFolder,
                automationPolicy: layout.automationPolicy
            )
            if let replacedWorkspaceID, replacedWorkspaceID != created.id {
                // This kill is the commit point. Everything that can fail has
                // already succeeded, and everything after it is best-effort.
                _ = try runTmux(["kill-window", "-t", replacedWorkspaceID])
                for paneID in replacedPaneIDs {
                    try? relayRuntime?.credentials.forget(paneID)
                }
            }
            return TmuxWorkspace(
                id: created.id,
                name: layout.name,
                defaultFolder: layout.defaultFolder,
                isActive: true,
                automationPolicy: layout.automationPolicy
            )
        } catch {
            let paneIDs = (try? listPanes().filter { $0.windowID == created.id }.map(\.id)) ?? []
            _ = try? runTmux(["kill-window", "-t", created.id], allowFailure: true)
            for paneID in paneIDs { try? relayRuntime?.credentials.forget(paneID) }
            if let replacedWorkspaceID { try? selectWorkspace(replacedWorkspaceID) }
            throw error
        }
    }

    @discardableResult
    public func createWorkspace(folder: String, name: String? = nil) throws -> TmuxWorkspace {
        try requireDirectory(folder)
        let resolvedName = try availableWorkspaceName(workspaceName(folder: folder, proposed: name))
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
            try setStartedMetadata(paneID: paneID, started: true)
            try setWorkspaceMetadata(
                windowID: windowID,
                name: resolvedName,
                folder: folder,
                automationPolicy: .askAndDelegate
            )
            try selectWorkspace(windowID)
        } catch {
            _ = try? runTmux(["kill-window", "-t", windowID], allowFailure: true)
            throw error
        }
        return TmuxWorkspace(
            id: windowID,
            name: resolvedName,
            defaultFolder: folder,
            isActive: true,
            automationPolicy: .askAndDelegate
        )
    }

    public func selectWorkspace(_ windowID: String) throws {
        _ = try runTmux(["select-window", "-t", windowID])
    }

    public func renameWorkspace(_ windowID: String, name: String) throws {
        let workspaces = try listWorkspaces()
        guard workspaces.contains(where: { $0.id == windowID }) else {
            throw ParleyTmuxError.workspaceNotFound(windowID)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParleyTmuxError.commandFailed("Workspace names cannot be empty.")
        }
        guard !workspaces.contains(where: {
            $0.id != windowID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            throw ParleyTmuxError.commandFailed("A workspace named \(trimmed) already exists.")
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

    public func setWorkspaceAutomationPolicy(
        _ windowID: String,
        policy: WorkspaceAutomationPolicy
    ) throws {
        guard try listWorkspaces().contains(where: { $0.id == windowID }) else {
            throw ParleyTmuxError.workspaceNotFound(windowID)
        }
        _ = try runTmux([
            "set-option", "-w", "-t", windowID, "@parley-automation-policy", policy.rawValue,
        ])
    }

    /// Exactly one agent pane may be the workspace lead. Clearing or replacing
    /// the stamp changes routing metadata only; it grants no additional process
    /// or filesystem capability.
    public func setWorkspaceLead(_ paneID: String?, workspaceID: String) throws {
        let workspacePanes = try listPanes().filter { $0.windowID == workspaceID }
        guard !workspacePanes.isEmpty else { throw ParleyTmuxError.workspaceNotFound(workspaceID) }
        if let paneID {
            guard let pane = workspacePanes.first(where: { $0.id == paneID }) else {
                throw ParleyTmuxError.paneNotFound(paneID)
            }
            guard pane.kind.isAgent else { throw ParleyTmuxError.notAgentPane }
        }
        for pane in workspacePanes where pane.isWorkspaceLead || pane.id == paneID {
            if pane.id == paneID {
                _ = try runTmux(["set-option", "-p", "-t", pane.id, "@parley-lead", "1"])
            } else {
                _ = try runTmux(["set-option", "-p", "-u", "-t", pane.id, "@parley-lead"], allowFailure: true)
            }
        }
    }

    /// A role is workspace-scoped routing metadata. It remains independent of
    /// the pane's display name and grants no process or filesystem capability.
    public func setPaneRole(_ role: String?, paneID: String, workspaceID: String) throws {
        let workspacePanes = try listPanes().filter { $0.windowID == workspaceID }
        guard let pane = workspacePanes.first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent else { throw ParleyTmuxError.notAgentPane }
        if let role {
            if let error = PaneRoleRules.validationError(role) {
                throw ParleyTmuxError.commandFailed(error)
            }
            guard !workspacePanes.contains(where: {
                $0.id != paneID && $0.role?.caseInsensitiveCompare(role) == .orderedSame
            }) else {
                throw ParleyTmuxError.commandFailed("The role \(role) is already assigned in this workspace.")
            }
            _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-role", role])
        } else {
            _ = try runTmux(["set-option", "-p", "-u", "-t", paneID, "@parley-role"], allowFailure: true)
        }
    }

    /// Transfers the exact tmux pane into another workspace. tmux retains the
    /// pane id, process, scrollback, terminal modes and current directory; no
    /// vendor CLI is restarted and no relay credential is rotated.
    @discardableResult
    public func movePane(
        _ paneID: String,
        toWorkspaceID targetWorkspaceID: String,
        direction: SplitDirection,
        activeHandoffCount: Int
    ) throws -> TmuxPane {
        let panes = try listPanes()
        guard let pane = panes.first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        guard let target = panes.first(where: { $0.windowID == targetWorkspaceID }) else {
            throw ParleyTmuxError.workspaceNotFound(targetWorkspaceID)
        }
        let assessment = PaneMobilityPolicy.assess(
            action: .move,
            pane: pane,
            targetWorkspaceID: targetWorkspaceID,
            panes: panes,
            activeHandoffCount: activeHandoffCount
        )
        guard assessment.isAllowed else {
            throw ParleyTmuxError.commandFailed(assessment.refusalText)
        }

        _ = try runTmux([
            "join-pane", "-d", direction == .horizontal ? "-h" : "-v",
            "-s", paneID, "-t", target.id,
        ])
        try selectPane(paneID)
        guard let moved = try listPanes().first(where: { $0.id == paneID && $0.windowID == targetWorkspaceID }) else {
            throw ParleyTmuxError.commandFailed("tmux moved the pane but Parley could not confirm its destination.")
        }
        return moved
    }

    /// Copies only the source pane's visible Parley configuration. Shells
    /// start normally; agent clones stay as inert placeholders until a person
    /// chooses Start, which creates a fresh vendor session and relay credential.
    @discardableResult
    public func clonePaneConfiguration(
        _ paneID: String,
        toWorkspaceID targetWorkspaceID: String,
        direction: SplitDirection,
        activeHandoffCount: Int
    ) throws -> TmuxPane {
        let panes = try listPanes()
        guard let pane = panes.first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        guard let target = panes.first(where: { $0.windowID == targetWorkspaceID }) else {
            throw ParleyTmuxError.workspaceNotFound(targetWorkspaceID)
        }
        let assessment = PaneMobilityPolicy.assess(
            action: .clone,
            pane: pane,
            targetWorkspaceID: targetWorkspaceID,
            panes: panes,
            activeHandoffCount: activeHandoffCount
        )
        guard assessment.isAllowed else {
            throw ParleyTmuxError.commandFailed(assessment.refusalText)
        }

        let arguments = [
            "split-window", "-d", "-P", "-F", "#{pane_id}",
            direction == .horizontal ? "-h" : "-v", "-t", target.id,
            "-c", pane.cwd, "/bin/sleep", "2147483647",
        ]
        let cloneID = try runTmux(arguments).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cloneID.isEmpty else {
            throw ParleyTmuxError.commandFailed("tmux did not return the cloned pane id")
        }

        let leaf = SavedLayoutLeaf(
            kind: pane.kind,
            name: pane.displayName,
            folder: pane.cwd,
            role: pane.role,
            isWorkspaceLead: pane.isWorkspaceLead,
            permissionSelection: pane.permissionSelection
        )
        do {
            try configureRestoredLeaf(leaf, paneID: cloneID)
            try selectPane(cloneID)
            guard let clone = try listPanes().first(where: {
                $0.id == cloneID && $0.windowID == targetWorkspaceID
            }) else {
                throw ParleyTmuxError.commandFailed("tmux created the clone but Parley could not confirm its destination.")
            }
            return clone
        } catch {
            _ = try? runTmux(["kill-pane", "-t", cloneID], allowFailure: true)
            try? relayRuntime?.credentials.forget(cloneID)
            throw error
        }
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
    public func createPane(
        kind: PaneKind,
        cwd: String,
        direction: SplitDirection,
        permissionProfile: EffectivePermissionProfile? = nil
    ) throws -> TmuxPane {
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
            let resolvedProfile = try effectivePermissionProfile(
                for: kind,
                cwd: cwd,
                supplied: permissionProfile,
                selection: nil
            )
            try setPermissionMetadata(paneID: paneID, kind: kind, profile: resolvedProfile)
            _ = try runTmux(try respawnArguments(
                paneID: paneID,
                kind: kind,
                cwd: cwd,
                permissionProfile: resolvedProfile
            ))
            try setRelayMetadata(paneID: paneID, enabled: kind.isAgent && relayRuntime != nil)
            try setProtocolMetadata(paneID: paneID, kind: kind)
            try setStartedMetadata(paneID: paneID, started: true)
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

    public func restartPane(
        _ paneID: String,
        permissionProfile: EffectivePermissionProfile? = nil
    ) throws {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        if pane.kind.isAgent, let relayRuntime {
            _ = try relayRuntime.credentials.rotate(paneID)
        }
        let resolvedProfile = try effectivePermissionProfile(
            for: pane.kind,
            cwd: pane.cwd,
            supplied: permissionProfile,
            selection: pane.permissionSelection
        )
        try setPermissionMetadata(paneID: paneID, kind: pane.kind, profile: resolvedProfile)
        _ = try runTmux(try respawnArguments(
            paneID: paneID,
            kind: pane.kind,
            cwd: pane.cwd,
            permissionProfile: resolvedProfile
        ))
        try setRelayMetadata(paneID: paneID, enabled: pane.kind.isAgent && relayRuntime != nil)
        try setProtocolMetadata(paneID: paneID, kind: pane.kind)
        try setStartedMetadata(paneID: paneID, started: true)
    }

    public func startPane(
        _ paneID: String,
        permissionProfile: EffectivePermissionProfile? = nil
    ) throws {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent, !pane.isStarted else { return }
        let resolvedProfile = try effectivePermissionProfile(
            for: pane.kind,
            cwd: pane.cwd,
            supplied: permissionProfile,
            selection: pane.permissionSelection
        )
        try setPermissionMetadata(paneID: paneID, kind: pane.kind, profile: resolvedProfile)
        _ = try runTmux(try respawnArguments(
            paneID: paneID,
            kind: pane.kind,
            cwd: pane.cwd,
            permissionProfile: resolvedProfile
        ))
        try setRelayMetadata(paneID: paneID, enabled: relayRuntime != nil)
        try setProtocolMetadata(paneID: paneID, kind: pane.kind)
        try setStartedMetadata(paneID: paneID, started: true)
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

    /// Sends the terminal interrupt key to one exact live agent pane. Callers
    /// must obtain explicit human confirmation; agent capabilities never reach
    /// this tmux control path.
    public func interruptPane(_ paneID: String) throws {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent, pane.isStarted, !pane.isDead else {
            throw ParleyTmuxError.notAgentPane
        }
        _ = try runTmux(["send-keys", "-t", paneID, "C-c"])
    }

    private func requirePane(in workspaceID: String) throws -> TmuxPane {
        guard let pane = try listPanes().first(where: { $0.windowID == workspaceID }) else {
            throw ParleyTmuxError.paneNotFound("workspace \(workspaceID)")
        }
        return pane
    }

    private func configureRestoredNode(_ node: SavedLayoutNode, in paneID: String) throws {
        switch node {
        case let .leaf(leaf):
            try configureRestoredLeaf(leaf, paneID: paneID)
        case let .split(direction, ratio, first, second):
            let secondFolder = second.leaves.first?.folder ?? "/"
            let secondPercentage = min(95, max(5, Int(((1 - ratio) * 100).rounded())))
            let arguments = [
                "split-window", "-d", "-P", "-F", "#{pane_id}",
                direction == .horizontal ? "-h" : "-v",
                "-p", String(secondPercentage),
                "-t", paneID,
                "-c", secondFolder,
                "/bin/sleep", "2147483647",
            ]
            let secondPaneID = try runTmux(arguments).stdoutText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secondPaneID.isEmpty else {
                throw ParleyTmuxError.commandFailed("tmux did not return a restored pane id")
            }
            try configureRestoredNode(first, in: paneID)
            try configureRestoredNode(second, in: secondPaneID)
        }
    }

    private func configureRestoredLeaf(_ leaf: SavedLayoutLeaf, paneID: String) throws {
        try setMetadata(paneID: paneID, kind: leaf.kind, name: leaf.name)
        if let role = leaf.role, leaf.kind.isAgent {
            _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-role", role])
        } else {
            _ = try runTmux(["set-option", "-p", "-u", "-t", paneID, "@parley-role"], allowFailure: true)
        }
        let profile = try effectivePermissionProfile(
            for: leaf.kind,
            cwd: leaf.folder,
            supplied: nil,
            selection: leaf.permissionSelection
        )
        try setPermissionMetadata(paneID: paneID, kind: leaf.kind, profile: profile)
        if leaf.isWorkspaceLead && leaf.kind.isAgent {
            _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-lead", "1"])
        } else {
            _ = try runTmux(["set-option", "-p", "-u", "-t", paneID, "@parley-lead"], allowFailure: true)
        }
        if leaf.kind == .shell {
            _ = try runTmux(try respawnArguments(paneID: paneID, kind: .shell, cwd: leaf.folder))
            try setRelayMetadata(paneID: paneID, enabled: false)
            try setProtocolMetadata(paneID: paneID, kind: .shell)
            try setStartedMetadata(paneID: paneID, started: true)
        } else {
            _ = try runTmux([
                "respawn-pane", "-k", "-t", paneID, "-c", leaf.folder,
                "/bin/sleep", "2147483647",
            ])
            try setRelayMetadata(paneID: paneID, enabled: false)
            _ = try runTmux(["set-option", "-p", "-u", "-t", paneID, "@parley-protocol"], allowFailure: true)
            try setStartedMetadata(paneID: paneID, started: false)
        }
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
        try ask(from: requesterID, to: consultantID, text: text, preservesExplicitFormatting: false)
    }

    public func askWithExplicitContext(from requesterID: String, to consultantID: String, text: String) throws {
        try ask(from: requesterID, to: consultantID, text: text, preservesExplicitFormatting: true)
    }

    private func ask(
        from requesterID: String,
        to consultantID: String,
        text: String?,
        preservesExplicitFormatting: Bool
    ) throws {
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
        let body = preservesExplicitFormatting
            ? ContextPackText.normalize(captured)
            : RelayText.clean(captured)
        guard !body.isEmpty else { throw ParleyTmuxError.noRelayText }
        let attributed = "\(requester.displayName) asked:\n\n\(body)"
        if preservesExplicitFormatting {
            try pasteExplicitContext(attributed, into: consultantID, submit: true)
        } else {
            try paste(attributed, into: consultantID, submit: true)
        }
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
        try pastePrepared(cleaned, into: paneID, submit: submit)
    }

    public func pasteExplicitContext(_ text: String, into paneID: String, submit: Bool) throws {
        let prepared = ContextPackText.normalize(text)
        guard !prepared.isEmpty else { throw ParleyTmuxError.noRelayText }
        guard prepared.utf8.count <= ContextPackBuilder.defaultMaximumRenderedBytes + 4_096 else {
            throw ContextPackError.packTooLarge
        }
        try pastePrepared(prepared, into: paneID, submit: submit)
    }

    private func pastePrepared(_ prepared: String, into paneID: String, submit: Bool) throws {
        let panes = try listPanes()
        guard let pane = panes.first(where: { $0.id == paneID }) else {
            throw ParleyTmuxError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent,
              !pane.isDead,
              pane.relayEnabled,
              pane.hasCurrentProtocol,
              pane.bracketedPasteActive else {
            throw ParleyTmuxError.unsafeRelayTarget(pane.displayName)
        }
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
        _ = try runTmux(["load-buffer", "-b", buffer, "-"], input: Data(prepared.utf8))
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
            "#{@parley-automation-policy}",
        ].joined(separator: separator)
        let output = try runTmux(["list-windows", "-t", exactSession, "-F", format]).stdoutText
        return output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else { return nil }
            let folder = !fields[4].isEmpty
                ? fields[4]
                : (!fields[5].isEmpty ? fields[5] : (fallbackFolder ?? "/"))
            let name = !fields[3].isEmpty
                ? fields[3]
                : workspaceName(folder: folder, proposed: fields[1] == "agents" ? nil : fields[1])
            return TmuxWorkspace(
                id: fields[0],
                name: name,
                defaultFolder: folder,
                isActive: fields[2] == "1",
                automationPolicy: WorkspaceAutomationPolicy(rawValue: fields[6]) ?? .askAndDelegate
            )
        }
    }

    private func workspaceName(folder: String, proposed: String? = nil) -> String {
        let trimmed = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let component = URL(fileURLWithPath: folder).standardizedFileURL.lastPathComponent
        return component.isEmpty ? "Workspace" : component
    }

    private func availableWorkspaceName(_ proposed: String) throws -> String {
        let existing = try listWorkspaces().map(\.name)
        guard existing.contains(where: { $0.caseInsensitiveCompare(proposed) == .orderedSame }) else {
            return proposed
        }
        for suffix in 2...999 {
            let qualified = "\(proposed) (\(suffix))"
            if !existing.contains(where: { $0.caseInsensitiveCompare(qualified) == .orderedSame }) {
                return qualified
            }
        }
        throw ParleyTmuxError.commandFailed("Too many workspaces share the name \(proposed).")
    }

    private func setWorkspaceMetadata(
        windowID: String,
        name: String,
        folder: String,
        automationPolicy: WorkspaceAutomationPolicy
    ) throws {
        _ = try runTmux(["set-option", "-w", "-t", windowID, "@parley-workspace-name", name])
        _ = try runTmux(["set-option", "-w", "-t", windowID, "@parley-workspace-folder", folder])
        _ = try runTmux([
            "set-option", "-w", "-t", windowID, "@parley-automation-policy", automationPolicy.rawValue,
        ])
        _ = try runTmux(["rename-window", "-t", windowID, name])
    }

    private func respawnArguments(
        paneID: String,
        kind: PaneKind,
        cwd: String,
        permissionProfile: EffectivePermissionProfile? = nil
    ) throws -> [String] {
        var arguments = [
            "respawn-pane", "-k", "-t", paneID, "-c", cwd,
            "-e", "PARLEY_PANE=1",
            "-e", "PARLEY_PANE_ID=\(paneID)",
            "-e", "PARLEY_PANE_KIND=\(kind.rawValue)",
            "-e", "PARLEY_APP_PID=\(ProcessInfo.processInfo.processIdentifier)",
        ]

        if kind == .shell {
            arguments.append(contentsOf: [loginShellExecutable(), "-l"])
            return arguments
        }

        if kind.isAgent {
            // Agents get the narrow relay capability, not the tmux discovery
            // variables. The authenticated broker exposes attributed relay,
            // explicit unsent paste, and correlated Ask—not raw tmux control.
            guard let relayRuntime else {
                throw ParleyTmuxError.commandFailed(
                    "Parley cannot start an agent without its protected relay boundary. Shell panes remain available."
                )
            }
            let token = try relayRuntime.credentials.token(for: paneID)
            let path = "\(relayRuntime.shimDirectory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            arguments.append(contentsOf: [
                "-e", "PARLEY_RELAY_TOKEN=\(token)",
                "-e", "PATH=\(path)",
            ])
            if let runtimeMarker = relayRuntime.runtimeMarker {
                arguments.append(contentsOf: ["-e", "PARLEY_RUNTIME=\(runtimeMarker)"])
            }
            let boundary = try AgentProcessBoundary(
                applicationDirectory: applicationDirectory,
                protocolDirectory: protocolDirectory,
                shimDirectory: relayRuntime.shimDirectory,
                tmuxSocket: socketPath,
                transportDirectory: relayRuntime.transportDirectory,
                paneToken: token,
                fileManager: fileManager
            )
            arguments.append(contentsOf: ["-e", "PARLEY_PROTOCOL_VERSION=\(AgentProtocol.version)"])
            for (key, value) in AgentProtocol.environment(
                for: kind,
                protocolDirectory: protocolDirectory,
                inherited: environment
            ).sorted(by: { $0.key < $1.key }) {
                arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
            }
            arguments.append(contentsOf: boundary.arguments)
            arguments.append(contentsOf: ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE"])
        }
        var command = AgentProtocol.command(for: kind, protocolDirectory: protocolDirectory)
        if let permissionProfile {
            command.append(contentsOf: PermissionProfileAdapter.launchPlan(
                for: kind,
                profile: permissionProfile
            ).arguments)
        }
        arguments.append(contentsOf: command)
        return arguments
    }

    private func effectivePermissionProfile(
        for kind: PaneKind,
        cwd: String,
        supplied: EffectivePermissionProfile?,
        selection: PermissionProfileSelection?
    ) throws -> EffectivePermissionProfile? {
        guard kind.isAgent else { return nil }
        if let supplied { return supplied }

        let profiles = try permissionProfileStore.profiles()
        let definition: PermissionProfileDefinition
        if let selection,
           let selected = profiles.first(where: { $0.id == selection.profileID }) {
            definition = selected
        } else {
            guard let fallback = profiles.first(where: { $0.id == "default" }) else {
                throw ParleyTmuxError.commandFailed("The Default permission profile is unavailable.")
            }
            definition = fallback
        }
        return try PermissionProfileResolver.resolve(
            definition: definition,
            paneFolder: cwd,
            approvedRoots: definition.rootMode == .exactApprovedRoots
                ? (selection?.approvedRoots ?? [cwd])
                : []
        )
    }

    private func loginShellExecutable() -> String {
        if let configured = environment["SHELL"],
           configured.hasPrefix("/"),
           fileManager.isExecutableFile(atPath: configured) {
            return configured
        }
        return "/bin/zsh"
    }

    private func setMetadata(paneID: String, kind: PaneKind, name: String) throws {
        _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-kind", kind.rawValue])
        _ = try runTmux(["set-option", "-p", "-t", paneID, "@parley-name", name])
        _ = try runTmux(["select-pane", "-t", paneID, "-T", name])
    }

    private func setPermissionMetadata(
        paneID: String,
        kind: PaneKind,
        profile: EffectivePermissionProfile?
    ) throws {
        guard let profile else {
            _ = try runTmux([
                "set-option", "-p", "-u", "-t", paneID, "@parley-permission-selection",
            ], allowFailure: true)
            _ = try runTmux([
                "set-option", "-p", "-u", "-t", paneID, "@parley-permission-enforcement",
            ], allowFailure: true)
            return
        }
        let plan = PermissionProfileAdapter.launchPlan(for: kind, profile: profile)
        _ = try runTmux([
            "set-option", "-p", "-t", paneID,
            "@parley-permission-selection", profile.selection.tmuxMetadataValue,
        ])
        _ = try runTmux([
            "set-option", "-p", "-t", paneID,
            "@parley-permission-enforcement", plan.enforcement.rawValue,
        ])
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

    private func setStartedMetadata(paneID: String, started: Bool) throws {
        _ = try runTmux([
            "set-option", "-p", "-t", paneID, "@parley-started", started ? "1" : "0",
        ])
    }

    private func retainExitedPanes() throws {
        _ = try runTmux(["set-window-option", "-g", "remain-on-exit", "on"])
    }

    private func configureEmbeddedPresentation() throws {
        _ = try runTmux(["set-option", "-g", "status", "off"])
        _ = try runTmux(["set-window-option", "-g", "pane-border-status", "off"])
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

    private static func scrubInheritedCapabilities(_ environment: [String: String]) -> [String: String] {
        let sensitive = Set([
            "PARLEY_PANE",
            "PARLEY_PANE_ID",
            "PARLEY_PANE_KIND",
            "PARLEY_APP_PID",
            "PARLEY_RELAY_INFO",
            "PARLEY_RELAY_TOKEN",
            "PARLEY_IDEMPOTENCY_KEY",
            "PARLEY_PROTOCOL_VERSION",
        ])
        return environment.filter { !sensitive.contains($0.key) }
    }

    private func writeConfiguration() throws {
        let configuration = """
        set-option -g mouse on
        set-option -g focus-events on
        set-option -g escape-time 0
        set-option -g history-limit 10000
        set-option -g renumber-windows on
        set-option -g set-clipboard external
        set-option -g status off
        set-option -g pane-border-style 'fg=#3b3d42'
        set-option -g pane-active-border-style 'fg=#5e8cff'
        set-window-option -g pane-border-status off
        set-window-option -g mode-keys vi
        set-window-option -g remain-on-exit on
        set-window-option -g automatic-rename off
        set-window-option -g allow-rename off
        """
        try configuration.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
