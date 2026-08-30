import Foundation

public enum RecoveryGuidanceTopic: String, CaseIterable, Equatable, Sendable {
    case damagedSocket
    case missingCLI
    case staleProtocol
    case deadPane
    case interruptedConsultation
}

public enum RecoveryGuidanceAction: Equatable, Sendable {
    case reconnect
    case refreshEnvironment
    case restartPane(String)
    case inspectHandoff(String)
}

public struct RecoveryGuidanceIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let topic: RecoveryGuidanceTopic
    public let title: String
    public let detail: String
    public let actionLabel: String
    public let action: RecoveryGuidanceAction

    public init(
        id: String,
        topic: RecoveryGuidanceTopic,
        title: String,
        detail: String,
        actionLabel: String,
        action: RecoveryGuidanceAction
    ) {
        self.id = id
        self.topic = topic
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
        self.action = action
    }
}

public struct RecoveryPlaybookEntry: Identifiable, Equatable, Sendable {
    public let topic: RecoveryGuidanceTopic
    public let title: String
    public let symptom: String
    public let steps: [String]

    public var id: RecoveryGuidanceTopic { topic }

    public init(
        topic: RecoveryGuidanceTopic,
        title: String,
        symptom: String,
        steps: [String]
    ) {
        self.topic = topic
        self.title = title
        self.symptom = symptom
        self.steps = steps
    }
}

/// Produces recovery guidance only from facts Parley owns. It never infers a
/// vendor's internal state and never suggests deleting local coordination
/// files or starting a second app instance.
public enum RecoveryGuidanceProjection {
    public static let playbook: [RecoveryPlaybookEntry] = [
        RecoveryPlaybookEntry(
            topic: .damagedSocket,
            title: "Coordination socket unavailable",
            symptom: "Terminals still work, but Ask, Return and tracked handoffs report that the local core cannot be reached.",
            steps: [
                "Keep Parley open; its retained Ghostty panes remain usable while coordination reconnects.",
                "Choose Reconnect once. Parley rebuilds its app-resident authenticated coordination endpoints.",
                "If Reconnect still fails, run Environment Check and export Diagnostics. Do not start a second Parley instance or delete socket files by hand.",
            ]
        ),
        RecoveryPlaybookEntry(
            topic: .missingCLI,
            title: "Vendor CLI missing",
            symptom: "A vendor is unavailable on the login PATH resolved for the macOS app.",
            steps: [
                "Open Environment Check to see which optional vendor CLI is missing.",
                "Install that vendor's CLI using its official instructions and complete its normal subscription sign-in in Terminal.",
                "Choose Check Again. Existing panes from other vendors do not need to restart.",
            ]
        ),
        RecoveryPlaybookEntry(
            topic: .staleProtocol,
            title: "Pane protocol is stale",
            symptom: "The terminal remains usable, but Parley disables cross-vendor commands for a pane launched with older shared instructions.",
            steps: [
                "Finish or preserve anything you still need from the current CLI conversation.",
                "Restart only the pane marked Protocol Stale; restarting deliberately ends that pane's current CLI process.",
                "The replacement pane receives the current shared protocol automatically. Other panes keep running.",
            ]
        ),
        RecoveryPlaybookEntry(
            topic: .deadPane,
            title: "Pane process exited",
            symptom: "The embedded terminal retained the pane after its shell or agent process exited, including its final output.",
            steps: [
                "Read the preserved terminal output before taking action.",
                "Choose Restart to launch a new process in the same pane and folder, or close the pane if it is no longer needed.",
                "Restarting an agent starts a new CLI process; Parley does not pretend the previous vendor conversation survived.",
            ]
        ),
        RecoveryPlaybookEntry(
            topic: .interruptedConsultation,
            title: "Consultation was interrupted",
            symptom: "A blocking Ask ended because a pane or the coordination core stopped before an answer returned.",
            steps: [
                "Inspect the durable handoff record and its final delivery receipt to see the explicit interruption reason.",
                "Confirm the target pane is running, current and at a prompt before asking again.",
                "Start a new Ask when ready. An interrupted Ask is never replayed automatically because delivery may already have occurred.",
            ]
        ),
    ]

