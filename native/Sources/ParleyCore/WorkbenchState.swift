import Foundation

public enum WorkbenchConnectionState: Equatable, Sendable {
    case connected
    case coreDisconnected
    case tmuxDisconnected
}

public enum WorkbenchPaneState: Equatable, Sendable {
    case empty
    case running
    case stopped
    case exited(status: Int?)
    case protocolStale(reportedVersion: String?)
    case relayUnavailable
}

public enum WorkbenchProtocolStatus: Equatable, Sendable {
    case notAttached
    case current(version: String)
    case restartRequired(reportedVersion: String?)
}

public enum WorkbenchStateProjection {
    public static func connection(
        tmuxAvailable: Bool,
        coreAvailable: Bool
    ) -> WorkbenchConnectionState {
        if !tmuxAvailable { return .tmuxDisconnected }
        if !coreAvailable { return .coreDisconnected }
        return .connected
    }

    public static func pane(_ pane: TmuxPane?) -> WorkbenchPaneState {
        guard let pane else { return .empty }
        if pane.kind.isAgent, !pane.isStarted { return .stopped }
        if pane.isDead { return .exited(status: pane.exitStatus) }
        if pane.kind.isAgent, !pane.hasCurrentProtocol {
            return .protocolStale(reportedVersion: pane.protocolVersion)
        }
        if pane.kind.isAgent, !pane.relayEnabled { return .relayUnavailable }
        return .running
    }

    /// The version Parley injected when this agent process was started. This
    /// is an authoritative launch stamp, not a claim that the model understood
    /// or followed the protocol text.
    public static func protocolStatus(_ pane: TmuxPane) -> WorkbenchProtocolStatus {
        guard pane.kind.isAgent, pane.isStarted else { return .notAttached }
        guard pane.protocolVersion == AgentProtocol.version else {
            return .restartRequired(reportedVersion: pane.protocolVersion)
        }
        return .current(version: AgentProtocol.version)
    }
}
