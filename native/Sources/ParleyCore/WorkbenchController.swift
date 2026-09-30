import Foundation

public struct GhosttyPaneLaunch: Equatable, Sendable {
    public let paneID: String
    public let generation: Int
    public let workingDirectory: String
    public let environment: [String: String]
    public let command: String
    /// The terminal type the launched process sees: the preference read for
    /// this generation, or Docker's fixed value for a container pane.
    public let terminalType: TerminalTypePreference

    public init(
        paneID: String,
        generation: Int,
        workingDirectory: String,
        environment: [String: String],
        command: String,
        terminalType: TerminalTypePreference = .default
    ) {
        self.paneID = paneID
        self.generation = generation
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.command = command
        self.terminalType = terminalType
    }
}

/// The small synchronous input surface the coordination broker needs. Its
/// implementation is Parley's retained Ghostty view registry in the app
/// process; no terminal multiplexer or second PTY owner sits underneath it.
public struct PaneTerminalTransport: @unchecked Sendable {
    public let paste: (_ paneID: String, _ text: String, _ submit: Bool) throws -> Void
    public let voicePaste: ((_ paneID: String, _ text: String, _ submit: Bool, _ reviewed: [VoiceDestination]) throws -> Void)?
    public let interrupt: (_ paneID: String) throws -> Void
    public let captureSelectedText: (_ paneID: String) throws -> String
    public let terminate: (_ paneID: String) -> Void
    public let terminateAll: () -> Void

    public init(
        paste: @escaping (_ paneID: String, _ text: String, _ submit: Bool) throws -> Void,
        voicePaste: ((_ paneID: String, _ text: String, _ submit: Bool, _ reviewed: [VoiceDestination]) throws -> Void)? = nil,
        interrupt: @escaping (_ paneID: String) throws -> Void,
        captureSelectedText: @escaping (_ paneID: String) throws -> String,
        terminate: @escaping (_ paneID: String) -> Void,
        terminateAll: @escaping () -> Void
    ) {
        self.paste = paste
        self.voicePaste = voicePaste
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
        /// The person's workspace groups, in order. Optional so state written
        /// before groups existed (30 September 2026) still decodes.
        var workspaceGroups: [WorkspaceGroup]?
    }
    private var approvedShellLaunches: [String: (generation: Int, argv: [String])] = [:]
    /// Greater than zero while a surface is being terminated. Ghostty reports
    /// the close synchronously from inside that call, and the report refreshes
    /// the app; no lifecycle mutation may start from inside it.
    private var terminatingDepth = 0
    public var isTerminatingSurface: Bool { lock.withLock { terminatingDepth > 0 } }

    /// Every surface termination goes through here so the re-entrancy guard
    /// covers each lifecycle path alike.
    /// Whether a pane's surface may end now. Checked for every pane before
    /// any of them ends, so an operation over several panes (closing or
    /// replacing a workspace) is refused whole rather than stopping part-way
    /// after ending some.
    private func requireTerminableLocked(_ paneID: String) throws {
        if let pane = document.panes.first(where: { $0.id == paneID }), pane.containerConfiguration != nil {
            guard confirmedContainerStops[paneID] == pane.launchGeneration else {
                throw ContainerPaneError.refused("Stop this container through its native action before ending the pane.")
            }
        }
        guard !containerPreparations.contains(paneID), preparedContainerIDs[paneID] == nil || confirmedContainerStops[paneID] == document.panes.first(where: { $0.id == paneID })?.launchGeneration else {
            throw ContainerPaneError.refused("This pane's prepared container must be removed before closing it.")
        }
    }

    private func terminateSurface(_ paneID: String) throws {
        try requireTerminableLocked(paneID)
        endSurfaceLocked(paneID)
    }

    /// Ends a surface without checking it, raising `terminatingDepth` as
    /// `terminateSurface` does. Only for an operation that checked the pane
    /// with `requireTerminableLocked` under this same lock and then saved its
    /// change: the check reads the document, and after the change it can
    /// refuse a pane that passed (a removed pane still holding a prepared
    /// container receipt), leaving a process running behind a saved close.
    private func endSurfaceLocked(_ paneID: String) {
        preparedContainerIDs[paneID] = nil
        terminatingDepth += 1
        defer { terminatingDepth -= 1 }
        terminalTransport?.terminate(paneID)
    }

    private func requireAllTerminableLocked() throws {
        guard containerPreparations.isEmpty, document.panes.allSatisfy({
            $0.containerConfiguration == nil || confirmedContainerStops[$0.id] == $0.launchGeneration
        }) else { throw ContainerPaneError.refused("Container cleanup must finish before Parley can stop.") }
    }

    /// Ends every surface, for a shutdown that checked
    /// `requireAllTerminableLocked` before it stopped every pane. Checking again
    /// after the generations advanced refuses every container pane.
    private func endAllSurfacesLocked() {
        preparedContainerIDs.removeAll()
        terminatingDepth += 1
        defer { terminatingDepth -= 1 }
        terminalTransport?.terminateAll()
    }

    /// Lifecycle mutations (close, restart, stop, start, workspace close,
    /// layout replacement) refuse to begin from inside a termination. A
    /// refresh triggered by a synchronous close report retries later instead
    /// of mutating a document another operation is still changing.
    private func requireNoTerminationInProgress() throws {
        guard !isShutDown else { throw ParleyWorkbenchError.commandFailed("Parley has shut down; a pending launch cannot start another process.") }
        guard terminatingDepth == 0 else {
            throw ParleyWorkbenchError.commandFailed("A pane is being terminated; this change can be retried once it has finished.")
        }
    }
    private static let processSessionID = UUID().uuidString

    /// Runs a document change and saves it, putting the document back when the
    /// change or the save fails, so memory never holds what disk does not.
    private func commitLocked<T>(_ change: () throws -> T) throws -> T {
        let previous = document
        do {
            let result = try change()
            try persistLocked()
            return result
        } catch {
            document = previous
            throw error
        }
    }

    private struct AgentLaunchRequest {
        let generation: Int
        let mode: AgentLaunchMode
    }

    public let containerService: ContainerPaneService
    private struct PreparedContainer {
        let generation: Int
        let id: String
        let configuration: ContainerConfiguration
        let mode: AgentLaunchMode
        let profile: EffectivePermissionProfile
        let folder: String
        let workspaceID: String
        let automationPolicy: WorkspaceAutomationPolicy
    }
    private var preparedContainerIDs: [String: PreparedContainer] = [:]
    private var confirmedContainerStops: [String: Int] = [:]
    private var containerPreparations: Set<String> = []

    public let applicationDirectory: URL
    public let protocolDirectory: URL
    private let swiftPMDirectory: URL
    private var swiftPMCompatibilityEnabled: Bool
    private var swiftPMLaunches: [String: (generation: Int, enabled: Bool)] = [:]
    private var terminalTypePreference: TerminalTypePreference
    /// The terminal type each pane's current generation launched with, so a
    /// later setting change never alters a retained process.
    private var terminalTypeLaunches: [String: (generation: Int, type: TerminalTypePreference)] = [:]
    /// The profile actually carried by each host launch. Editing the store
    /// changes future launches, never the running process or its ticket policy.
    private var hostPermissionLaunches: [String: (generation: Int, profile: EffectivePermissionProfile?, claudeSandbox: ClaudeSandboxFact?, folder: String)] = [:]
    private var deliveringPaneIDs: Set<String> = []
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

    /// Terminal titles change many times a second while a vendor CLI works.
    /// They are applied in memory at once and written to the state file at
    /// most once per interval; every other persist, stop, close and shutdown
    /// carries a pending title with it immediately.
    private let titlePersistenceInterval: TimeInterval
    private let deferredPersistenceQueue = DispatchQueue(label: "parley.workbench.deferred-persistence", qos: .utility)
    private var titlePersistencePending = false
    private var titlePersistenceScheduled = false
    private var isShutDown = false
    private var persistWriteCountStorage = 0
    private var lastDeferredPersistenceErrorStorage: String?
    /// Diagnostics for checks and measurements: state-file writes so far.
    /// Read under the same lock the deferred queue writes them under.
    public var persistWriteCount: Int { lock.withLock { persistWriteCountStorage } }
    /// The last deferred write failure; cleared by the next successful write.
    public var lastDeferredPersistenceError: String? { lock.withLock { lastDeferredPersistenceErrorStorage } }

