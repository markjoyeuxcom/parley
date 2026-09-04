import Foundation

public enum PaneKind: String, CaseIterable, Codable, Sendable {
    case shell
    case claude
    case codex
    case agy
    case copilot

    public var isAgent: Bool { self != .shell }

    public var label: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude"
        case .codex: "Codex"
        case .agy: "Agy"
        case .copilot: "Copilot"
        }
    }

}

public enum SplitDirection: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// The maximum agent-initiated coordination a workspace permits. Human native
/// controls remain available at every level; this gate applies to commands a
/// model invokes through its pane-scoped `parley` capability.
public enum WorkspaceAutomationPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case off
    case askAnswer
    case askAndDelegate

    public var label: String {
        switch self {
        case .off: "Off"
        case .askAnswer: "Ask/Answer"
        case .askAndDelegate: "Ask + Delegation"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Agents cannot submit cross-vendor messages or start new tracked work."
        case .askAnswer: "Agents may relay messages and run correlated Ask/Answer consultations."
        case .askAndDelegate: "Agents may also assign and track asynchronous work."
        }
    }

    public func allows(_ kind: RelayHandoffKind) -> Bool {
        switch kind {
        case .paste:
            true
        case .relay, .ask:
            self != .off
        case .delegate:
            self == .askAndDelegate
        }
    }
}

/// A Parley workspace is a durable collaboration identity whose panes are
/// retained Ghostty exec surfaces. Folder attachments are explicit lookup and
/// presentation metadata; they are not workspace identity, process working
/// directories, or permission grants. A workspace may have none. The optional
/// New Pane Folder is an independent launch preference.
public struct WorkbenchWorkspace: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var attachedFolders: [String]
    public var newPaneFolder: String?
    public var isActive: Bool
    public var automationPolicy: WorkspaceAutomationPolicy
    /// Durable workspace identity, intentionally independent of a process id.
    public var workspaceID: String

    public init(
        id: String,
        name: String,
        attachedFolders: [String] = [],
        newPaneFolder: String? = nil,
        isActive: Bool,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate,
        workspaceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.attachedFolders = Self.normalizedFolders(attachedFolders)
        self.newPaneFolder = newPaneFolder.flatMap {
            $0.hasPrefix("/") ? WorkspaceFolderIdentity.normalized($0) : nil
        }
        self.isActive = isActive
        self.automationPolicy = automationPolicy
        self.workspaceID = workspaceID ?? id
    }

    /// Source-compatible construction for records and tests written before
    /// workspace identity was separated from one required folder.
    public init(
        id: String,
        name: String,
        homeFolder: String? = nil,
        defaultFolder: String,
        isActive: Bool,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate,
        workspaceID: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            attachedFolders: [homeFolder ?? defaultFolder],
            newPaneFolder: defaultFolder,
            isActive: isActive,
            automationPolicy: automationPolicy,
            workspaceID: workspaceID
        )
    }

    public var primaryAttachedFolder: String? { attachedFolders.first }
    public var isFolderless: Bool { attachedFolders.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case attachedFolders
        case newPaneFolder
        case isActive
        case automationPolicy
        case workspaceID
        // Legacy schema fields. Decode only; new records never write them.
        case homeFolder
        case defaultFolder
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        if values.contains(.attachedFolders) {
            attachedFolders = Self.normalizedFolders(
                try values.decode([String].self, forKey: .attachedFolders)
            )
        } else if let legacyHome = try values.decodeIfPresent(String.self, forKey: .homeFolder) {
            attachedFolders = Self.normalizedFolders([legacyHome])
        } else if let legacyDefault = try values.decodeIfPresent(String.self, forKey: .defaultFolder) {
            attachedFolders = Self.normalizedFolders([legacyDefault])
        } else {
            attachedFolders = []
        }
        if values.contains(.newPaneFolder) {
            newPaneFolder = try values.decodeIfPresent(String.self, forKey: .newPaneFolder)
                .flatMap { $0.hasPrefix("/") ? WorkspaceFolderIdentity.normalized($0) : nil }
        } else {
            newPaneFolder = try values.decodeIfPresent(String.self, forKey: .defaultFolder)
                .flatMap { $0.hasPrefix("/") ? WorkspaceFolderIdentity.normalized($0) : nil }
        }
        isActive = try values.decode(Bool.self, forKey: .isActive)
        automationPolicy = try values.decodeIfPresent(
            WorkspaceAutomationPolicy.self,
            forKey: .automationPolicy
        ) ?? .askAndDelegate
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID) ?? id
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(attachedFolders, forKey: .attachedFolders)
        try values.encodeIfPresent(newPaneFolder, forKey: .newPaneFolder)
        try values.encode(isActive, forKey: .isActive)
        try values.encode(automationPolicy, forKey: .automationPolicy)
        try values.encode(workspaceID, forKey: .workspaceID)
    }

    private static func normalizedFolders(_ folders: [String]) -> [String] {
        var seen: Set<String> = []
        return Array(folders.compactMap { folder in
            let normalized = WorkspaceFolderIdentity.normalized(folder)
            guard normalized.hasPrefix("/") else { return nil }
            let key = WorkspaceFolderIdentity.matchingKey(normalized)
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }.prefix(32))
    }
}

