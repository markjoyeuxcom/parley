import Foundation

public struct GhosttyPaneLaunch: Equatable, Sendable {
    public let paneID: String
    public let generation: Int
    public let workingDirectory: String
    public let environment: [String: String]
    public let command: String

    public init(
        paneID: String,
        generation: Int,
        workingDirectory: String,
        environment: [String: String],
        command: String
    ) {
        self.paneID = paneID
        self.generation = generation
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.command = command
    }
}

/// The small synchronous input surface the coordination broker needs. Its
/// implementation is Parley's retained Ghostty view registry in the app
/// process; no terminal multiplexer or second PTY owner sits underneath it.
public struct PaneTerminalTransport: @unchecked Sendable {
    public let paste: (_ paneID: String, _ text: String, _ submit: Bool) throws -> Void
    public let interrupt: (_ paneID: String) throws -> Void
    public let captureSelectedText: (_ paneID: String) throws -> String
    public let terminate: (_ paneID: String) -> Void
    public let terminateAll: () -> Void

    public init(
        paste: @escaping (_ paneID: String, _ text: String, _ submit: Bool) throws -> Void,
        interrupt: @escaping (_ paneID: String) throws -> Void,
        captureSelectedText: @escaping (_ paneID: String) throws -> String,
        terminate: @escaping (_ paneID: String) -> Void,
        terminateAll: @escaping () -> Void
    ) {
        self.paste = paste
        self.interrupt = interrupt
        self.captureSelectedText = captureSelectedText
        self.terminate = terminate
        self.terminateAll = terminateAll
    }
}

