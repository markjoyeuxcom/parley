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

/// A Parley workspace is a durable tmux window. The id belongs only to the
/// live tmux server; the human-facing name and default folder are stored as
/// window options so closing and reopening the UI does not lose them.
public struct TmuxWorkspace: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let defaultFolder: String
    public let isActive: Bool
    public let automationPolicy: WorkspaceAutomationPolicy

    public init(
        id: String,
        name: String,
        defaultFolder: String,
        isActive: Bool,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate
    ) {
        self.id = id
        self.name = name
        self.defaultFolder = defaultFolder
        self.isActive = isActive
        self.automationPolicy = automationPolicy
    }
}

public struct TmuxPane: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: PaneKind
    public let customName: String?
    public let terminalTitle: String
    public let cwd: String
    public let currentCommand: String
    public let isActive: Bool
    public let windowID: String
    public let returnToPaneID: String?
    public let relayEnabled: Bool
    public let protocolVersion: String?
    public let workspaceName: String?
    public let bracketedPasteActive: Bool
    public let isDead: Bool
    public let exitStatus: Int?
    public let isStarted: Bool
    public let isWorkspaceLead: Bool
    public let role: String?
    public let automationPolicy: WorkspaceAutomationPolicy
    public let permissionSelection: PermissionProfileSelection?
    public let permissionEnforcement: PermissionEnforcementLevel?

    public init(
        id: String,
        kind: PaneKind,
        customName: String?,
        terminalTitle: String,
        cwd: String,
        currentCommand: String,
        isActive: Bool,
        windowID: String,
        returnToPaneID: String?,
        relayEnabled: Bool = false,
        protocolVersion: String? = nil,
        workspaceName: String? = nil,
        bracketedPasteActive: Bool = false,
        isDead: Bool = false,
        exitStatus: Int? = nil,
        isStarted: Bool = true,
        isWorkspaceLead: Bool = false,
        role: String? = nil,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate,
        permissionSelection: PermissionProfileSelection? = nil,
        permissionEnforcement: PermissionEnforcementLevel? = nil
    ) {
        self.id = id
        self.kind = kind
        self.customName = customName
        self.terminalTitle = terminalTitle
        self.cwd = cwd
        self.currentCommand = currentCommand
        self.isActive = isActive
        self.windowID = windowID
        self.returnToPaneID = returnToPaneID
        self.relayEnabled = relayEnabled
        self.protocolVersion = protocolVersion
        self.workspaceName = workspaceName
        self.bracketedPasteActive = bracketedPasteActive
        self.isDead = isDead
        self.exitStatus = exitStatus
        self.isStarted = isStarted
        self.isWorkspaceLead = isWorkspaceLead
        self.role = role
        self.automationPolicy = automationPolicy
        self.permissionSelection = permissionSelection
        self.permissionEnforcement = permissionEnforcement
    }

    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return kind.label
    }

    public var hasCurrentProtocol: Bool {
        !kind.isAgent || protocolVersion == AgentProtocol.version
    }
}

public enum ParleyTmuxError: LocalizedError, Equatable {
    case tmuxNotFound
    case invalidDirectory(String)
    case commandFailed(String)
    case paneNotFound(String)
    case noRelayText
    case sameVendor
    case notAgentPane
    case noReturnRoute
    case cannotCloseLastPane
    case workspaceNotFound(String)
    case cannotCloseLastWorkspace
    case copilotTrustRequired
    case unsafeRelayTarget(String)

    public var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            "tmux was not found. Install it or set PARLEY_TMUX to its absolute path."
        case let .invalidDirectory(path):
            "The folder does not exist: \(path)"
        case let .commandFailed(detail):
            detail
        case let .paneNotFound(id):
            "The tmux pane no longer exists: \(id)"
        case .noRelayText:
            "That pane has no output to relay yet."
        case .sameVendor:
            "Ask is cross-vendor; use the CLI's own delegation for the same vendor."
        case .notAgentPane:
            "Ask requires two agent panes."
        case .noReturnRoute:
            "This pane does not owe an answer to another pane."
        case .cannotCloseLastPane:
            "Keep one pane open so the Parley tmux session remains attached."
        case let .workspaceNotFound(id):
            "The tmux workspace no longer exists: \(id)"
        case .cannotCloseLastWorkspace:
            "Keep one workspace open so the Parley tmux session remains attached."
        case .copilotTrustRequired:
            "Copilot needs folder trust before it can receive an Ask. Focus its pane, approve the folder if you trust it, then retry."
        case let .unsafeRelayTarget(name):
            "\(name) is not ready for safe relay input. Focus it and wait for its prompt, or restart the pane if its Relay badge is stale."
        }
    }
}
