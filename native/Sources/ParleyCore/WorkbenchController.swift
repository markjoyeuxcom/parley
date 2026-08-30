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
    }

    public let applicationDirectory: URL
    public let protocolDirectory: URL
    public let environment: [String: String]

    private let stateFile: URL
    private let fileManager: FileManager
    private let permissionProfileStore: PermissionProfileStore
    private let lock = NSRecursiveLock()
    private var document: Document
    private var relayRuntime: RelayRuntime?
    private var terminalTransport: PaneTerminalTransport?

    public init(
        applicationDirectory: URL? = nil,
        environment: [String: String]? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = applicationDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)
        self.applicationDirectory = directory
        self.environment = Self.scrubInheritedCapabilities(environment ?? EnvironmentResolver.resolved())
        self.fileManager = fileManager
        stateFile = directory.appendingPathComponent("workbench-state.json")
        permissionProfileStore = PermissionProfileStore(
            file: directory.appendingPathComponent("permission-profiles.json"),
            fileManager: fileManager
        )

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        protocolDirectory = try AgentProtocol.install(in: directory, fileManager: fileManager)

        if fileManager.fileExists(atPath: stateFile.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            document = try decoder.decode(Document.self, from: Data(contentsOf: stateFile))
        } else {
            document = Document(workspaces: [], panes: [], activity: [:], ownerPID: 0)
        }
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
            if document.ownerPID != currentPID {
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
                    } else {
                        document.panes[index].isStarted = true
                        document.panes[index].currentCommand = loginShellExecutable().lastPathComponent
                    }
                }
                document.ownerPID = currentPID
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
        permissionProfile: EffectivePermissionProfile? = nil
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
            markStartedLocked(index: index, profile: profile)
            try persistLocked()
        }
    }

    public func startPane(
        _ paneID: String,
        permissionProfile: EffectivePermissionProfile? = nil
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
            document.panes[index].launchGeneration &+= 1
            document.panes[index].isStarted = false
            document.panes[index].isDead = false
            document.panes[index].inputAvailable = false
            document.panes[index].relayEnabled = false
            document.panes[index].protocolVersion = nil
            document.panes[index].currentCommand = "stopped"
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
            for index in document.panes.indices {
                document.panes[index].launchGeneration &+= 1
                document.panes[index].isStarted = false
                document.panes[index].inputAvailable = false
                document.panes[index].relayEnabled = false
                document.panes[index].protocolVersion = nil
                document.panes[index].currentCommand = "stopped"
            }
            document.ownerPID = 0
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
                for id in oldIDs { terminalTransport?.terminate(id); try relayRuntime?.credentials.forget(id) }
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
                argv = [loginShellExecutable().path, "-l"]
            } else {
                guard let relayRuntime else {
                    throw ParleyWorkbenchError.commandFailed(
                        "Parley cannot start an agent without its protected relay boundary. Shell panes remain available."
                    )
                }
                let token = try relayRuntime.credentials.token(for: pane.id)
                launchEnvironment["PARLEY_RELAY_TOKEN"] = token
                launchEnvironment["PARLEY_PROTOCOL_VERSION"] = AgentProtocol.version
                launchEnvironment["PATH"] = "\(relayRuntime.shimDirectory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
                if let marker = relayRuntime.runtimeMarker { launchEnvironment["PARLEY_RUNTIME"] = marker }
                for (key, value) in AgentProtocol.environment(
                    for: pane.kind,
                    protocolDirectory: protocolDirectory,
                    inherited: environment
                ) { launchEnvironment[key] = value }
                let boundary = try AgentProcessBoundary(
                    applicationDirectory: applicationDirectory,
                    protocolDirectory: protocolDirectory,
                    shimDirectory: relayRuntime.shimDirectory,
                    transportDirectory: relayRuntime.transportDirectory,
                    paneToken: token,
                    fileManager: fileManager
                )
                argv = boundary.arguments + ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE"]
                var command = AgentProtocol.command(for: pane.kind, protocolDirectory: protocolDirectory)
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
        try updatePaneRuntime(paneID: paneID) { $0.cwd = path }
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
        try updatePaneRuntime(paneID: paneID) {
            $0.isDead = !processAlive
            $0.exitStatus = processAlive ? nil : exitStatus
            $0.relayEnabled = processAlive && $0.kind.isAgent
            if !processAlive {
                $0.inputAvailable = false
                $0.currentCommand = "exited"
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

    private func requireRelayPane(_ paneID: String) throws -> WorkbenchPane {
        guard let pane = try listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.paneNotFound(paneID)
        }
        guard pane.kind.isAgent, pane.isStarted, !pane.isDead,
              pane.relayEnabled, pane.hasCurrentProtocol, pane.inputAvailable else {
            throw ParleyWorkbenchError.unsafeRelayTarget(pane.displayName)
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
        document.panes[index].launchGeneration &+= 1
        document.panes[index].isStarted = true
        document.panes[index].isDead = false
        document.panes[index].exitStatus = nil
        document.panes[index].inputAvailable = false
        document.panes[index].relayEnabled = document.panes[index].kind.isAgent && relayRuntime != nil
        document.panes[index].protocolVersion = document.panes[index].kind.isAgent ? AgentProtocol.version : nil
        document.panes[index].currentCommand = document.panes[index].kind.rawValue
        document.panes[index].permissionSelection = profile?.selection
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
        scrubbed["TMUX"] = nil
        scrubbed["TMUX_PANE"] = nil
        return scrubbed
    }
}