/// App-resident pane and workspace ownership for Ghostty surfaces. This class
/// persists only Parley-owned configuration. Vendor processes, terminal grids,
/// scrollback and sessions live in retained Ghostty surfaces and deliberately
/// end when the application process ends.
public final class WorkbenchController: @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var workspaces: [WorkbenchWorkspace]
        var panes: [WorkbenchPane]
        var activity: [String: Date]
        var ownerPID: Int32
        var ownerSessionID: String?
    }
    private var approvedShellLaunches: [String: (generation: Int, argv: [String])] = [:]
    private static let processSessionID = UUID().uuidString

    private struct AgentLaunchRequest {
        let generation: Int
        let mode: AgentLaunchMode
    }


    public let applicationDirectory: URL
    public let protocolDirectory: URL
    private let swiftPMDirectory: URL
    private var swiftPMCompatibilityEnabled: Bool
    private var swiftPMLaunches: [String: (generation: Int, enabled: Bool)] = [:]
    public let environment: [String: String]

    private let stateFile: URL
    private let fileManager: FileManager
    private let permissionProfileStore: PermissionProfileStore
    private let lock = NSRecursiveLock()
    private var document: Document
    private var relayRuntime: RelayRuntime?
    private var terminalTransport: PaneTerminalTransport?
    private var copilotTrustConfirmations: [String: Int] = [:]
    private var agentLaunchRequests: [String: AgentLaunchRequest] = [:]

    public init(
        applicationDirectory: URL? = nil,
        environment: [String: String]? = nil,
        swiftPMCompatibilityEnabled: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        let directory = applicationDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)
        self.applicationDirectory = directory
        self.environment = Self.scrubInheritedCapabilities(environment ?? EnvironmentResolver.resolved())
        self.fileManager = fileManager
        self.swiftPMCompatibilityEnabled = swiftPMCompatibilityEnabled
        stateFile = directory.appendingPathComponent("workbench-state.json")
        permissionProfileStore = PermissionProfileStore(
            file: directory.appendingPathComponent("permission-profiles.json"),
            fileManager: fileManager
        )

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        protocolDirectory = try AgentProtocol.install(in: directory, fileManager: fileManager)
        swiftPMDirectory = try SwiftPMCompatibility.install(in: directory, fileManager: fileManager)

        if fileManager.fileExists(atPath: stateFile.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            document = try decoder.decode(Document.self, from: Data(contentsOf: stateFile))
        } else {
            document = Document(workspaces: [], panes: [], activity: [:], ownerPID: 0)
        }
    }

    /// A native preference affects future launches, never a retained process.
    public func setSwiftPMCompatibilityEnabled(_ enabled: Bool) {
        lock.withLock { swiftPMCompatibilityEnabled = enabled }
    }

    public func configureRelay(_ runtime: RelayRuntime) {
        lock.withLock { relayRuntime = runtime }
    }

    public func configureTerminalTransport(_ transport: PaneTerminalTransport) {
        lock.withLock { terminalTransport = transport }
    }

    public func bootstrap(cwd: String, createIfMissing: Bool = true) throws {
        try requireDirectory(cwd)
        try lock.withLock {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if document.ownerPID != currentPID || document.ownerSessionID != Self.processSessionID {
                // A previous app process cannot have surviving Ghostty
                // surfaces. Preserve layout and identity, but never claim its
                // agent sessions are still live.
                for index in document.panes.indices {
                    document.panes[index].launchGeneration &+= 1
                    document.panes[index].isDead = false
                    document.panes[index].exitStatus = nil
                    document.panes[index].inputAvailable = false
                    if document.panes[index].kind.isAgent {
                        document.panes[index].isStarted = false
                        document.panes[index].relayEnabled = false
                        document.panes[index].protocolVersion = nil
                        document.panes[index].currentCommand = "stopped"
                        document.panes[index].vendorRuntimeState = nil
                        document.panes[index].vendorRuntimeSignal = nil
                        document.panes[index].vendorRuntimeSignaledAt = nil
                    } else {
                        document.panes[index].isStarted = true
                        document.panes[index].currentCommand = loginShellExecutable().lastPathComponent
                    }
                }
                document.ownerPID = currentPID
                document.ownerSessionID = Self.processSessionID
            }
            // Surface attachment is process-local and can never be restored
            // from persisted metadata.
            for index in document.panes.indices {
                document.panes[index].inputAvailable = false
            }
            if document.workspaces.isEmpty || document.panes.isEmpty {
                guard createIfMissing else {
                    throw ParleyWorkbenchError.commandFailed(
                        "The requested workbench is not running. Start Parley before reconnecting."
                    )
                }
                document.workspaces = []
                document.panes = []
                _ = try createWorkspaceLocked(
                    launchFolder: cwd,
                    name: nil,
                    attachedFolders: [],
                    newPaneFolder: nil
                )
            }
            normalizeSelectionLocked()
            try persistLocked()
        }
    }

    public func listPanes() throws -> [WorkbenchPane] {
        lock.withLock { document.panes }
    }

    public func listWorkspaces() throws -> [WorkbenchWorkspace] {
        lock.withLock { document.workspaces }
    }

    public func activePane() throws -> WorkbenchPane? {
        lock.withLock { document.panes.first(where: \.isActive) }
    }

    @discardableResult
    public func createWorkspace(
        folder: String,
        name: String? = nil
    ) throws -> WorkbenchWorkspace {
        try requireDirectory(folder)
        return try lock.withLock {
            let workspace = try createWorkspaceLocked(
                launchFolder: folder,
                name: name,
                attachedFolders: [folder],
                newPaneFolder: folder
            )
            try persistLocked()
            return workspace
        }
    }

    /// Creates a collaboration container without turning its initial shell's
    /// working directory into workspace identity or an attached folder.
    @discardableResult
    public func createFolderlessWorkspace(
        name: String? = nil,
        launchFolder: String
    ) throws -> WorkbenchWorkspace {
        try requireDirectory(launchFolder)
        return try lock.withLock {
            let workspace = try createWorkspaceLocked(
                launchFolder: launchFolder,
                name: name,
                attachedFolders: [],
                newPaneFolder: nil
            )
            try persistLocked()
            return workspace
        }
    }

    public func selectWorkspace(_ workspaceID: String) throws {
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            for position in document.workspaces.indices {
                document.workspaces[position].isActive = position == index
            }
            let durableID = document.workspaces[index].workspaceID
            if !document.panes.contains(where: { $0.workspaceID == durableID && $0.isActive }),
               let paneIndex = document.panes.firstIndex(where: { $0.workspaceID == durableID }) {
                for position in document.panes.indices { document.panes[position].isActive = position == paneIndex }
            }
            try persistLocked()
        }
    }

    public func renameWorkspace(_ workspaceID: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParleyWorkbenchError.commandFailed("Workspace names cannot be empty.") }
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            if document.workspaces.contains(where: {
                $0.workspaceID != document.workspaces[index].workspaceID
                    && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                throw ParleyWorkbenchError.commandFailed("A workspace named \(trimmed) already exists.")
            }
            let durableID = document.workspaces[index].workspaceID
            document.workspaces[index].name = trimmed
            for paneIndex in document.panes.indices where document.panes[paneIndex].workspaceID == durableID {
                document.panes[paneIndex].workspaceName = trimmed
            }
            try persistLocked()
        }
    }

    public func setWorkspaceNewPaneFolder(_ workspaceID: String, folder: String?) throws {
        if let folder { try requireDirectory(folder) }
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            document.workspaces[index].newPaneFolder = folder.map(WorkspaceFolderIdentity.normalized)
            try persistLocked()
        }
    }

    public func attachFolder(_ folder: String, toWorkspace workspaceID: String) throws {
        try requireDirectory(folder)
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            let normalized = WorkspaceFolderIdentity.normalized(folder)
            guard !document.workspaces[index].attachedFolders.contains(where: {
                WorkspaceFolderIdentity.matches($0, normalized)
            }) else { return }
            guard document.workspaces[index].attachedFolders.count < 32 else {
                throw ParleyWorkbenchError.commandFailed("A workspace can attach at most 32 folders.")
            }
            document.workspaces[index].attachedFolders.append(normalized)
            try persistLocked()
        }
    }

    public func detachFolder(_ folder: String, fromWorkspace workspaceID: String) throws {
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            document.workspaces[index].attachedFolders.removeAll {
                WorkspaceFolderIdentity.matches($0, folder)
            }
            try persistLocked()
        }
    }

    public func moveAttachedFolder(
        _ folder: String,
        inWorkspace workspaceID: String,
        by offset: Int
    ) throws {
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            guard let source = document.workspaces[index].attachedFolders.firstIndex(where: {
                WorkspaceFolderIdentity.matches($0, folder)
            }) else { return }
            let destination = source + offset
            guard document.workspaces[index].attachedFolders.indices.contains(destination) else { return }
            let moved = document.workspaces[index].attachedFolders.remove(at: source)
            document.workspaces[index].attachedFolders.insert(moved, at: destination)
            try persistLocked()
        }
    }

    public func setWorkspaceAutomationPolicy(
        _ workspaceID: String,
        policy: WorkspaceAutomationPolicy
    ) throws {
        try lock.withLock {
            let index = try workspaceIndexLocked(workspaceID)
            let durableID = document.workspaces[index].workspaceID
            document.workspaces[index].automationPolicy = policy
            for paneIndex in document.panes.indices where document.panes[paneIndex].workspaceID == durableID {
                document.panes[paneIndex].automationPolicy = policy
            }
            try persistLocked()
        }
    }

    public func setWorkspaceLead(_ paneID: String?, workspaceID: String) throws {
        try lock.withLock {
            let workspace = document.workspaces[try workspaceIndexLocked(workspaceID)]
            if let paneID {
                guard let pane = document.panes.first(where: {
                    $0.id == paneID && $0.workspaceID == workspace.workspaceID && $0.kind.isAgent
                }) else { throw ParleyWorkbenchError.notAgentPane }
                _ = pane
            }
            for index in document.panes.indices where document.panes[index].workspaceID == workspace.workspaceID {
                document.panes[index].isWorkspaceLead = document.panes[index].id == paneID
            }
            try persistLocked()
        }
    }

    public func setPaneRole(_ role: String?, paneID: String, workspaceID: String) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            let workspace = document.workspaces[try workspaceIndexLocked(workspaceID)]
            guard document.panes[index].workspaceID == workspace.workspaceID,
                  document.panes[index].kind.isAgent else { throw ParleyWorkbenchError.notAgentPane }
            let normalized: String?
            if let role {
                if let error = PaneRoleRules.validationError(role) {
                    throw ParleyWorkbenchError.commandFailed(error)
                }
                normalized = role
            } else {
                normalized = nil
            }
            if let normalized, document.panes.contains(where: {
                $0.workspaceID == workspace.workspaceID && $0.id != paneID && $0.role == normalized
            }) {
                throw ParleyWorkbenchError.commandFailed("That role is already assigned in this workspace.")
            }
            document.panes[index].role = normalized
            try persistLocked()
        }
    }

    @discardableResult
    public func createPane(
        kind: PaneKind,
        cwd: String,
        permissionProfile: EffectivePermissionProfile? = nil
    ) throws -> WorkbenchPane {
        try requireDirectory(cwd)
        return try lock.withLock {
            guard let activeWorkspace = document.workspaces.first(where: \.isActive) else {
                throw ParleyWorkbenchError.workspaceNotFound("active")
            }
            let profile = try effectivePermissionProfile(
                for: kind,
                cwd: cwd,
                supplied: permissionProfile,
                selection: nil
            )
            let pane = makePane(
                kind: kind,
                cwd: cwd,
                workspace: activeWorkspace,
                started: true,
                permissionProfile: profile
            )
            for index in document.panes.indices { document.panes[index].isActive = false }
            document.panes.append(pane)
            document.activity[pane.id] = Date()
            try persistLocked()
            return pane
        }
    }

    /// Native-only creation path for an approved team session. The agent
    /// transport can only ask; the workspace, folder, vendor list, permission
    /// profile and limit come from the person's approval, re-checked here.
    public func createTeamPane(
        session: TeamSession,
        grant: TeamSessionGrant,
        provision: TeamPaneProvision,
        permissionProfile: EffectivePermissionProfile
    ) throws -> WorkbenchPane {
        try requireDirectory(grant.folder)
        return try lock.withLock {
            guard session.state == .active, session.grantID == grant.id, provision.sessionID == session.id,
                  provision.paneID == nil, provision.failure == nil,
                  provision.kind.isAgent, grant.allowedVendors.contains(provision.kind),
                  session.members.count < grant.paneLimit, Date() < grant.provisioningDeadline,
                  let lead = document.panes.first(where: { $0.id == grant.leadPaneID }),
                  lead.kind.isAgent, lead.isStarted, !lead.isDead,
                  lead.launchGeneration == grant.leadGeneration, lead.workspaceID == grant.workspaceID,
                  WorkspaceFolderIdentity.matchingKey(lead.cwd) == session.sourceFolder,
                  let workspace = document.workspaces.first(where: { $0.workspaceID == grant.workspaceID }),
                  workspace.automationPolicy == grant.automationPolicy else {
                throw TeamSessionError.invalid("The approved team session or its lead pane changed before pane creation.")
            }
            let canonical = WorkspaceFolderIdentity.matchingKey(grant.folder)
            guard canonical == session.sourceFolder || canonical.hasPrefix(session.sourceFolder + "/") else {
                throw TeamSessionError.invalid("The approved folder is outside the lead pane's working folder.")
            }
            if let role = provision.role {
                if let error = PaneRoleRules.validationError(role) { throw TeamSessionError.invalid(error) }
                guard !document.panes.contains(where: { $0.workspaceID == workspace.workspaceID && $0.role == role }) else {
                    throw TeamSessionError.invalid("The role \(role) is already assigned in this workspace.")
                }
            }
            // The supplied profile must be the approved definition and roots.
            // There is no fallback to a stored default under another identity.
            guard grant.matches(effective: permissionProfile) else {
                throw TeamSessionError.invalid("The permission profile does not match the approved grant.")
            }
            let current = try permissionProfileStore.profiles().first { $0.id == grant.permissionProfileID }
            guard current == grant.approvedProfile else {
                throw TeamSessionError.invalid("The approved permission profile was edited or removed; the pane was not created.")
            }
            var pane = makePane(kind: provision.kind, cwd: grant.folder, workspace: workspace, started: true, permissionProfile: permissionProfile)
            pane.customName = provision.name
            pane.role = provision.role
            let previous = document
            for index in document.workspaces.indices {
                document.workspaces[index].isActive = document.workspaces[index].workspaceID == workspace.workspaceID
            }
            for index in document.panes.indices { document.panes[index].isActive = false }
            document.panes.append(pane)
            document.activity[pane.id] = Date()
            do { try persistLocked() } catch {
                // Creation is atomic: a pane that could not be recorded does not exist.
                document = previous
                throw TeamSessionError.invalid("The pane could not be recorded, so it was not created: \(error.localizedDescription)")
            }
            return pane
        }
    }

    /// Native-only creation path. No agent transport can supply launch overrides.
    public func createApprovedCommandPane(run: ReviewedCommandRun, workerExecutable: URL) throws -> WorkbenchPane {
        try lock.withLock {
            guard run.state == .running,
                  let source = document.panes.first(where: { $0.id == run.source.id }),
                  source.kind.isAgent, source.isStarted, !source.isDead,
                  source.launchGeneration == run.source.launchGeneration,
                  source.workspaceID == run.source.workspaceID,
                  WorkspaceFolderIdentity.matchingKey(source.cwd) == run.sourceFolder,
                  let workspace = document.workspaces.first(where: { $0.workspaceID == source.workspaceID }),
                  !document.panes.contains(where: { $0.id == run.shellPaneID }),
                  workerExecutable.path.hasPrefix("/"),
                  fileManager.isExecutableFile(atPath: workerExecutable.path) else {
                throw ReviewedCommandRunError.invalid("The approved request or its source pane changed before Shell creation.")
            }
            let checked = try ReviewedCommand(argv: run.command.argv, folder: run.command.folder, sourceFolder: run.sourceFolder)
            guard checked == run.command else { throw ReviewedCommandRunError.invalid("The approved folder changed.") }
            let directory = applicationDirectory.resolvingSymlinksInPath().appendingPathComponent("approved-command-runs")
            let ticket = try ApprovedCommandWorker.stage(run: run, directory: directory,
                shellExecutable: loginShellExecutable().path, ownerPID: ProcessInfo.processInfo.processIdentifier)
            let previous = document
            var pane = makePane(kind: .shell, cwd: run.command.folder, workspace: workspace, started: true, permissionProfile: nil)
            pane.id = run.shellPaneID
            pane.customName = "Command run"
            for index in document.workspaces.indices { document.workspaces[index].isActive = document.workspaces[index].workspaceID == workspace.workspaceID }
            for index in document.panes.indices { document.panes[index].isActive = false }
            document.panes.append(pane)
            document.activity[pane.id] = Date()
            do { try persistLocked() }
            catch {
                document = previous
                try? fileManager.removeItem(at: ticket.deletingLastPathComponent())
                throw error
            }
            approvedShellLaunches[pane.id] = (pane.launchGeneration, [workerExecutable.path, ApprovedCommandWorker.argument, ticket.path])
            return pane
        }
    }

    public func selectPane(_ paneID: String) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            let workspaceID = document.panes[index].workspaceID
            for position in document.workspaces.indices {
                document.workspaces[position].isActive = document.workspaces[position].workspaceID == workspaceID
            }
            for position in document.panes.indices { document.panes[position].isActive = position == index }
            document.activity[paneID] = Date()
            try persistLocked()
        }
    }

    public func renamePane(_ paneID: String, name: String) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            document.panes[index].customName = trimmed.isEmpty ? nil : trimmed
            try persistLocked()
        }
    }

    public func restartPane(
        _ paneID: String,
        permissionProfile: EffectivePermissionProfile? = nil,
        launchMode: AgentLaunchMode = .fresh
    ) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            if document.panes[index].kind.isAgent, let relayRuntime {
                _ = try relayRuntime.credentials.rotate(paneID)
            }
            let profile = try effectivePermissionProfile(
                for: document.panes[index].kind,
                cwd: document.panes[index].cwd,
                supplied: permissionProfile,
                selection: document.panes[index].permissionSelection
            )
            terminalTransport?.terminate(paneID)
            copilotTrustConfirmations[paneID] = nil
            markStartedLocked(index: index, profile: profile)
            if document.panes[index].kind.isAgent {
                agentLaunchRequests[paneID] = AgentLaunchRequest(
                    generation: document.panes[index].launchGeneration,
                    mode: launchMode
                )
            } else {
                agentLaunchRequests[paneID] = nil
            }
            try persistLocked()
        }
    }

    public func startPane(
        _ paneID: String,
        permissionProfile: EffectivePermissionProfile? = nil,
        launchMode: AgentLaunchMode = .fresh
    ) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard document.panes[index].kind.isAgent, !document.panes[index].isStarted else { return }
            let profile = try effectivePermissionProfile(
                for: document.panes[index].kind,
                cwd: document.panes[index].cwd,
                supplied: permissionProfile,
                selection: document.panes[index].permissionSelection
            )
            markStartedLocked(index: index, profile: profile)
            agentLaunchRequests[paneID] = AgentLaunchRequest(
                generation: document.panes[index].launchGeneration,
                mode: launchMode
            )
            try persistLocked()
        }
    }

    /// Rebinds only an inert agent placeholder. A running process owns its
    /// cwd, so this route can never move or restart a live pane.
    public func setStoppedPaneFolder(_ paneID: String, folder: String) throws {
        try requireDirectory(folder)
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard document.panes[index].kind.isAgent, !document.panes[index].isStarted else {
                throw ParleyWorkbenchError.commandFailed(
                    "Only a stopped agent pane can choose a new working folder."
                )
            }
            document.panes[index].cwd = WorkspaceFolderIdentity.normalized(folder)
            document.panes[index].permissionSelection = nil
            document.panes[index].permissionEnforcement = nil
            try persistLocked()
        }
    }

    public func stopPaneProcess(_ paneID: String) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard document.panes[index].kind.isAgent, document.panes[index].isStarted else { return }
            terminalTransport?.terminate(paneID)
            copilotTrustConfirmations[paneID] = nil
            agentLaunchRequests[paneID] = nil
            document.panes[index].launchGeneration &+= 1
            document.panes[index].isStarted = false
            document.panes[index].isDead = false
            document.panes[index].inputAvailable = false
            document.panes[index].relayEnabled = false
            document.panes[index].protocolVersion = nil
            document.panes[index].currentCommand = "stopped"
            document.panes[index].vendorRuntimeState = nil
            document.panes[index].vendorRuntimeSignal = nil
            document.panes[index].vendorRuntimeSignaledAt = nil
            try relayRuntime?.credentials.forget(paneID)
            try persistLocked()
        }
    }

    public func closePane(_ paneID: String) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard document.panes.count > 1 else { throw ParleyWorkbenchError.cannotCloseLastPane }
            let workspaceID = document.panes[index].workspaceID
            terminalTransport?.terminate(paneID)
            copilotTrustConfirmations[paneID] = nil
            agentLaunchRequests[paneID] = nil
            document.panes.remove(at: index)
            document.activity[paneID] = nil
            try relayRuntime?.credentials.forget(paneID)
            if !document.panes.contains(where: { $0.workspaceID == workspaceID }) {
                document.workspaces.removeAll(where: { $0.workspaceID == workspaceID })
            }
            normalizeSelectionLocked()
            try persistLocked()
        }
    }

    public func closeWorkspace(_ workspaceID: String) throws {
        try lock.withLock {
            guard document.workspaces.count > 1 else { throw ParleyWorkbenchError.cannotCloseLastWorkspace }
            let workspace = document.workspaces[try workspaceIndexLocked(workspaceID)]
            let paneIDs = document.panes.filter { $0.workspaceID == workspace.workspaceID }.map(\.id)
            for paneID in paneIDs {
                terminalTransport?.terminate(paneID)
                copilotTrustConfirmations[paneID] = nil
                agentLaunchRequests[paneID] = nil
                try relayRuntime?.credentials.forget(paneID)
                document.activity[paneID] = nil
            }
            document.panes.removeAll(where: { $0.workspaceID == workspace.workspaceID })
            document.workspaces.removeAll(where: { $0.workspaceID == workspace.workspaceID })
            normalizeSelectionLocked()
            try persistLocked()
        }
    }

    public func shutdown() throws {
        try lock.withLock {
            for pane in document.panes { try relayRuntime?.credentials.forget(pane.id) }
            terminalTransport?.terminateAll()
            agentLaunchRequests.removeAll()
            copilotTrustConfirmations.removeAll()
            for index in document.panes.indices {
                document.panes[index].launchGeneration &+= 1
                document.panes[index].isStarted = false
                document.panes[index].inputAvailable = false
                document.panes[index].relayEnabled = false
                document.panes[index].protocolVersion = nil
                document.panes[index].currentCommand = "stopped"
                document.panes[index].vendorRuntimeState = nil
                document.panes[index].vendorRuntimeSignal = nil
                document.panes[index].vendorRuntimeSignaledAt = nil
            }
            document.ownerPID = 0
            document.ownerSessionID = nil
            try persistLocked()
        }
    }

    public func interruptPane(_ paneID: String) throws {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent, pane.isStarted, !pane.isDead else { throw ParleyWorkbenchError.notAgentPane }
        guard let terminalTransport else {
            throw ParleyWorkbenchError.commandFailed("The Ghostty pane is not attached to Parley.")
        }
        try terminalTransport.interrupt(paneID)
    }

    public func paneActivityTimestamps() throws -> [String: Date] {
        lock.withLock { document.activity }
    }

    public func capturePane(_ paneID: String) throws -> String {
        guard try listPanes().contains(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.paneNotFound(paneID)
        }
        guard let terminalTransport else { throw ParleyWorkbenchError.noRelayText }
        return try terminalTransport.captureSelectedText(paneID)
    }

    public func paste(_ text: String, into paneID: String, submit: Bool) throws {
        try pastePrepared(text, into: paneID, submit: submit)
    }

    public func pasteExplicitContext(_ text: String, into paneID: String, submit: Bool) throws {
        try pastePrepared(text, into: paneID, submit: submit)
    }

    @discardableResult
    public func movePane(
        _ paneID: String,
        toWorkspaceID targetWorkspaceID: String,
        activeHandoffCount: Int
    ) throws -> WorkbenchPane {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            let target = document.workspaces[try workspaceIndexLocked(targetWorkspaceID)]
            let assessment = PaneMobilityPolicy.assess(
                action: .move,
                pane: document.panes[index],
                targetWorkspaceID: target.workspaceID,
                panes: document.panes,
                activeHandoffCount: activeHandoffCount
            )
            guard assessment.isAllowed else { throw ParleyWorkbenchError.commandFailed(assessment.refusalText) }
            if let role = document.panes[index].role,
               document.panes.contains(where: {
                   $0.id != paneID && $0.workspaceID == target.workspaceID && $0.role == role
               }) {
                throw ParleyWorkbenchError.commandFailed("The target workspace already has @\(role).")
            }
            document.panes[index].workspaceID = target.workspaceID
            document.panes[index].workspaceName = target.name
            document.panes[index].automationPolicy = target.automationPolicy
            try persistLocked()
            return document.panes[index]
        }
    }

    @discardableResult
    public func clonePaneConfiguration(
        _ paneID: String,
        toWorkspaceID targetWorkspaceID: String,
        activeHandoffCount: Int
    ) throws -> WorkbenchPane {
        try lock.withLock {
            guard let source = document.panes.first(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            let target = document.workspaces[try workspaceIndexLocked(targetWorkspaceID)]
            let assessment = PaneMobilityPolicy.assess(
                action: .clone,
                pane: source,
                targetWorkspaceID: target.workspaceID,
                panes: document.panes,
                activeHandoffCount: activeHandoffCount
            )
            guard assessment.isAllowed else { throw ParleyWorkbenchError.commandFailed(assessment.refusalText) }
            var clone = source
            clone.id = Self.paneID()
            clone.workspaceID = target.workspaceID
            clone.workspaceName = target.name
            clone.automationPolicy = target.automationPolicy
            clone.inputAvailable = false
            clone.isActive = false
            clone.isWorkspaceLead = false
            clone.launchGeneration = 0
            clone.isDead = false
            clone.exitStatus = nil
            if clone.kind.isAgent {
                clone.isStarted = false
                clone.relayEnabled = false
                clone.protocolVersion = nil
                clone.currentCommand = "stopped"
                clone.vendorRuntimeState = nil
                clone.vendorRuntimeSignal = nil
                clone.vendorRuntimeSignaledAt = nil
            }
            document.panes.append(clone)
            document.activity[clone.id] = Date()
            try persistLocked()
            return clone
        }
    }

    public func restoreWorkspaceLayout(
        _ layout: SavedWorkspaceLayout,
        replacing replacedWorkspaceID: String? = nil,
        folderless: Bool = false
    ) throws -> WorkbenchWorkspace {
        try requireDirectory(layout.defaultFolder)
        for leaf in layout.root.leaves { try requireDirectory(leaf.folder) }
        return try lock.withLock {
            let replacement = try replacedWorkspaceID.map { document.workspaces[try workspaceIndexLocked($0)] }
            let workspace = try createWorkspaceLocked(
                launchFolder: layout.defaultFolder,
                name: layout.name,
                attachedFolders: folderless
                    ? []
                    : (replacement?.attachedFolders ?? [layout.defaultFolder]),
                newPaneFolder: folderless ? nil : layout.defaultFolder
            )
            document.panes.removeAll(where: { $0.workspaceID == workspace.workspaceID })
            for leaf in layout.root.leaves {
                let profile = if folderless && leaf.kind.isAgent {
                    Optional<EffectivePermissionProfile>.none
                } else {
                    try effectivePermissionProfile(
                        for: leaf.kind,
                        cwd: leaf.folder,
                        supplied: nil,
                        selection: leaf.permissionSelection
                    )
                }
                var pane = makePane(
                    kind: leaf.kind,
                    cwd: leaf.folder,
                    workspace: workspace,
                    started: leaf.kind == .shell,
                    permissionProfile: profile
                )
                pane.customName = leaf.name == leaf.kind.label ? nil : leaf.name
                pane.role = leaf.role
                pane.isWorkspaceLead = leaf.isWorkspaceLead
                document.panes.append(pane)
                document.activity[pane.id] = Date()
            }
            if let replacement {
                let oldIDs = document.panes.filter { $0.workspaceID == replacement.workspaceID }.map(\.id)
                for id in oldIDs {
                    terminalTransport?.terminate(id)
                    copilotTrustConfirmations[id] = nil
                    agentLaunchRequests[id] = nil
                    try relayRuntime?.credentials.forget(id)
                }
                document.panes.removeAll(where: { $0.workspaceID == replacement.workspaceID })
                document.workspaces.removeAll(where: { $0.workspaceID == replacement.workspaceID })
            }
            try selectWorkspaceLocked(workspace.workspaceID)
            try persistLocked()
            return document.workspaces.first(where: { $0.workspaceID == workspace.workspaceID }) ?? workspace
        }
    }

    public func launchConfiguration(for paneID: String) throws -> GhosttyPaneLaunch {
        try lock.withLock {
            guard let pane = document.panes.first(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard pane.isStarted, !pane.isDead else {
                throw ParleyWorkbenchError.commandFailed("\(pane.displayName) is stopped.")
            }
            var launchEnvironment: [String: String] = [
                "PARLEY_PANE": "1",
                "PARLEY_PANE_ID": pane.id,
                "PARLEY_PANE_KIND": pane.kind.rawValue,
                "PARLEY_APP_PID": String(ProcessInfo.processInfo.processIdentifier),
            ]
            var argv: [String]
            if pane.kind == .shell {
                // Ghostty overlays envVars on its process environment. Remove
                // inherited authority before the login shell starts.
                let metadataKeys = Set(launchEnvironment.keys)
                let inheritedKeys = Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("PARLEY_") })
                    .union(["PARLEY_RELAY_TOKEN", "PARLEY_PROTOCOL_VERSION", "PARLEY_COMMAND", "PARLEY_RUNTIME", "PARLEY_SWIFT_COMMAND", "PARLEY_SWIFTPM_COMPATIBILITY", "TMUX", "TMUX_PANE"])
                    .subtracting(metadataKeys)
                argv = ["/usr/bin/env"] + inheritedKeys.sorted().flatMap { ["-u", $0] }
                if let marker = relayRuntime?.runtimeMarker { argv += ["PARLEY_RUNTIME=\(marker)"] }
                launchEnvironment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
                if let approved = approvedShellLaunches.removeValue(forKey: pane.id), approved.generation == pane.launchGeneration {
                    argv += approved.argv
                } else {
                    argv += [loginShellExecutable().path, "-l"]
                }
            } else {
                guard let relayRuntime else {
                    throw ParleyWorkbenchError.commandFailed(
                        "Parley cannot start an agent without its protected relay boundary. Shell panes remain available."
                    )
                }
                let token = try relayRuntime.credentials.token(for: pane.id)
                launchEnvironment["PARLEY_RELAY_TOKEN"] = token
                launchEnvironment["PARLEY_PROTOCOL_VERSION"] = AgentProtocol.version
                if swiftPMLaunches[pane.id]?.generation != pane.launchGeneration {
                    let liveIDs = Set(document.panes.map(\.id))
                    swiftPMLaunches = swiftPMLaunches.filter { liveIDs.contains($0.key) }
                    swiftPMLaunches[pane.id] = (pane.launchGeneration, swiftPMCompatibilityEnabled)
                }
                let swiftPMEnabled = swiftPMLaunches[pane.id]?.enabled == true
                launchEnvironment["PARLEY_SWIFT_COMMAND"] = swiftPMDirectory.appendingPathComponent("swift").path
                launchEnvironment["PARLEY_SWIFTPM_COMPATIBILITY"] = swiftPMEnabled ? "1" : "0"
                let swiftPMPath = swiftPMEnabled ? "\(swiftPMDirectory.path):" : ""
                launchEnvironment["PATH"] = "\(relayRuntime.shimDirectory.path):\(swiftPMPath)\(environment["PATH"] ?? "/usr/bin:/bin")"
                if let marker = relayRuntime.runtimeMarker { launchEnvironment["PARLEY_RUNTIME"] = marker }
                for (key, value) in AgentProtocol.environment(
                    for: pane.kind,
                    protocolDirectory: protocolDirectory,
                    commandPath: relayRuntime.shimDirectory.appendingPathComponent("parley"),
                    inherited: environment
                ) { launchEnvironment[key] = value }
                let boundary = try AgentProcessBoundary(
                    applicationDirectory: applicationDirectory,
                    protocolDirectory: protocolDirectory,
                    shimDirectory: relayRuntime.shimDirectory,
                    protectedControlEndpoint: applicationDirectory.appendingPathComponent("relay.sock"),
                    transportDirectory: relayRuntime.transportDirectory,
                    paneToken: token,
                    fileManager: fileManager
                )
                argv = boundary.arguments + ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE"]
                let launchMode = agentLaunchRequests[pane.id].flatMap {
                    $0.generation == pane.launchGeneration ? $0.mode : nil
                } ?? .fresh
                var command = AgentProtocol.command(
                    for: pane.kind,
                    protocolDirectory: protocolDirectory,
                    launchMode: launchMode
                )
                if let profile = try effectivePermissionProfile(
                    for: pane.kind,
                    cwd: pane.cwd,
                    supplied: nil,
                    selection: pane.permissionSelection
                ) {
                    command.append(contentsOf: PermissionProfileAdapter.launchPlan(
                        for: pane.kind,
                        profile: profile
                    ).arguments)
                }
                argv.append(contentsOf: command)
            }
            return GhosttyPaneLaunch(
                paneID: pane.id,
                generation: pane.launchGeneration,
                workingDirectory: pane.cwd,
                environment: launchEnvironment,
                command: GhosttyLaunchCommand.render(argv)
            )
        }
    }

    public func terminalDidChangeTitle(paneID: String, title: String) throws {
        try updatePaneRuntime(paneID: paneID) { $0.terminalTitle = title }
    }

    public func terminalDidChangeWorkingDirectory(paneID: String, path: String) throws {
        guard path.hasPrefix("/") else { return }
        try lock.withLock {
            if document.panes.first(where: { $0.id == paneID })?.cwd != path {
                copilotTrustConfirmations.removeValue(forKey: paneID)
            }
            try updatePaneRuntime(paneID: paneID) { $0.cwd = path }
        }
    }

    public func recordVendorSignal(
        paneID: String,
        signal: VendorHookSignal,
        occurredAt: Date
    ) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            let pane = document.panes[index]
            guard pane.kind.isAgent, pane.isStarted, !pane.isDead,
                  pane.relayEnabled, pane.hasCurrentProtocol else {
                throw ParleyWorkbenchError.commandFailed(
                    "Parley refused a lifecycle signal from an inactive agent pane."
                )
            }
            guard VendorHookAdapter.supportedSignals(for: pane.kind).contains(signal) else {
                throw ParleyWorkbenchError.commandFailed(
                    "\(pane.kind.label) has no supported Parley hook for \(signal.rawValue)."
                )
            }
            if signal == .sessionEnded { copilotTrustConfirmations.removeValue(forKey: paneID) }
            document.panes[index].vendorRuntimeState = signal.runtimeState(
                after: document.panes[index].vendorRuntimeState
            )
            document.panes[index].vendorRuntimeSignal = signal
            document.panes[index].vendorRuntimeSignaledAt = occurredAt
            document.activity[paneID] = occurredAt
        }
    }

    public func terminalDidAttach(paneID: String) throws {
        try updatePaneRuntime(paneID: paneID) {
            $0.inputAvailable = $0.isStarted && !$0.isDead
        }
    }

    public func terminalDidDetach(paneID: String) throws {
        try updatePaneRuntime(paneID: paneID) { $0.inputAvailable = false }
    }

    public func terminalDidClose(paneID: String, processAlive: Bool, exitStatus: Int? = nil) throws {
        if !processAlive { lock.withLock { copilotTrustConfirmations[paneID] = nil } }
        try updatePaneRuntime(paneID: paneID) {
            $0.isDead = !processAlive
            $0.exitStatus = processAlive ? nil : exitStatus
            $0.relayEnabled = processAlive && $0.kind.isAgent
            if !processAlive {
                $0.inputAvailable = false
                $0.currentCommand = "exited"
                $0.vendorRuntimeState = nil
                $0.vendorRuntimeSignal = nil
                $0.vendorRuntimeSignaledAt = nil
            }
        }
    }

    private func updatePaneRuntime(paneID: String, mutation: (inout WorkbenchPane) -> Void) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else { return }
            mutation(&document.panes[index])
            document.activity[paneID] = Date()
            try persistLocked()
        }
    }

    private func pastePrepared(_ text: String, into paneID: String, submit: Bool) throws {
        let pane = try requireRelayPane(paneID)
        guard let terminalTransport else {
            throw ParleyWorkbenchError.unsafeRelayTarget(pane.displayName)
        }
        try terminalTransport.paste(paneID, text, submit)
        lock.withLock { document.activity[paneID] = Date() }
    }

    /// Native UI only: confirms the person has resolved Copilot's own folder
    /// trust prompt. Never grants vendor permissions or survives a new launch.
    public func confirmCopilotFolderTrust(paneID: String, expectedGeneration: Int, expectedFolder: String) throws {
        try lock.withLock {
            guard let pane = document.panes.first(where: { $0.id == paneID }),
                  pane.kind == .copilot, pane.isStarted, !pane.isDead,
                  pane.launchGeneration == expectedGeneration, pane.cwd == expectedFolder else {
                throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
            }
            copilotTrustConfirmations[paneID] = expectedGeneration
        }
    }

    private func requireRelayPane(_ paneID: String) throws -> WorkbenchPane {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent, pane.isStarted, !pane.isDead,
              pane.relayEnabled, pane.hasCurrentProtocol, pane.inputAvailable else {
            throw ParleyWorkbenchError.unsafeRelayTarget(pane.displayName)
        }
        if pane.kind == .copilot,
           lock.withLock({ copilotTrustConfirmations[pane.id] }) != pane.launchGeneration {
            throw ParleyWorkbenchError.copilotTrustRequired
        }
        return pane
    }

    private func validateDistinctAgents(_ sourceID: String, _ targetID: String) throws {
        let panes = try listPanes()
        guard sourceID != targetID else { throw ParleyWorkbenchError.samePane }
        guard let source = panes.first(where: { $0.id == sourceID }),
              let target = panes.first(where: { $0.id == targetID }) else {
            throw ParleyWorkbenchError.paneNotFound(targetID)
        }
        guard source.kind.isAgent, target.kind.isAgent else { throw ParleyWorkbenchError.notAgentPane }
    }

    private func createWorkspaceLocked(
        launchFolder: String,
        name: String?,
        attachedFolders: [String],
        newPaneFolder: String?
    ) throws -> WorkbenchWorkspace {
        let baseName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedName = attachedFolders.first.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let proposed = baseName?.isEmpty == false ? baseName! : (attachedName ?? "Workspace")
        let resolvedName = availableWorkspaceNameLocked(proposed.isEmpty ? "Workspace" : proposed)
        let id = Self.workspaceID()
        for index in document.workspaces.indices { document.workspaces[index].isActive = false }
        for index in document.panes.indices { document.panes[index].isActive = false }
        let workspace = WorkbenchWorkspace(
            id: id,
            name: resolvedName,
            attachedFolders: attachedFolders,
            newPaneFolder: newPaneFolder,
            isActive: true,
            automationPolicy: .askAndDelegate,
            workspaceID: id
        )
        document.workspaces.append(workspace)
        let pane = makePane(
            kind: .shell,
            cwd: launchFolder,
            workspace: workspace,
            started: true,
            permissionProfile: nil
        )
        document.panes.append(pane)
        document.activity[pane.id] = Date()
        return workspace
    }

    private func makePane(
        kind: PaneKind,
        cwd: String,
        workspace: WorkbenchWorkspace,
        started: Bool,
        permissionProfile: EffectivePermissionProfile?
    ) -> WorkbenchPane {
        let plan = permissionProfile.map { PermissionProfileAdapter.launchPlan(for: kind, profile: $0) }
        let paneID = Self.paneID()
        return WorkbenchPane(
            id: paneID,
            kind: kind,
            customName: nil,
            terminalTitle: kind.label,
            cwd: cwd,
            currentCommand: started ? (kind == .shell ? loginShellExecutable().lastPathComponent : kind.rawValue) : "stopped",
            isActive: true,
            workspaceID: workspace.workspaceID,
            relayEnabled: started && kind.isAgent && relayRuntime != nil,
            protocolVersion: started && kind.isAgent ? AgentProtocol.version : nil,
            workspaceName: workspace.name,
            inputAvailable: false,
            isDead: false,
            exitStatus: nil,
            isStarted: started,
            isWorkspaceLead: false,
            role: nil,
            automationPolicy: workspace.automationPolicy,
            permissionSelection: permissionProfile?.selection,
            permissionEnforcement: plan?.enforcement,
            launchGeneration: 0
        )
    }

    private func markStartedLocked(index: Int, profile: EffectivePermissionProfile?) {
        copilotTrustConfirmations[document.panes[index].id] = nil
        document.panes[index].launchGeneration &+= 1
        document.panes[index].isStarted = true
        document.panes[index].isDead = false
        document.panes[index].exitStatus = nil
        document.panes[index].inputAvailable = false
        document.panes[index].relayEnabled = document.panes[index].kind.isAgent && relayRuntime != nil
        document.panes[index].protocolVersion = document.panes[index].kind.isAgent ? AgentProtocol.version : nil
        document.panes[index].currentCommand = document.panes[index].kind.rawValue
        document.panes[index].permissionSelection = profile?.selection
        document.panes[index].vendorRuntimeState = nil
        document.panes[index].vendorRuntimeSignal = nil
        document.panes[index].vendorRuntimeSignaledAt = nil
        document.panes[index].permissionEnforcement = profile.map {
            PermissionProfileAdapter.launchPlan(for: document.panes[index].kind, profile: $0).enforcement
        }
        document.activity[document.panes[index].id] = Date()
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
        let chosen = selection.flatMap { saved in profiles.first(where: { $0.id == saved.profileID }) }
            ?? profiles.first(where: { $0.id == "default" })
        guard let chosen else {
            throw ParleyWorkbenchError.commandFailed("The Default permission profile is unavailable.")
        }
        return try PermissionProfileResolver.resolve(
            definition: chosen,
            paneFolder: cwd,
            approvedRoots: chosen.rootMode == .exactApprovedRoots ? (selection?.approvedRoots ?? [cwd]) : [],
            fileManager: fileManager
        )
    }

    private func workspaceIndexLocked(_ reference: String) throws -> Int {
        guard let index = document.workspaces.firstIndex(where: {
            $0.id == reference || $0.workspaceID == reference
        }) else { throw ParleyWorkbenchError.workspaceNotFound(reference) }
        return index
    }

    private func selectWorkspaceLocked(_ workspaceID: String) throws {
        let index = try workspaceIndexLocked(workspaceID)
        let durableID = document.workspaces[index].workspaceID
        for position in document.workspaces.indices { document.workspaces[position].isActive = position == index }
        if let paneIndex = document.panes.firstIndex(where: { $0.workspaceID == durableID }) {
            for position in document.panes.indices { document.panes[position].isActive = position == paneIndex }
        }
    }

    private func normalizeSelectionLocked() {
        if !document.workspaces.contains(where: \.isActive), !document.workspaces.isEmpty {
            document.workspaces[0].isActive = true
        }
        guard let workspace = document.workspaces.first(where: \.isActive) else { return }
        if !document.panes.contains(where: { $0.workspaceID == workspace.workspaceID && $0.isActive }),
           let first = document.panes.firstIndex(where: { $0.workspaceID == workspace.workspaceID }) {
            for index in document.panes.indices { document.panes[index].isActive = index == first }
        }
    }

    private func availableWorkspaceNameLocked(_ proposed: String) -> String {
        guard document.workspaces.contains(where: {
            $0.name.caseInsensitiveCompare(proposed) == .orderedSame
        }) else { return proposed }
        var suffix = 2
        while document.workspaces.contains(where: {
            $0.name.caseInsensitiveCompare("\(proposed) \(suffix)") == .orderedSame
        }) { suffix += 1 }
        return "\(proposed) \(suffix)"
    }

    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: stateFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ParleyWorkbenchError.invalidDirectory(path)
        }
    }

    private func loginShellExecutable() -> URL {
        let candidate = environment["SHELL"] ?? "/bin/zsh"
        if candidate.hasPrefix("/"), fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/bin/zsh")
    }

    private static func workspaceID() -> String { "workspace-\(UUID().uuidString.lowercased())" }
    private static func paneID() -> String { "pane-\(UUID().uuidString.lowercased())" }

    private static func scrubInheritedCapabilities(_ source: [String: String]) -> [String: String] {
        var scrubbed = source
        for key in source.keys where key.hasPrefix("PARLEY_") {
            scrubbed[key] = nil
        }
        var managedBins = Set(ParleyRuntime.controlDirectories().flatMap {
            [$0.appendingPathComponent("bin").path, SwiftPMCompatibility.directory(in: $0).path]
        })
        if let helper = source["PARLEY_SWIFT_COMMAND"], helper.hasSuffix("/agent-protocol/swiftpm-bin/swift") {
            managedBins.insert(URL(fileURLWithPath: helper).deletingLastPathComponent().path)
        }
        if let path = scrubbed["PATH"] {
            scrubbed["PATH"] = path.split(separator: ":", omittingEmptySubsequences: false)
                .filter { !managedBins.contains(String($0)) }.joined(separator: ":")
        }
        scrubbed["TMUX"] = nil
        scrubbed["TMUX_PANE"] = nil
        return scrubbed
    }
}
