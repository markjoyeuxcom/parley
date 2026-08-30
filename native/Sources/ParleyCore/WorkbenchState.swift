import Foundation

public enum WorkbenchConnectionState: Equatable, Sendable {
    case connected
    case coreDisconnected
    case terminalDisconnected
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

public enum RuntimeCoreLifecycle: Equatable, Sendable {
    case unavailable
    case checking
    case current(detail: String?)
}

public enum RuntimeProtocolLifecycle: Equatable, Sendable {
    case current(version: String, runningPaneCount: Int)
    case restartRequired(version: String, paneIDs: [String])
}

public struct RuntimeLifecycleSnapshot: Equatable, Sendable {
    public let core: RuntimeCoreLifecycle
    public let `protocol`: RuntimeProtocolLifecycle

    public init(core: RuntimeCoreLifecycle, protocol: RuntimeProtocolLifecycle) {
        self.core = core
        self.protocol = `protocol`
    }
}

public enum RuntimeLifecycleProjection {
    /// Projects only lifecycle facts Parley owns: whether the current UI may
    /// replace its core, the result of that reconciliation, and the exact
    /// launch stamps on running agent panes.
    public static func snapshot(
        coreAvailable: Bool,
        coreMessage: String?,
        panes: [WorkbenchPane]
    ) -> RuntimeLifecycleSnapshot {
        let core: RuntimeCoreLifecycle
        if !coreAvailable {
            core = .unavailable
        } else if let coreMessage {
            core = .current(detail: coreMessage)
        } else {
            core = .checking
        }

        let stalePaneIDs = AgentProtocol.stalePaneIDs(in: panes).sorted()
        let protocolLifecycle: RuntimeProtocolLifecycle
        if stalePaneIDs.isEmpty {
            let runningPaneCount = panes.count {
                $0.kind.isAgent && $0.isStarted && !$0.isDead
            }
            protocolLifecycle = .current(
                version: AgentProtocol.version,
                runningPaneCount: runningPaneCount
            )
        } else {
            protocolLifecycle = .restartRequired(
                version: AgentProtocol.version,
                paneIDs: stalePaneIDs
            )
        }
        return RuntimeLifecycleSnapshot(core: core, protocol: protocolLifecycle)
    }
}

public enum WorkbenchStateProjection {
    public static func connection(
        terminalAvailable: Bool,
        coreAvailable: Bool
    ) -> WorkbenchConnectionState {
        if !terminalAvailable { return .terminalDisconnected }
        if !coreAvailable { return .coreDisconnected }
        return .connected
    }

    public static func pane(_ pane: WorkbenchPane?) -> WorkbenchPaneState {
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
    public static func protocolStatus(_ pane: WorkbenchPane) -> WorkbenchProtocolStatus {
        guard pane.kind.isAgent, pane.isStarted else { return .notAttached }
        guard pane.protocolVersion == AgentProtocol.version else {
            return .restartRequired(reportedVersion: pane.protocolVersion)
        }
        return .current(version: AgentProtocol.version)
    }
}

/// Small, deterministic labels for the workbench chrome. These are derived
/// only from state Parley owns; the UI must not turn a live process into an
/// inferred claim that a vendor is ready, thinking or finished.
public enum WorkbenchChromeProjection {
    public static func selectionLabel(_ pane: WorkbenchPane) -> String? {
        pane.isActive ? "SELECTED" : nil
    }

    public static func processLabel(_ pane: WorkbenchPane) -> String {
        switch WorkbenchStateProjection.pane(pane) {
        case .empty:
            "EMPTY"
        case .running:
            "RUNNING"
        case .stopped:
            "STOPPED"
        case let .exited(status):
            status.map { "EXITED \($0)" } ?? "EXITED"
        case .protocolStale:
            "RESTART FOR PROTOCOL"
        case .relayUnavailable:
            "RESTART FOR RELAY"
        }
    }

    public static func connectionLabel(_ state: WorkbenchConnectionState) -> String {
        switch state {
        case .connected:
            "Core healthy"
        case .coreDisconnected:
            "Core disconnected"
        case .terminalDisconnected:
            "Terminal unavailable"
        }
    }
}