    public init(
        applicationDirectory: URL? = nil,
        environment: [String: String]? = nil,
        swiftPMCompatibilityEnabled: Bool = false,
        terminalTypePreference: TerminalTypePreference = .default,
        fileManager: FileManager = .default,
        titlePersistenceInterval: TimeInterval = 1,
        containerService: ContainerPaneService? = nil
    ) throws {
        let directory = applicationDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)
        self.applicationDirectory = directory
        self.titlePersistenceInterval = max(0.05, titlePersistenceInterval)
        self.environment = Self.scrubInheritedCapabilities(environment ?? EnvironmentResolver.resolved())
        self.containerService = try containerService ?? ContainerPaneService(directory: directory, environment: self.environment)
        self.fileManager = fileManager
        self.swiftPMCompatibilityEnabled = swiftPMCompatibilityEnabled
        self.terminalTypePreference = terminalTypePreference
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

    /// The terminal type for panes started or restarted from now on. A pane
    /// that is already running keeps the value its generation launched with.
    public func setTerminalTypePreference(_ preference: TerminalTypePreference) {
        lock.withLock { terminalTypePreference = preference }
    }

    /// Network permission carried by this exact live Codex generation, or
    /// unknown when no reviewed launch has been recorded. Never consults
    /// the editable profile store on behalf of an already-running process.
    public func hostNetworkAllowed(for pane: WorkbenchPane) -> Bool? {
        lock.withLock {
            guard let current = document.panes.first(where: { $0.id == pane.id }),
                  current.launchGeneration == pane.launchGeneration,
                  current.kind == .codex, current.containerConfiguration == nil,
                  current.isStarted, !current.isDead,
                  let launch = hostPermissionLaunches[pane.id], launch.generation == current.launchGeneration,
                  let profile = launch.profile else { return nil }
            return profile.definition.rule(for: .networkAccess) == .allow
        }
    }

    public func hostClaudeSandbox(for pane: WorkbenchPane) -> ClaudeSandboxFact? {
        lock.withLock {
            guard let current = document.panes.first(where: { $0.id == pane.id }),
                  current.launchGeneration == pane.launchGeneration, current.kind == .claude,
                  current.containerConfiguration == nil, current.isStarted, !current.isDead,
                  let launch = hostPermissionLaunches[pane.id], launch.generation == current.launchGeneration else { return nil }
            return launch.claudeSandbox
        }
    }