public struct WorkbenchPane: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var kind: PaneKind
    public var customName: String?
    public var terminalTitle: String
    public var cwd: String
    public var currentCommand: String
    public var isActive: Bool
    public var relayEnabled: Bool
    public var protocolVersion: String?
    public var workspaceName: String?
    /// Whether the retained Ghostty surface is attached and can accept input.
    /// This is not a claim that the vendor is idle or at its prompt.
    public var inputAvailable: Bool
    public var vendorRuntimeState: VendorRuntimeState?
    public var vendorRuntimeSignal: VendorHookSignal?
    public var vendorRuntimeSignaledAt: Date?
    public var isDead: Bool
    public var exitStatus: Int?
    public var isStarted: Bool
    public var isWorkspaceLead: Bool
    public var role: String?
    public var automationPolicy: WorkspaceAutomationPolicy
    public var permissionSelection: PermissionProfileSelection?
    public var permissionEnforcement: PermissionEnforcementLevel?
    /// Changes whenever Parley must replace this pane's Ghostty exec surface.
    /// It is app-owned identity, not a process id and not a persisted vendor
    /// session identifier.
    public var launchGeneration: Int
    /// The durable identity of the workspace containing this pane.
    public var workspaceID: String

    public init(
        id: String,
        kind: PaneKind,
        customName: String?,
        terminalTitle: String,
        cwd: String,
        currentCommand: String,
        isActive: Bool,
        workspaceID: String,
        relayEnabled: Bool = false,
        protocolVersion: String? = nil,
        workspaceName: String? = nil,
        inputAvailable: Bool = false,
        vendorRuntimeState: VendorRuntimeState? = nil,
        vendorRuntimeSignal: VendorHookSignal? = nil,
        vendorRuntimeSignaledAt: Date? = nil,
        isDead: Bool = false,
        exitStatus: Int? = nil,
        isStarted: Bool = true,
        isWorkspaceLead: Bool = false,
        role: String? = nil,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate,
        permissionSelection: PermissionProfileSelection? = nil,
        permissionEnforcement: PermissionEnforcementLevel? = nil,
        launchGeneration: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.customName = customName
        self.terminalTitle = terminalTitle
        self.cwd = cwd
        self.currentCommand = currentCommand
        self.isActive = isActive
        self.workspaceID = workspaceID
        self.relayEnabled = relayEnabled
        self.protocolVersion = protocolVersion
        self.workspaceName = workspaceName
        self.inputAvailable = inputAvailable
        self.vendorRuntimeState = vendorRuntimeState
        self.vendorRuntimeSignal = vendorRuntimeSignal
        self.vendorRuntimeSignaledAt = vendorRuntimeSignaledAt
        self.isDead = isDead
        self.exitStatus = exitStatus
        self.isStarted = isStarted
        self.isWorkspaceLead = isWorkspaceLead
        self.role = role
        self.automationPolicy = automationPolicy
        self.permissionSelection = permissionSelection
        self.permissionEnforcement = permissionEnforcement
        self.launchGeneration = launchGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case customName
        case terminalTitle
        case cwd
        case currentCommand
        case isActive
        case relayEnabled
        case protocolVersion
        case workspaceName
        case inputAvailable
        case vendorRuntimeState
        case vendorRuntimeSignal
        case vendorRuntimeSignaledAt
        case isDead
        case exitStatus
        case isStarted
        case isWorkspaceLead
        case role
        case automationPolicy
        case permissionSelection
        case permissionEnforcement
        case launchGeneration
        case workspaceID
        // Decode-only fields from the tmux and pre-broker schemas.
        case windowID
        case returnToPaneID
        case bracketedPasteActive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(PaneKind.self, forKey: .kind)
        customName = try values.decodeIfPresent(String.self, forKey: .customName)
        terminalTitle = try values.decode(String.self, forKey: .terminalTitle)
        cwd = try values.decode(String.self, forKey: .cwd)
        currentCommand = try values.decode(String.self, forKey: .currentCommand)
        isActive = try values.decode(Bool.self, forKey: .isActive)
        relayEnabled = try values.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? false
        protocolVersion = try values.decodeIfPresent(String.self, forKey: .protocolVersion)
        workspaceName = try values.decodeIfPresent(String.self, forKey: .workspaceName)
        inputAvailable = try values.decodeIfPresent(Bool.self, forKey: .inputAvailable) ?? false
        vendorRuntimeState = try values.decodeIfPresent(VendorRuntimeState.self, forKey: .vendorRuntimeState)
        vendorRuntimeSignal = try values.decodeIfPresent(VendorHookSignal.self, forKey: .vendorRuntimeSignal)
        vendorRuntimeSignaledAt = try values.decodeIfPresent(Date.self, forKey: .vendorRuntimeSignaledAt)
        isDead = try values.decodeIfPresent(Bool.self, forKey: .isDead) ?? false
        exitStatus = try values.decodeIfPresent(Int.self, forKey: .exitStatus)
        isStarted = try values.decodeIfPresent(Bool.self, forKey: .isStarted) ?? true
        isWorkspaceLead = try values.decodeIfPresent(Bool.self, forKey: .isWorkspaceLead) ?? false
        role = try values.decodeIfPresent(String.self, forKey: .role)
        automationPolicy = try values.decodeIfPresent(
            WorkspaceAutomationPolicy.self,
            forKey: .automationPolicy
        ) ?? .askAndDelegate
        permissionSelection = try values.decodeIfPresent(
            PermissionProfileSelection.self,
            forKey: .permissionSelection
        )
        permissionEnforcement = try values.decodeIfPresent(
            PermissionEnforcementLevel.self,
            forKey: .permissionEnforcement
        )
        launchGeneration = try values.decodeIfPresent(Int.self, forKey: .launchGeneration) ?? 0
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
            ?? values.decodeIfPresent(String.self, forKey: .windowID)
            ?? id
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(customName, forKey: .customName)
        try values.encode(terminalTitle, forKey: .terminalTitle)
        try values.encode(cwd, forKey: .cwd)
        try values.encode(currentCommand, forKey: .currentCommand)
        try values.encode(isActive, forKey: .isActive)
        try values.encode(relayEnabled, forKey: .relayEnabled)
        try values.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try values.encodeIfPresent(workspaceName, forKey: .workspaceName)
        try values.encode(inputAvailable, forKey: .inputAvailable)
        try values.encodeIfPresent(vendorRuntimeState, forKey: .vendorRuntimeState)
        try values.encodeIfPresent(vendorRuntimeSignal, forKey: .vendorRuntimeSignal)
        try values.encodeIfPresent(vendorRuntimeSignaledAt, forKey: .vendorRuntimeSignaledAt)
        try values.encode(isDead, forKey: .isDead)
        try values.encodeIfPresent(exitStatus, forKey: .exitStatus)
        try values.encode(isStarted, forKey: .isStarted)
        try values.encode(isWorkspaceLead, forKey: .isWorkspaceLead)
        try values.encodeIfPresent(role, forKey: .role)
        try values.encode(automationPolicy, forKey: .automationPolicy)
        try values.encodeIfPresent(permissionSelection, forKey: .permissionSelection)
        try values.encodeIfPresent(permissionEnforcement, forKey: .permissionEnforcement)
        try values.encode(launchGeneration, forKey: .launchGeneration)
        try values.encode(workspaceID, forKey: .workspaceID)
    }

    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return kind.label
    }

    public var hasCurrentProtocol: Bool {
        !kind.isAgent || protocolVersion == AgentProtocol.version
    }
}