    public static func issues(
        coreAvailable: Bool,
        readiness: RuntimeReadinessSnapshot?,
        panes: [WorkbenchPane],
        handoffs: [RelayHandoff],
        workspaceID: String?
    ) -> [RecoveryGuidanceIssue] {
        var issues: [RecoveryGuidanceIssue] = []

        if !coreAvailable {
            issues.append(RecoveryGuidanceIssue(
                id: "recovery:damaged-socket",
                topic: .damagedSocket,
                title: "Coordination socket is unavailable",
                detail: "Terminal panes remain attached. Cross-vendor actions are paused until Parley reconnects to its authenticated local core.",
                actionLabel: "Reconnect",
                action: .reconnect
            ))
        }

        let missingVendors = readiness?.vendorItems
            .filter { $0.state == .unavailable }
            .map(\.title)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            ?? []
        if !missingVendors.isEmpty {
            let names = missingVendors.joined(separator: ", ")
            issues.append(RecoveryGuidanceIssue(
                id: "recovery:missing-cli",
                topic: .missingCLI,
                title: missingVendors.count == 1 ? "\(names) CLI is missing" : "Vendor CLIs are missing",
                detail: "\(names) \(missingVendors.count == 1 ? "is" : "are") unavailable on Parley's resolved login PATH. Other installed vendors remain usable.",
                actionLabel: "Check Again",
                action: .refreshEnvironment
            ))
        }

        let workspaceAliases: Set<String> = if let workspaceID {
            Set(panes.lazy.filter { $0.workspaceID == workspaceID }.map(\.workspaceID))
                .union([workspaceID])
        } else {
            []
        }
        let scopedPanes = panes
            .filter { pane in
                pane.kind.isAgent && (workspaceID == nil || workspaceAliases.contains(pane.workspaceID))
            }
            .sorted { left, right in
                if left.displayName.caseInsensitiveCompare(right.displayName) == .orderedSame {
                    return left.id < right.id
                }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }

        for pane in scopedPanes where isProtocolStale(pane) {
            issues.append(RecoveryGuidanceIssue(
                id: "recovery:stale-protocol:\(pane.id)",
                topic: .staleProtocol,
                title: "\(pane.displayName) has a stale protocol",
                detail: "Its terminal is usable, but cross-vendor actions are disabled. Restarting ends only this pane's current CLI process and supplies protocol v\(AgentProtocol.version).",
                actionLabel: "Restart…",
                action: .restartPane(pane.id)
            ))
        }

        for pane in scopedPanes where isDead(pane) {
            let status = pane.exitStatus.map { " with status \($0)" } ?? ""
            issues.append(RecoveryGuidanceIssue(
                id: "recovery:dead-pane:\(pane.id)",
                topic: .deadPane,
                title: "\(pane.displayName) exited\(status)",
                detail: "Ghostty preserved its final output. Restarting begins a new \(pane.kind.label) process in the same pane and folder.",
                actionLabel: "Restart…",
                action: .restartPane(pane.id)
            ))
        }

        let interrupted = handoffs
            .filter { handoff in
                guard handoff.kind == .ask, handoff.state == .interrupted else { return false }
                guard workspaceID != nil else { return true }
                return workspaceAliases.contains(handoff.sourceWorkspaceID)
                    || workspaceAliases.contains(handoff.targetWorkspaceID)
            }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt { return left.id < right.id }
                return left.updatedAt > right.updatedAt
            }
        if let latest = interrupted.first {
            let count = interrupted.count
            issues.append(RecoveryGuidanceIssue(
                id: "recovery:interrupted-consultation",
                topic: .interruptedConsultation,
                title: count == 1 ? "A consultation was interrupted" : "\(count) consultations were interrupted",
                detail: "The waiting command was released and the reason remains in the durable delivery receipts. Interrupted Ask delivery is never replayed automatically.",
                actionLabel: count == 1 ? "Inspect" : "Inspect Latest",
                action: .inspectHandoff(latest.id)
            ))
        }

        return issues
    }

    private static func isProtocolStale(_ pane: WorkbenchPane) -> Bool {
        if case .protocolStale = WorkbenchStateProjection.pane(pane) { return true }
        return false
    }

    private static func isDead(_ pane: WorkbenchPane) -> Bool {
        if case .exited = WorkbenchStateProjection.pane(pane) { return true }
        return false
    }
}