    /// Definitions actually selected for live generations, including containers.
    /// Used for advisory writer warnings; edits to the profile store affect no
    /// already-running process.
    public func runningPermissionDefinitions() -> [String: PermissionProfileDefinition] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: document.panes.compactMap { pane in
                guard pane.kind.isAgent, pane.isStarted, !pane.isDead,
                      let launch = hostPermissionLaunches[pane.id], launch.generation == pane.launchGeneration,
                      let profile = launch.profile else { return nil }
                return (pane.id, profile.definition)
            })
        }
    }

    private func recordLaunchPermissionsLocked(_ pane: WorkbenchPane, profile: EffectivePermissionProfile?) {
        let liveIDs = Set(document.panes.map(\.id))
        hostPermissionLaunches = hostPermissionLaunches.filter { liveIDs.contains($0.key) }
        let sandbox = pane.kind == .claude && pane.containerConfiguration == nil
            ? ClaudeHostConfiguration.sandbox(folder: pane.launchWorkingDirectory, environment: environment) : nil
        hostPermissionLaunches[pane.id] = (pane.launchGeneration, profile, sandbox, pane.launchWorkingDirectory)
    }

    private func hostPermissionProfileForLaunchLocked(_ pane: WorkbenchPane) throws -> EffectivePermissionProfile? {
        if let launch = hostPermissionLaunches[pane.id], launch.generation == pane.launchGeneration {
            return launch.profile
        }
        let profile = try effectivePermissionProfile(for: pane.kind, cwd: pane.launchWorkingDirectory, supplied: nil, selection: pane.permissionSelection)
        recordLaunchPermissionsLocked(pane, profile: profile)
        return profile
    }

    /// Reads the preference once per launch generation and keeps that value
    /// for every later configuration read of the same generation.
    private func terminalTypeForLaunchLocked(_ pane: WorkbenchPane) -> TerminalTypePreference {
        if let recorded = terminalTypeLaunches[pane.id], recorded.generation == pane.launchGeneration {
            return recorded.type
        }
        let liveIDs = Set(document.panes.map(\.id))
        terminalTypeLaunches = terminalTypeLaunches.filter { liveIDs.contains($0.key) }
        terminalTypeLaunches[pane.id] = (pane.launchGeneration, terminalTypePreference)
        return terminalTypePreference
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
            // A workspace may be empty, so only a document with no workspaces is
            // a fresh workbench; one with workspaces and no panes reloads as it was.
            if document.workspaces.isEmpty {
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
                    newPaneFolder: nil,
                    initialShell: true,
                    automationPolicy: .askAndDelegate
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
            try commitLocked {
                try createWorkspaceLocked(
                    launchFolder: folder,
                    name: name,
                    attachedFolders: [folder],
                    newPaneFolder: folder,
                    initialShell: true,
                    automationPolicy: .askAndDelegate
                )
            }
        }
    }

    /// Creates an empty collaboration container: no attached folder, no pane.
    /// `launchFolder` is only validated, as the folder a first shell would use.
    @discardableResult
    public func createFolderlessWorkspace(
        name: String? = nil,
        launchFolder: String
    ) throws -> WorkbenchWorkspace {
        try requireDirectory(launchFolder)
        return try lock.withLock {
            try commitLocked {
                try createWorkspaceLocked(
                    launchFolder: launchFolder,
                    name: name,
                    attachedFolders: [],
                    newPaneFolder: nil,
                    initialShell: false,
                    automationPolicy: .askAndDelegate
                )
            }
        }
    }

    // Workspace groups: native presentation metadata, each change saved or
    // rolled back whole. A workspace naming a group that is gone reads as
    // Ungrouped, so deleting a group only has to clear its members.

    public func listWorkspaceGroups() throws -> [WorkspaceGroup] {
        lock.withLock { document.workspaceGroups ?? [] }
    }

    /// Adds a group last, and moves `workspaceID` into it when given.
    public func createWorkspaceGroup(name: String, moving workspaceID: String?) throws -> WorkspaceGroup {
        try lock.withLock {
            try commitLocked {
                let group = WorkspaceGroup(id: "group-" + UUID().uuidString.lowercased(), name: try validatedGroupNameLocked(name))
                document.workspaceGroups = (document.workspaceGroups ?? []) + [group]
                if let workspaceID {
                    // Indices are read before each write: an optional-chained
                    // write (`document.workspaceGroups?[…]`) begins its access
                    // before its arguments are read, and a read of `document`
                    // there stopped the check with "Fatal access conflict detected".
                    let index = try workspaceIndexLocked(workspaceID)
                    document.workspaces[index].groupID = group.id
                }
                return group
            }
        }
    }

    public func renameWorkspaceGroup(_ groupID: String, name: String) throws {
        try lock.withLock {
            try commitLocked {
                let index = try groupIndexLocked(groupID)
                let validated = try validatedGroupNameLocked(name, excluding: groupID)
                document.workspaceGroups?[index].name = validated
            }
        }
    }

    /// Removes the group; its workspaces move to Ungrouped. Nothing closes.
    public func deleteWorkspaceGroup(_ groupID: String) throws {
        try lock.withLock {
            try commitLocked {
                let index = try groupIndexLocked(groupID)
                document.workspaceGroups?.remove(at: index)
                for index in document.workspaces.indices where document.workspaces[index].groupID == groupID {
                    document.workspaces[index].groupID = nil
                }
            }
        }
    }

    /// Moves a workspace into a group, or to Ungrouped with nil.
    public func setWorkspaceGroup(_ workspaceID: String, groupID: String?) throws {
        try lock.withLock {
            try commitLocked {
                let index = try workspaceIndexLocked(workspaceID)
                if let groupID { _ = try groupIndexLocked(groupID) }
                document.workspaces[index].groupID = groupID
            }
        }
    }

    public func moveWorkspaceGroup(_ groupID: String, by offset: Int) throws {
        try lock.withLock {
            try commitLocked {
                let index = try groupIndexLocked(groupID)
                guard var groups = document.workspaceGroups, groups.indices.contains(index + offset) else {
                    throw ParleyWorkbenchError.commandFailed("That group cannot move any further.")
                }
                groups.insert(groups.remove(at: index), at: index + offset)
                document.workspaceGroups = groups
            }
        }
    }

    public func setWorkspaceGroupCollapsed(_ groupID: String, collapsed: Bool) throws {
        try lock.withLock {
            try commitLocked {
                let index = try groupIndexLocked(groupID)
                document.workspaceGroups?[index].isCollapsed = collapsed
            }
        }
    }

    private func groupIndexLocked(_ groupID: String) throws -> Int {
        guard let index = document.workspaceGroups?.firstIndex(where: { $0.id == groupID }) else {
            throw ParleyWorkbenchError.commandFailed("That workspace group no longer exists.")
        }
        return index
    }

    private func validatedGroupNameLocked(_ proposed: String, excluding groupID: String? = nil) throws -> String {
        try WorkspaceGroup.validatedName(proposed, among: document.workspaceGroups ?? [], excluding: groupID).get()
    }

    /// Pins or unpins a workspace in the sidebar. Native metadata only.
    public func setWorkspacePinned(_ workspaceID: String, pinned: Bool) throws {
        try lock.withLock {
            try commitLocked {
                let index = try workspaceIndexLocked(workspaceID)
                document.workspaces[index].pinned = pinned
            }
        }
    }

    public func selectWorkspace(_ workspaceID: String) throws {
        try lock.withLock {
            try commitLocked {
                let index = try workspaceIndexLocked(workspaceID)
                let durableID = document.workspaces[index].workspaceID
                activateWorkspaceLocked(workspaceID: durableID)
                if !document.panes.contains(where: { $0.workspaceID == durableID && $0.isActive }),
                   let paneIndex = document.panes.firstIndex(where: { $0.workspaceID == durableID }) {
                    for position in document.panes.indices { document.panes[position].isActive = position == paneIndex }
                }
            }
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
        permissionProfile: EffectivePermissionProfile? = nil,
        containerConfiguration: ContainerConfiguration? = nil
    ) throws -> WorkbenchPane {
        try requireDirectory(cwd)
        return try lock.withLock {
            try requireNoTerminationInProgress()
            guard let activeWorkspace = document.workspaces.first(where: \.isActive) else {
                throw ParleyWorkbenchError.workspaceNotFound("active")
            }
            let profile = try effectivePermissionProfile(
                for: kind,
                cwd: cwd,
                supplied: permissionProfile,
                selection: nil
            )
            var pane = try makePane(
                kind: kind,
                cwd: cwd,
                workspace: activeWorkspace,
                started: containerConfiguration == nil,
                permissionProfile: profile
            )
            pane.containerConfiguration = containerConfiguration
            // Creating an inert placeholder is local metadata only. Docker preparation
            // is an explicit background operation before startPane may activate it.
            if containerConfiguration != nil { confirmedContainerStops[pane.id] = pane.launchGeneration }
            let previous = document
            for index in document.panes.indices { document.panes[index].isActive = false }
            document.panes.append(pane)
            document.activity[pane.id] = Date()
            do { try persistLocked() } catch {
                // Nothing names the new pane once the document is put back;
                // its id is never reused, so the entries makePane recorded
                // for it go too.
                document = previous
                confirmedContainerStops[pane.id] = nil
                hostPermissionLaunches[pane.id] = nil
                throw error
            }
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
                  let lead = document.panes.first(where: { $0.id == grant.requesterPaneID }),
                  lead.kind.isAgent, lead.isStarted, !lead.isDead,
                  lead.launchGeneration == grant.requesterGeneration, lead.workspaceID == grant.workspaceID,
                  WorkspaceFolderIdentity.matchingKey(lead.launchWorkingDirectory) == session.sourceFolder,
                  let workspace = document.workspaces.first(where: { $0.workspaceID == grant.workspaceID }),
                  workspace.automationPolicy == grant.automationPolicy else {
                throw TeamSessionError.invalid("The approved team session or its requesting pane changed before pane creation.")
            }
            let canonical = WorkspaceFolderIdentity.matchingKey(grant.folder)
            guard WorkspaceFolderIdentity.contains(canonical, within: session.sourceFolder) else {
                throw TeamSessionError.invalid("The approved folder is outside the requesting pane's working folder.")
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
            let container = grant.containerConfigurations?[provision.kind.rawValue]
            if let container { try ContainerLaunchProjection.validate(container) }
            var pane = try makePane(kind: provision.kind, cwd: grant.folder, workspace: workspace, started: container == nil, permissionProfile: permissionProfile)
            pane.containerConfiguration = container
            if container != nil { confirmedContainerStops[pane.id] = pane.launchGeneration }
            pane.customName = provision.name
            pane.role = provision.role
            let previous = document
            activateWorkspaceLocked(workspaceID: workspace.workspaceID)
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
    public func createApprovedCommandPane(run: ReviewedCommandRun, workerExecutable: URL, exitWhenClean: Bool = false) throws -> WorkbenchPane {
        try lock.withLock {
            // An agent run's Shell opens beside a requesting pane that must
            // still be exactly the one that asked; a person-proposed run opens
            // in the workspace the person chose, which only has to exist.
            let workspace: WorkbenchWorkspace
            switch run.origin {
            case .agentPane:
                guard let requester = run.source,
                      let source = document.panes.first(where: { $0.id == requester.id }),
                      source.kind.isAgent, source.isStarted, !source.isDead,
                      source.launchGeneration == requester.launchGeneration,
                      source.workspaceID == requester.workspaceID,
                      WorkspaceFolderIdentity.matchingKey(source.launchWorkingDirectory) == run.sourceFolder,
                      let found = document.workspaces.first(where: { $0.workspaceID == source.workspaceID }) else {
                    throw ReviewedCommandRunError.invalid("The approved request or its source pane changed before Shell creation.")
                }
                workspace = found
            case .person:
                guard let found = document.workspaces.first(where: { $0.workspaceID == run.workspaceID }) else {
                    throw ReviewedCommandRunError.invalid("The workspace chosen for this run no longer exists.")
                }
                workspace = found
            }
            guard run.state == .running,
                  !document.panes.contains(where: { $0.id == run.shellPaneID }),
                  workerExecutable.path.hasPrefix("/"),
                  fileManager.isExecutableFile(atPath: workerExecutable.path) else {
                throw ReviewedCommandRunError.invalid("The approved request or its source pane changed before Shell creation.")
            }
            let checked = try ReviewedCommand(argv: run.command.argv, folder: run.command.folder, sourceFolder: run.sourceFolder)
            guard checked == run.command else { throw ReviewedCommandRunError.invalid("The approved folder changed.") }
            // Refused before the worker ticket is staged, not only at pane construction.
            try requireNotReservedForRemoval(run.command.folder)
            let directory = applicationDirectory.resolvingSymlinksInPath().appendingPathComponent("approved-command-runs")
            let ticket = try ApprovedCommandWorker.stage(run: run, directory: directory,
                shellExecutable: loginShellExecutable().path, ownerPID: ProcessInfo.processInfo.processIdentifier,
                exitWhenClean: exitWhenClean)
            let previous = document
            var pane = try makePane(kind: .shell, cwd: run.command.folder, workspace: workspace, started: true, permissionProfile: nil)
            pane.id = run.shellPaneID
            pane.customName = "Command run"
            activateWorkspaceLocked(workspaceID: workspace.workspaceID)
            for index in document.panes.indices { document.panes[index].isActive = false }
            document.panes.append(pane)
            document.activity[pane.id] = Date()
            do { try persistLocked() }
            catch {
                document = previous
                try? fileManager.removeItem(at: ticket.deletingLastPathComponent())
                throw error
            }
            approvedShellLaunches[pane.id] = (pane.launchGeneration, [workerExecutable.path, ApprovedCommandWorker.argument, ticket.path, try ApprovedCommandWorker.ticketDigest(for: ticket)])
            return pane
        }
    }

    public func selectPane(_ paneID: String) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            try commitLocked {
                activateWorkspaceLocked(workspaceID: document.panes[index].workspaceID)
                for position in document.panes.indices { document.panes[position].isActive = position == index }
                document.activity[paneID] = Date()
            }
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
        launchMode: AgentLaunchMode = .fresh,
        containerConfiguration: ContainerConfiguration? = nil
    ) throws {
        try lock.withLock {
            try requireNoTerminationInProgress()
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard containerConfiguration == nil else {
                throw ContainerPaneError.refused("Stop and prepare the container in the background before starting this pane.")
            }
            try requireDirectory(document.panes[index].launchWorkingDirectory)
            let profile = try effectivePermissionProfile(
                for: document.panes[index].kind,
                cwd: document.panes[index].launchWorkingDirectory,
                supplied: permissionProfile,
                selection: document.panes[index].permissionSelection
            )
            try terminateSurface(paneID)
            // Re-resolve after the transport ran: act on this pane or not at all.
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            copilotTrustConfirmations[paneID] = nil
            document.panes[index].isStarted = false
            document.panes[index].inputAvailable = false
            document.panes[index].relayEnabled = false
            document.panes[index].currentCommand = "stopped"
            try persistLocked()
            if document.panes[index].kind.isAgent, let relayRuntime {
                _ = try relayRuntime.credentials.rotate(paneID)
            }
            // The old process has ended and the pane is saved stopped. If the
            // new start cannot be saved, it stays that way rather than reading
            // started with nothing saved behind it, as startPane does.
            let stopped = document
            let stoppedLaunch = hostPermissionLaunches[paneID]
            document.panes[index].containerConfiguration = containerConfiguration
            markStartedLocked(index: index, profile: profile)
            if document.panes[index].kind.isAgent {
                agentLaunchRequests[paneID] = AgentLaunchRequest(
                    generation: document.panes[index].launchGeneration,
                    mode: launchMode
                )
            } else {
                agentLaunchRequests[paneID] = nil
            }
            do { try persistLocked() } catch {
                document = stopped
                hostPermissionLaunches[paneID] = stoppedLaunch
                agentLaunchRequests[paneID] = nil
                throw error
            }
        }
    }

    public func startPane(
        _ paneID: String,
        permissionProfile: EffectivePermissionProfile? = nil,
        launchMode: AgentLaunchMode = .fresh,
        containerConfiguration: ContainerConfiguration? = nil
    ) throws {
        try lock.withLock {
            try requireNoTerminationInProgress()
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard document.panes[index].kind.isAgent, !document.panes[index].isStarted else { return }
            try requireDirectory(document.panes[index].launchWorkingDirectory)
            let profile = try effectivePermissionProfile(
                for: document.panes[index].kind,
                cwd: document.panes[index].launchWorkingDirectory,
                supplied: permissionProfile,
                selection: document.panes[index].permissionSelection
            )
            guard !containerPreparations.contains(paneID) else {
                throw ContainerPaneError.refused("This pane's container is still being prepared.")
            }
            if let containerConfiguration {
                guard let prepared = preparedContainerIDs[paneID],
                      prepared.generation == document.panes[index].launchGeneration + 1,
                      prepared.configuration == containerConfiguration, prepared.mode == launchMode,
                      prepared.profile == profile, prepared.folder == document.panes[index].launchWorkingDirectory,
                      prepared.workspaceID == document.panes[index].workspaceID,
                      prepared.automationPolicy == document.panes[index].automationPolicy else {
                    throw ContainerPaneError.refused("This container was not prepared for the exact reviewed pane, profile and launch mode.")
                }
            } else {
                guard preparedContainerIDs[paneID] == nil else {
                    throw ContainerPaneError.refused("Remove the prepared container before starting a host session.")
                }
                if let relayRuntime { _ = try relayRuntime.credentials.rotate(paneID) }
            }
            // A start that cannot be saved leaves the pane stopped: otherwise
            // it read started, with a surface mounted for it, while the saved
            // state held it stopped. A rotated credential is harmless on a
            // stopped pane, whose next start rotates it again.
            let previous = document
            let previousLaunch = hostPermissionLaunches[paneID]
            document.panes[index].containerConfiguration = containerConfiguration
            markStartedLocked(index: index, profile: profile)
            agentLaunchRequests[paneID] = AgentLaunchRequest(
                generation: document.panes[index].launchGeneration,
                mode: launchMode
            )
            do { try persistLocked() } catch {
                document = previous
                hostPermissionLaunches[paneID] = previousLaunch
                agentLaunchRequests[paneID] = nil
                throw error
            }
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
            guard !containerPreparations.contains(paneID), preparedContainerIDs[paneID] == nil,
                  document.panes[index].kind.isAgent, !document.panes[index].isStarted else {
                throw ParleyWorkbenchError.commandFailed(
                    "Only a stopped agent pane can choose a new working folder."
                )
            }
            document.panes[index].cwd = WorkspaceFolderIdentity.normalized(folder)
            document.panes[index].launchFolder = document.panes[index].cwd
            document.panes[index].permissionSelection = nil
            document.panes[index].permissionEnforcement = nil
            try persistLocked()
        }
    }

    /// `expectedGeneration` is the generation the caller reviewed: a pane
    /// restarted since is left alone. It has no default, so a caller that
    /// awaits anything before stopping has to say which process it means;
    /// nil is for a caller that stops whatever runs there now.
    public func stopPaneProcess(_ paneID: String, expectedGeneration: Int?) throws {
        try lock.withLock {
            try requireNoTerminationInProgress()
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            if let expectedGeneration, document.panes[index].launchGeneration != expectedGeneration {
                throw ContainerPaneError.refused("The pane restarted after container cleanup; its new session was left alone.")
            }
            guard document.panes[index].kind.isAgent, document.panes[index].isStarted else { return }
            try requireTerminableLocked(paneID)
            // Saved stopped first, as closePane does; the process ends only
            // once that is durable, and the close Ghostty reports from inside
            // the ending names a generation that is no longer current.
            let previous = document
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
            do { try persistLocked() } catch {
                document = previous
                throw error
            }
            // Read before the ending, whose callbacks re-enter this controller.
            let stoppedGeneration = document.panes[index].launchGeneration
            endSurfaceLocked(paneID)
            confirmedContainerStops[paneID] = stoppedGeneration
            copilotTrustConfirmations[paneID] = nil
            agentLaunchRequests[paneID] = nil
            // The pane is saved stopped with relay off; a credential that
            // cannot be forgotten routes nowhere, and its next start rotates it.
            try? relayRuntime?.credentials.forget(paneID)
        }
    }

    public func closePane(_ paneID: String) throws {
        try lock.withLock {
            try requireNoTerminationInProgress()
            guard document.panes.contains(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            try requireTerminableLocked(paneID)
            // Save the removal first and end the process only once it is
            // durable. Ending first and saving after left a pane that could
            // not be saved gone from the window while the error said it had
            // not closed, and back at the next launch.
            let previous = document
            document.panes.removeAll { $0.id == paneID }
            document.activity[paneID] = nil
            // The workspace stays, with its attachments, New Pane Folder and
            // history; closing a workspace is its own explicit action.
            normalizeSelectionLocked()
            do { try persistLocked() } catch {
                document = previous
                throw error
            }
            // Ghostty reports the close synchronously from inside this call;
            // the pane is no longer listed, so that report changes nothing.
            endSurfaceLocked(paneID)
            copilotTrustConfirmations[paneID] = nil
            agentLaunchRequests[paneID] = nil
            // The pane no longer exists in the saved state; a credential
            // that cannot be forgotten names no pane and routes nowhere.
            try? relayRuntime?.credentials.forget(paneID)
        }
    }

    public func closeWorkspace(_ workspaceID: String) throws {
        try lock.withLock {
            try requireNoTerminationInProgress()
            guard document.workspaces.count > 1 else { throw ParleyWorkbenchError.cannotCloseLastWorkspace }
            let workspace = document.workspaces[try workspaceIndexLocked(workspaceID)]
            let paneIDs = document.panes.filter { $0.workspaceID == workspace.workspaceID }.map(\.id)
            for paneID in paneIDs { try requireTerminableLocked(paneID) }
            // Save the removal first and end the processes only once it is
            // durable, as a layout restore does: a failure part-way used to
            // leave ended panes listed in a workspace that stayed open.
            let previous = document
            do {
                document.panes.removeAll(where: { $0.workspaceID == workspace.workspaceID })
                document.workspaces.removeAll(where: { $0.workspaceID == workspace.workspaceID })
                for paneID in paneIDs { document.activity[paneID] = nil }
                normalizeSelectionLocked()
                try persistLocked()
            } catch {
                document = previous
                throw error
            }
            for paneID in paneIDs {
                endSurfaceLocked(paneID)
                copilotTrustConfirmations[paneID] = nil
                agentLaunchRequests[paneID] = nil
                // The pane no longer exists in the saved state; a credential
                // that cannot be forgotten names no pane and routes nowhere.
                try? relayRuntime?.credentials.forget(paneID)
            }
        }
    }

    /// Everything that can refuse happens before anything ends: the container
    /// check, then the saved state. Ending every surface first used to leave
    /// Parley open with every pane gone, and unable to start another, when a
    /// credential or the state file could not be written.
    public func shutdown() throws {
        try lock.withLock {
            try requireAllTerminableLocked()
            let previous = document
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
            do { try persistLocked() } catch {
                document = previous
                throw error
            }
            isShutDown = true
            endAllSurfacesLocked()
            agentLaunchRequests.removeAll()
            copilotTrustConfirmations.removeAll()
            // Every pane is stopped in the saved state; a credential that
            // cannot be forgotten names no running pane and routes nowhere.
            for pane in document.panes { try? relayRuntime?.credentials.forget(pane.id) }
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

    public func pasteVoice(_ text: String, destination: VoiceDestination, source: VoiceDestination? = nil, submit: Bool) throws {
        let reviewed = [destination] + (source.map { [$0] } ?? [])
        let live = try listPanes()
        for snapshot in reviewed { _ = try snapshot.resolve(in: live) }
        try pastePrepared(text, into: destination.paneID, submit: submit, reviewed: reviewed)
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
            // A caller stopping this pane's container checks its workspace
            // after Docker cleanup; a move meanwhile would leave it refusing
            // with the container already gone.
            guard !containerPreparations.contains(paneID), !moveHolds.contains(paneID) else {
                throw ContainerPaneError.refused("This pane's container is being prepared or stopped. Move it when that ends.")
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
            let sourceWorkspaceID = document.panes[index].workspaceID
            // Changed in memory, then saved; put back if the save fails, so a
            // failed move leaves the pane where the saved state says it is.
            let previous = document
            document.panes[index].workspaceID = target.workspaceID
            document.panes[index].workspaceName = target.name
            document.panes[index].automationPolicy = target.automationPolicy
            // The document has one active pane. If it was the one that just
            // moved, the source workspace — still the one on screen, since a
            // move keeps it open — is left with panes but none active, and the
            // workbench shows "No pane in this workspace" until the person
            // reselects the workspace. Hand activity to a remaining source
            // pane instead; the policy above guarantees there is one.
            if document.panes[index].isActive,
               let successor = document.panes.firstIndex(where: {
                   $0.id != paneID && $0.workspaceID == sourceWorkspaceID
               }) {
                document.panes[index].isActive = false
                document.panes[successor].isActive = true
            }
            do { try persistLocked() } catch {
                document = previous
                throw error
            }
            return document.panes[index]
        }
    }

    public func restoreWorkspaceLayout(
        _ layout: SavedWorkspaceLayout,
        replacing replacedWorkspaceID: String? = nil
    ) throws -> WorkbenchWorkspace {
        try requireDirectory(layout.defaultFolder)
        for leaf in layout.root.leaves { try requireDirectory(leaf.folder) }
        return try lock.withLock {
            // Every leaf folder is checked under the lock before the workspace
            // is created, so a refusal changes nothing.
            try requireNotReservedForRemoval(layout.defaultFolder)
            for leaf in layout.root.leaves { try requireNotReservedForRemoval(leaf.folder) }
            let replacement = try replacedWorkspaceID.map { document.workspaces[try workspaceIndexLocked($0)] }
            try requireNoTerminationInProgress()
            if let replacement {
                for pane in document.panes where pane.workspaceID == replacement.workspaceID {
                    guard !containerPreparations.contains(pane.id),
                          pane.containerConfiguration == nil || confirmedContainerStops[pane.id] == pane.launchGeneration else {
                        throw ContainerPaneError.refused("Finish container cleanup before replacing this workspace.")
                    }
                }
            }
            // Every replaced pane must be allowed to end before anything
            // changes; the new workspace is then built and saved against a
            // snapshot that is put back on any failure, and the replaced
            // panes end only once the new state is saved.
            let replacedIDs = replacement.map { replaced in document.panes.filter { $0.workspaceID == replaced.workspaceID }.map(\.id) } ?? []
            for id in replacedIDs { try requireTerminableLocked(id) }
            let previous = document
            // Starting panes records their launch permissions; a rolled-back
            // restore puts these back too, so no entry names a pane that never existed.
            let previousLaunches = hostPermissionLaunches
            let workspace: WorkbenchWorkspace
            do {
                workspace = try createWorkspaceLocked(
                    launchFolder: layout.defaultFolder,
                    name: layout.name,
                    attachedFolders: replacement?.attachedFolders ?? [layout.defaultFolder],
                    newPaneFolder: layout.defaultFolder,
                    initialShell: false,
                    automationPolicy: layout.automationPolicy
                )
                document.panes.removeAll(where: { $0.workspaceID == workspace.workspaceID })
                for leaf in layout.root.leaves {
                    let profile = try effectivePermissionProfile(
                        for: leaf.kind,
                        cwd: leaf.folder,
                        supplied: nil,
                        selection: leaf.permissionSelection
                    )
                    var pane = try makePane(
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
                    // The replacement is a new workspace; it keeps the pin and the group.
                    if let index = document.workspaces.firstIndex(where: { $0.workspaceID == workspace.workspaceID }) {
                        document.workspaces[index].pinned = replacement.pinned
                        document.workspaces[index].groupID = replacement.groupID
                    }
                    document.panes.removeAll(where: { $0.workspaceID == replacement.workspaceID })
                    document.workspaces.removeAll(where: { $0.workspaceID == replacement.workspaceID })
                }
                try selectWorkspaceLocked(workspace.workspaceID)
                try persistLocked()
            } catch {
                document = previous
                hostPermissionLaunches = previousLaunches
                throw error
            }
            for id in replacedIDs {
                endSurfaceLocked(id)
                copilotTrustConfirmations[id] = nil
                agentLaunchRequests[id] = nil
                // The pane no longer exists in the saved state; a credential
                // that cannot be forgotten names no pane and routes nowhere.
                try? relayRuntime?.credentials.forget(id)
            }
            return document.workspaces.first(where: { $0.workspaceID == workspace.workspaceID }) ?? workspace
        }
    }

    /// Run off the main actor. No Docker operation holds the workbench lock.
    /// The stopped pane and exact reviewed configuration are rechecked before
    /// the prepared generation becomes eligible for native activation.
    public func prepareContainerStart(_ paneID: String, configuration: ContainerConfiguration,
        permissionProfile: EffectivePermissionProfile, launchMode: AgentLaunchMode = .fresh) throws {
        let (snapshot, runtime): (WorkbenchPane, RelayRuntime) = try lock.withLock {
            try requireNoTerminationInProgress()
            guard !isShutDown, let pane = document.panes.first(where: { $0.id == paneID }),
                  pane.kind.isAgent, !pane.isStarted, let runtime = relayRuntime,
                  !containerPreparations.contains(paneID), preparedContainerIDs[paneID] == nil else {
                throw ContainerPaneError.refused("Container preparation requires an unchanged stopped agent pane and the active core.")
            }
            guard permissionProfile.approvedRoots == [pane.launchWorkingDirectory] else {
                throw ContainerPaneError.refused("Container panes currently require exactly their working folder as the approved root.")
            }
            containerPreparations.insert(paneID)
            confirmedContainerStops[paneID] = nil
            return (pane, runtime)
        }
        defer { _ = lock.withLock { containerPreparations.remove(paneID) } }
        let controlDirectories = ParleyRuntime.controlDirectories() + [applicationDirectory]
        let protectedDirectories = controlDirectories
            + controlDirectories.map { RelayFileTransport.runtimeDirectory(applicationDirectory: $0) }
            + [runtime.transportDirectory]
        try containerService.validateFolder(snapshot.launchWorkingDirectory, protectedDirectories: protectedDirectories.map(\.path), gitAccess: configuration.gitAccess)
        let root = applicationDirectory.appendingPathComponent("container-runtime")
        let protocolFolder = try AgentProtocol.install(in: root)
        let shim = try RelayShim.installCommand(in: root.appendingPathComponent("bin"),
            transportDirectory: runtime.transportDirectory, runtimeMarker: runtime.runtimeMarker, platform: .linux)
        let token = try runtime.credentials.rotate(paneID)
        let endpoint = try RelayFileTransport.prepareEndpoint(runtimeDirectory: runtime.transportDirectory, paneToken: token)
        var proposed = snapshot
        proposed.cwd = snapshot.launchWorkingDirectory
        proposed.containerConfiguration = configuration
        proposed.launchGeneration += 1
        // Bypass is the person's explicit choice, and an ask rule outranks
        // every permission mode including bypassPermissions. Emitting one here
        // would quietly overrule that choice, so a bypassed container carries
        // no execution rule at all.
        var command = AgentProtocol.command(
            for: proposed.kind, protocolDirectory: protocolFolder, launchMode: launchMode,
            shellCommandRule: configuration.bypassVendorPermissions
                ? .allow : PermissionProfileAdapter.shellCommandRule(permissionProfile))
        command.removeFirst()
        if !configuration.bypassVendorPermissions {
            command += PermissionProfileAdapter.launchPlan(for: proposed.kind, profile: permissionProfile).arguments
        }
        // Copilot takes its instructions directory from the environment. The
        // protocol directory is mounted at the same path inside the container,
        // so the host value is the container value; PARLEY_COMMAND is set by
        // the projection itself and is not carried here.
        let vendorEnvironment = AgentProtocol.environment(for: proposed.kind, protocolDirectory: protocolFolder, commandPath: shim)
            .filter { ContainerLaunchProjection.vendorEnvironmentKeys.contains($0.key) }
        let id = try containerService.prepare(configuration: configuration, pane: proposed, endpoint: endpoint.path,
            protocolDirectory: protocolFolder.path, shimDirectory: shim.deletingLastPathComponent().path,
            token: token, vendorArguments: command, vendorEnvironment: vendorEnvironment, runtime: runtime.runtimeMarker ?? "PRODUCTION")
        try lock.withLock {
            guard !isShutDown, let current = document.panes.first(where: { $0.id == paneID }),
                  !current.isStarted, current.launchGeneration == snapshot.launchGeneration,
                  current.cwd == snapshot.cwd, current.launchFolder == snapshot.launchFolder, current.workspaceID == snapshot.workspaceID,
                  current.automationPolicy == snapshot.automationPolicy,
                  current.permissionSelection == snapshot.permissionSelection else {
                throw ContainerPaneError.refused("The pane changed while its container was being prepared. Remove the recorded container in Status Center before retrying.")
            }
            preparedContainerIDs[paneID] = PreparedContainer(generation: proposed.launchGeneration, id: id,
                configuration: configuration, mode: launchMode, profile: permissionProfile, folder: proposed.cwd,
                workspaceID: proposed.workspaceID, automationPolicy: proposed.automationPolicy)
        }
    }

    /// Background cleanup is bound to the pane revision the native action saw.
    /// A subsequent start invalidates this receipt without another Docker read.
    /// Panes a person's lifecycle action is stopping or closing. `movePane`
    /// refuses them from before the action's first container cleanup until
    /// after its last step: the cleanup reservation ends when Docker returns,
    /// and in a batch one pane's cleanup ends while another's still runs.
    private var moveHolds: Set<String> = []

    /// Holds every pane or none; a pane another action holds is refused.
    public func holdAgainstMove(_ paneIDs: [String]) throws {
        try lock.withLock {
            guard moveHolds.isDisjoint(with: paneIDs) else {
                throw ContainerPaneError.refused("Another action is already stopping or closing this pane.")
            }
            moveHolds.formUnion(paneIDs)
        }
    }

    public func releaseMoveHold(_ paneIDs: [String]) {
        lock.withLock { moveHolds.subtract(paneIDs) }
    }

    /// `requiringWorkspace` is for a caller that checks the pane's workspace
    /// again after cleanup (`performAfterContainerStops`): a pane moved after
    /// its review is refused here, before Docker, not after its container is
    /// gone. Team Stop, restart, shutdown and lost-client reconciliation follow
    /// the pane wherever it is and pass false. It has no default. A move waits
    /// for the cleanup either way (`movePane` refuses during it).
    public func prepareContainerStop(_ reviewed: WorkbenchPane, requiringWorkspace: Bool) throws {
        try lock.withLock {
            guard !containerPreparations.contains(reviewed.id), let current = document.panes.first(where: { $0.id == reviewed.id }),
                  current.launchGeneration == reviewed.launchGeneration, current.cwd == reviewed.cwd,
                  current.containerConfiguration == reviewed.containerConfiguration,
                  !requiringWorkspace || current.workspaceID == reviewed.workspaceID else {
                throw ContainerPaneError.refused("The pane changed; review its container again before stopping it.")
            }
            containerPreparations.insert(reviewed.id)
        }
        defer { _ = lock.withLock { containerPreparations.remove(reviewed.id) } }
        // Includes a created-but-not-started next generation belonging to this
        // exact stopped pane. An in-flight preparation cannot overlap this call.
        try containerService.stop(paneID: reviewed.id)
        try lock.withLock {
            guard let current = document.panes.first(where: { $0.id == reviewed.id }),
                  current.launchGeneration == reviewed.launchGeneration else {
                throw ContainerPaneError.refused("The pane changed during container cleanup; its surface was left alone.")
            }
            confirmedContainerStops[reviewed.id] = reviewed.launchGeneration
            preparedContainerIDs[reviewed.id] = nil
        }
    }

    /// Native Status Center removal, run off the main actor. Returns only a
    /// matching pane whose surface may be stopped after Docker cleanup.
    public func removeRecordedContainer(_ record: ContainerPaneRecord) throws -> WorkbenchPane? {
        let snapshot: WorkbenchPane? = try lock.withLock {
            try requireNoTerminationInProgress()
            guard !containerPreparations.contains(record.paneID) else {
                throw ContainerPaneError.refused("This pane's container operation is still in progress.")
            }
            containerPreparations.insert(record.paneID)
            return document.panes.first { $0.id == record.paneID }
        }
        defer { _ = lock.withLock { containerPreparations.remove(record.paneID) } }
        // The person's action names exactly this record, never every container
        // with the pane ID. In particular, an old receipt cannot stop a replacement.
        try containerService.remove(record)
        guard try !containerService.records().contains(where: { $0.paneID == record.paneID && !$0.removed }) else { return nil }
        return lock.withLock {
            guard let snapshot, let current = document.panes.first(where: { $0.id == record.paneID }),
                  current.launchGeneration == snapshot.launchGeneration, current.cwd == snapshot.cwd,
                  current.containerConfiguration == snapshot.containerConfiguration,
                  current.isStarted == snapshot.isStarted else { return nil }
            let prepared = preparedContainerIDs[current.id]
            let removedPreparation = prepared?.id == record.containerID && prepared?.generation == record.generation
                && prepared?.configuration == record.configuration
            let removedCurrent = current.launchGeneration == record.generation && current.containerConfiguration == record.configuration
            guard removedPreparation || removedCurrent else { return nil }
            confirmedContainerStops[current.id] = current.launchGeneration
            preparedContainerIDs[current.id] = nil
            return current
        }
    }

    public func prepareAllContainerStops() throws {
        let panes = try listPanes()
        var failures: [String] = []
        let paneIDs = Set(panes.map(\.id))
        var recordedPaneIDs: Set<String> = []
        do { recordedPaneIDs = Set(try containerService.records().filter { !$0.removed }.map(\.paneID)) }
        catch { failures.append(error.localizedDescription) }
        let preparedPaneIDs = lock.withLock { Set(preparedContainerIDs.keys).union(containerPreparations) }
        for pane in panes where pane.containerConfiguration != nil || recordedPaneIDs.contains(pane.id) || preparedPaneIDs.contains(pane.id) {
            do { try prepareContainerStop(pane, requiringWorkspace: false) }
            catch { failures.append("\(pane.displayName): \(error.localizedDescription)") }
        }
        // Visit orphans independently; never retry a failed live-pane removal
        // without its controller reservation and unchanged-generation checks.
        do {
            for record in try containerService.records() where !record.removed && !paneIDs.contains(record.paneID) {
                do { try containerService.remove(record) }
                catch { failures.append("\(record.paneID): \(error.localizedDescription)") }
            }
        } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw ContainerPaneError.refused(failures.joined(separator: "\n")) }
    }

    public func launchConfiguration(for paneID: String) throws -> GhosttyPaneLaunch {
        try lock.withLock {
            try requireNoTerminationInProgress()
            guard let pane = document.panes.first(where: { $0.id == paneID }) else {
                throw ParleyWorkbenchError.paneNotFound(paneID)
            }
            guard pane.isStarted, !pane.isDead else {
                throw ParleyWorkbenchError.commandFailed("\(pane.displayName) is stopped.")
            }
            let workingDirectory = hostPermissionLaunches[pane.id].flatMap {
                pane.kind.isAgent && $0.generation == pane.launchGeneration ? $0.folder : nil
            } ?? pane.launchWorkingDirectory
            var launchEnvironment: [String: String] = [
                "PARLEY_PANE": "1",
                "PARLEY_PANE_ID": pane.id,
                // The ticket socket admits only a process of this launch, not
                // one left over from an earlier generation of the same pane.
                RelayTicketServer.generationMarkerKey: String(pane.launchGeneration),
                "PARLEY_PANE_KIND": pane.kind.rawValue,
                "PARLEY_APP_PID": String(ProcessInfo.processInfo.processIdentifier),
            ]
            var argv: [String]
            // Ghostty sets TERM from its own option after the surface
            // environment, so the terminal type is a word of the command,
            // read once for this generation.
            let terminalType = terminalTypeForLaunchLocked(pane)
            if pane.kind == .shell {
                // Ghostty overlays envVars on its process environment. Remove
                // inherited authority before the login shell starts.
                let metadataKeys = Set(launchEnvironment.keys)
                let inheritedKeys = Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("PARLEY_") })
                    .union(["PARLEY_RELAY_TOKEN", "PARLEY_PROTOCOL_VERSION", "PARLEY_COMMAND", "PARLEY_RUNTIME", "PARLEY_SWIFT_COMMAND", "PARLEY_SWIFTPM_COMPATIBILITY", "TMUX", "TMUX_PANE"])
                    .subtracting(metadataKeys)
                argv = ["/usr/bin/env"] + inheritedKeys.sorted().flatMap { ["-u", $0] }
                if let marker = relayRuntime?.runtimeMarker { argv += ["PARLEY_RUNTIME=\(marker)"] }
                if let assignment = terminalType.launchAssignment { argv.append(assignment) }
                launchEnvironment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
                if let approved = approvedShellLaunches.removeValue(forKey: pane.id), approved.generation == pane.launchGeneration {
                    argv += approved.argv
                } else {
                    argv += [loginShellExecutable().path, "-l"]
                }
            } else {
                guard let relayRuntime else {
                    throw ParleyWorkbenchError.commandFailed(
                        "Parley cannot start an agent without its relay endpoint. Shell panes remain available."
                    )
                }
                let token = try relayRuntime.credentials.token(for: pane.id)
                if let container = pane.containerConfiguration {
                    guard let receipt = preparedContainerIDs[pane.id], receipt.generation == pane.launchGeneration else {
                        throw ContainerPaneError.refused("This container launch has not been prepared. Review permissions and start the pane again.")
                    }
                    let root = applicationDirectory.appendingPathComponent("container-runtime")
                    let boundary = try AgentProcessBoundary(applicationDirectory: applicationDirectory,
                        protocolDirectory: root.appendingPathComponent("agent-protocol"), shimDirectory: root.appendingPathComponent("bin"),
                        protectedControlEndpoint: applicationDirectory.appendingPathComponent("relay.sock"),
                        transportDirectory: relayRuntime.transportDirectory, paneToken: token, fileManager: fileManager)
                    let stripped = Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("DOCKER_") || ($0.hasPrefix("PARLEY_") && launchEnvironment[$0] == nil) })
                        .union(["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "TMUX", "TMUX_PANE"])
                    let command = boundary.arguments + ["/usr/bin/env"] + stripped.sorted().flatMap { ["-u", $0] } + [container.dockerExecutable] + (try ContainerLaunchProjection.attachArguments(configuration: container, containerID: receipt.id))
                    launchEnvironment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
                    launchEnvironment["HOME"] = NSHomeDirectory()
                    // Docker sets the container's TERM at create; the host
                    // client's own value is not what the vendor sees.
                    return GhosttyPaneLaunch(paneID: pane.id, generation: pane.launchGeneration, workingDirectory: workingDirectory,
                        environment: launchEnvironment, command: GhosttyLaunchCommand.render(command), terminalType: .compatible)
                }
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
                let endpoint = try RelayFileTransport.prepareEndpoint(
                    runtimeDirectory: relayRuntime.transportDirectory, paneToken: token, fileManager: fileManager)
                argv = ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE", "-u", "PARLEY_RUNTIME"]
                if let marker = relayRuntime.runtimeMarker { argv.append("PARLEY_RUNTIME=\(marker)") }
                if let assignment = terminalType.launchAssignment { argv.append(assignment) }
                let launchMode = agentLaunchRequests[pane.id].flatMap {
                    $0.generation == pane.launchGeneration ? $0.mode : nil
                } ?? .fresh
                // Resolve the profile first: Claude's settings have to carry the
                // execution rule, and that value is built with the command.
                let resolved = try hostPermissionProfileForLaunchLocked(pane)
                var command = AgentProtocol.command(
                    for: pane.kind,
                    protocolDirectory: protocolDirectory,
                    launchMode: launchMode,
                    shellCommandRule: resolved.map(PermissionProfileAdapter.shellCommandRule) ?? .allow
                )
                if let profile = resolved {
                    if pane.kind == .codex {
                        command += HostAgentPermissions(applicationDirectory: applicationDirectory,
                            protocolDirectory: protocolDirectory, shimDirectory: relayRuntime.shimDirectory,
                            transportDirectory: relayRuntime.transportDirectory, endpointDirectory: endpoint,
                            profile: profile).launchArguments
                    } else {
                        command += PermissionProfileAdapter.launchPlan(for: pane.kind, profile: profile).arguments
                    }
                }
                argv.append(contentsOf: command)
            }
            return GhosttyPaneLaunch(
                paneID: pane.id,
                generation: pane.launchGeneration,
                workingDirectory: workingDirectory,
                environment: launchEnvironment,
                command: GhosttyLaunchCommand.render(argv),
                terminalType: terminalType
            )
        }
    }

    public func preflightHostLaunch(folder: String, profile: EffectivePermissionProfile) throws {
        let runtime = try lock.withLock {
            guard let relayRuntime else { throw PermissionProfileError.invalid("The relay is unavailable.") }
            return relayRuntime
        }
        try HostAgentPermissions.preflight(applicationDirectory: applicationDirectory,
            protocolDirectory: protocolDirectory, shimDirectory: runtime.shimDirectory,
            transportDirectory: runtime.transportDirectory, folder: folder, profile: profile,
            environment: environment)
    }

    /// Codex's own `approvals_reviewer` setting as it resolves for a folder,
    /// read through the same bounded config query the preflight uses. Run
    /// away from the main actor. Nil when Codex is not installed or sets none;
    /// a read failure is reported, never guessed.
    public func codexApprovalsReviewer(folder: String) throws -> String? {
        guard let executable = environment["PATH", default: "/usr/bin:/bin"].split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        return try CodexHostConfiguration.approvalsReviewer(executable: executable, environment: environment, folder: folder)
    }

    /// Applies a title in memory and schedules one coalesced write. Returns
    /// false, changing nothing durable, when the title is unchanged; a
    /// repeated title still counts as pane activity in memory because the
    /// vendor process is evidently alive.
    @discardableResult
    public func terminalDidChangeTitle(paneID: String, title: String) throws -> Bool {
        lock.withLock {
            guard !isShutDown, let index = document.panes.firstIndex(where: { $0.id == paneID }) else { return false }
            document.activity[paneID] = Date()
            guard document.panes[index].terminalTitle != title else { return false }
            document.panes[index].terminalTitle = title
            scheduleTitlePersistenceLocked()
            return true
        }
    }

    public var hasPendingPersistence: Bool {
        lock.withLock { titlePersistencePending }
    }

    /// Writes a pending title-only change now. Safe to call at any time; a
    /// failure keeps the change pending and records the error.
    public func flushPendingPersistence() {
        lock.withLock {
            titlePersistenceScheduled = false
            guard titlePersistencePending, !isShutDown else { return }
            do {
                try persistLocked()
            } catch {
                lastDeferredPersistenceErrorStorage = error.localizedDescription
            }
        }
    }

    private func scheduleTitlePersistenceLocked() {
        titlePersistencePending = true
        guard !titlePersistenceScheduled else { return }
        titlePersistenceScheduled = true
        deferredPersistenceQueue.asyncAfter(deadline: .now() + titlePersistenceInterval) { [weak self] in
            self?.flushPendingPersistence()
        }
    }

    /// Returns whether the pane's folder changed. Shells report their folder at
    /// every prompt; an unchanged report only stamps activity in memory, as a
    /// repeated title does, and writes nothing.
    @discardableResult
    public func terminalDidChangeWorkingDirectory(paneID: String, path: String) throws -> Bool {
        guard path.hasPrefix("/") else { return false }
        return try lock.withLock {
            // Guest OSC working-directory reports do not establish a host path
            // or broaden the folder used by context staging and request-run.
            guard let pane = document.panes.first(where: { $0.id == paneID }), pane.containerConfiguration == nil else { return false }
            guard pane.cwd != path else {
                document.activity[paneID] = Date()
                return false
            }
            copilotTrustConfirmations.removeValue(forKey: paneID)
            try updatePaneRuntime(paneID: paneID) { $0.cwd = path }
            return true
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

    public func terminalDidClose(paneID: String, generation: Int? = nil, processAlive: Bool, exitStatus: Int? = nil) throws {
        try lock.withLock {
            guard let pane = document.panes.first(where: { $0.id == paneID }) else { return }
            if let generation, pane.launchGeneration != generation { return }
            // A pane that is not started has no process to report on. Stop and
            // shutdown save the pane stopped before its surface ends, and the
            // close reported from inside that ending must not mark it exited.
            guard pane.isStarted else { return }
            if !processAlive { copilotTrustConfirmations[paneID] = nil }
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
    }

    private func updatePaneRuntime(paneID: String, mutation: (inout WorkbenchPane) -> Void) throws {
        try lock.withLock {
            guard let index = document.panes.firstIndex(where: { $0.id == paneID }) else { return }
            mutation(&document.panes[index])
            document.activity[paneID] = Date()
            try persistLocked()
        }
    }

    private func pastePrepared(_ text: String, into paneID: String, submit: Bool, reviewed: [VoiceDestination]? = nil) throws {
        try lock.withLock {
            guard deliveringPaneIDs.insert(paneID).inserted else { throw ParleyWorkbenchError.deliveryInProgress }
        }
        defer { _ = lock.withLock { deliveringPaneIDs.remove(paneID) } }
        let pane = try requireRelayPane(paneID)
        guard let terminalTransport else {
            throw ParleyWorkbenchError.unsafeRelayTarget(pane.displayName)
        }
        if let reviewed {
            guard let voicePaste = terminalTransport.voicePaste else {
                throw VoiceError.unavailable("Reviewed voice delivery is unavailable.")
            }
            try voicePaste(paneID, text, submit, reviewed)
        } else {
            try terminalTransport.paste(paneID, text, submit)
        }
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

    /// `initialShell`: whether the gesture that creates this workspace asked
    /// for a place to work (a fresh install, Open Folder) or only for a
    /// container (New Workspace, which starts empty; a layout restore, which
    /// adds its own leaves). A workspace may hold no panes.
    private func createWorkspaceLocked(
        launchFolder: String,
        name: String?,
        attachedFolders: [String],
        newPaneFolder: String?,
        initialShell: Bool,
        automationPolicy: WorkspaceAutomationPolicy
    ) throws -> WorkbenchWorkspace {
        // Checked under the lock before any workspace or pane is touched, so a
        // reservation never leaves half-applied metadata behind.
        try requireNotReservedForRemoval(launchFolder)
        let baseName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedName = attachedFolders.first.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let proposed = baseName?.isEmpty == false ? baseName! : (attachedName ?? "Workspace")
        let resolvedName = availableWorkspaceNameLocked(proposed.isEmpty ? "Workspace" : proposed)
        let id = Self.workspaceID()
        // The workspace left and the new one are both last used now, as
        // activateWorkspaceLocked stamps a switch.
        let now = Date()
        if let left = document.workspaces.firstIndex(where: \.isActive) { document.workspaces[left].lastSelectedAt = now }
        for index in document.workspaces.indices { document.workspaces[index].isActive = false }
        for index in document.panes.indices { document.panes[index].isActive = false }
        var workspace = WorkbenchWorkspace(
            id: id,
            name: resolvedName,
            attachedFolders: attachedFolders,
            newPaneFolder: newPaneFolder,
            isActive: true,
            automationPolicy: automationPolicy,
            workspaceID: id
        )
        workspace.lastSelectedAt = now
        document.workspaces.append(workspace)
        if initialShell {
            let pane = try makePane(
                kind: .shell,
                cwd: launchFolder,
                workspace: workspace,
                started: true,
                permissionProfile: nil
            )
            document.panes.append(pane)
            document.activity[pane.id] = Date()
        }
        return workspace
    }

    private func makePane(
        kind: PaneKind,
        cwd: String,
        workspace: WorkbenchWorkspace,
        started: Bool,
        permissionProfile: EffectivePermissionProfile?
    ) throws -> WorkbenchPane {
        // Every pane is constructed here, under the mutation lock.
        try requireNotReservedForRemoval(cwd)
        let plan = permissionProfile.map { PermissionProfileAdapter.launchPlan(for: kind, profile: $0) }
        let paneID = Self.paneID()
        let pane = WorkbenchPane(
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
        if started { recordLaunchPermissionsLocked(pane, profile: permissionProfile) }
        return pane
    }

    private func markStartedLocked(index: Int, profile: EffectivePermissionProfile?) {
        document.panes[index].cwd = document.panes[index].launchWorkingDirectory
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
        document.panes[index].permissionEnforcement = document.panes[index].containerConfiguration?.bypassVendorPermissions == true
            ? .guidanceOnly : profile.map {
                PermissionProfileAdapter.launchPlan(for: document.panes[index].kind, profile: $0).enforcement
            }
        document.activity[document.panes[index].id] = Date()
        recordLaunchPermissionsLocked(document.panes[index], profile: profile)
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
            approvals: selection?.approvals ?? .person,
            fileManager: fileManager
        )
    }

    private func workspaceIndexLocked(_ reference: String) throws -> Int {
        guard let index = document.workspaces.firstIndex(where: {
            $0.id == reference || $0.workspaceID == reference
        }) else { throw ParleyWorkbenchError.workspaceNotFound(reference) }
        return index
    }

    /// Makes one workspace the active one. When that changes which workspace
    /// is active, both sides are stamped: the one left and the one entered
    /// were both last used now, and the sidebar's Recent section is ordered
    /// by it. The stamps live in the document, so a change that is rolled
    /// back takes them with it. A workspace id that is not there leaves none
    /// active, as the loops this replaces did.
    private func activateWorkspaceLocked(workspaceID: String, now: Date = Date()) {
        let left = document.workspaces.firstIndex(where: \.isActive)
        let entered = document.workspaces.firstIndex(where: { $0.workspaceID == workspaceID })
        for position in document.workspaces.indices { document.workspaces[position].isActive = position == entered }
        guard let entered, left != entered else { return }
        if let left { document.workspaces[left].lastSelectedAt = now }
        document.workspaces[entered].lastSelectedAt = now
    }

    private func selectWorkspaceLocked(_ workspaceID: String) throws {
        let index = try workspaceIndexLocked(workspaceID)
        let durableID = document.workspaces[index].workspaceID
        activateWorkspaceLocked(workspaceID: durableID)
        if let paneIndex = document.panes.firstIndex(where: { $0.workspaceID == durableID }) {
            for position in document.panes.indices { document.panes[position].isActive = position == paneIndex }
        }
    }

    private func normalizeSelectionLocked() {
        if !document.workspaces.contains(where: \.isActive), let first = document.workspaces.first {
            activateWorkspaceLocked(workspaceID: first.workspaceID)
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
        try OwnerOnlyFile.write(try encoder.encode(document), to: stateFile, fileManager: fileManager)
        // The whole document was just written, so any deferred title is durable too.
        titlePersistencePending = false
        lastDeferredPersistenceErrorStorage = nil
        persistWriteCountStorage += 1
    }

    /// Every creation, start and restart passes through here, so a folder
    /// reserved by a native removal in flight refuses new processes on every
    /// route, not only the toolbar actions that happen to check.
    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ParleyWorkbenchError.invalidDirectory(path)
        }
        try requireNotReservedForRemoval(path)
    }

    /// Called again inside the mutation lock by `makePane`, so a reservation
    /// inserted between an early check and the mutation still refuses.
    private func requireNotReservedForRemoval(_ path: String) throws {
        let reserved = lock.withLock { removalReservations }
        if let blocking = reserved.first(where: { WorktreeCleanupPolicy.isNested(path, in: $0) }) {
            throw ParleyWorkbenchError.folderReservedForRemoval(blocking)
        }
    }

    // MARK: Folder reservations

    /// Canonical folders a native worktree removal is working on. Memory-only;
    /// the removal releases them when it finishes, whatever its outcome.
    private var removalReservations: Set<String> = []

    public func reserveFolderForRemoval(_ path: String) throws {
        let canonical = GitWorktreeResolver.canonicalPath(path)
        try lock.withLock {
            guard !removalReservations.contains(canonical) else {
                throw ParleyWorkbenchError.folderReservedForRemoval(canonical)
            }
            removalReservations.insert(canonical)
        }
    }

    public func releaseFolderReservation(_ path: String) {
        let canonical = GitWorktreeResolver.canonicalPath(path)
        lock.withLock { _ = removalReservations.remove(canonical) }
    }

    public func reservedFolders() -> [String] {
        lock.withLock { removalReservations.sorted() }
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