public enum ParleyWorkbenchError: LocalizedError, Equatable {
    case invalidDirectory(String)
    case commandFailed(String)
    case paneNotFound(String)
    case noRelayText
    case samePane
    case notAgentPane
    case cannotCloseLastPane
    case workspaceNotFound(String)
    case cannotCloseLastWorkspace
    case copilotTrustRequired
    case unsafeRelayTarget(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDirectory(path):
            "The folder does not exist: \(path)"
        case let .commandFailed(detail):
            detail
        case let .paneNotFound(id):
            "The pane no longer exists: \(id)"
        case .noRelayText:
            "Select terminal text first; Parley never captures scrollback implicitly."
        case .samePane:
            "Choose another agent pane; a pane cannot send an Ask to itself."
        case .notAgentPane:
            "Ask requires two agent panes."
        case .cannotCloseLastPane:
            "Keep one pane open so the workspace remains available."
        case let .workspaceNotFound(id):
            "The workspace no longer exists: \(id)"
        case .cannotCloseLastWorkspace:
            "Keep one workspace open so the workbench remains available."
        case .copilotTrustRequired:
            "Copilot needs folder trust before it can receive handoffs. Resolve its folder-trust prompt, then choose Confirm Copilot Folder Trust from the pane menu and retry."
        case let .unsafeRelayTarget(name):
            "\(name) is not ready for safe relay input. Focus it and wait for its prompt, or restart the pane if its Relay badge is stale."
        }
    }
}
