import Foundation

/// Text rules shared by every native chrome surface so labels are rendered
/// consistently: section headings stay uppercase, inline state chips read in
/// sentence case.
public enum ChromeLabel {
    /// Converts an all-caps state label such as `UNREAD RESULT` to
    /// `Unread result`. Mixed-case text, routing roles (`@reviewer`), version
    /// stamps (`v14`) and digits are returned unchanged.
    public static func chipCase(_ text: String) -> String {
        guard text.contains(where: \.isLetter),
              !text.contains(where: \.isLowercase) else { return text }
        let lowered = text.lowercased()
        guard let first = lowered.first else { return lowered }
        return String(first).uppercased() + lowered.dropFirst()
    }
}

public enum WorkbenchNoticeKind: String, CaseIterable, Codable, Equatable, Sendable {
    case permission
    case humanCheckpoint
    case failure
    case protocolStale
    case relayUnavailable
    case worktreeCollision
    case connection
    case targetAttention
    case paneStopped
    case activity
    case workflow
    case recipe
    case focusCanvas
}

/// Which semantic colour a notice may use. The palette is fixed: attention is
/// orange, failure is red, in-flight work is the accent, everything else is
/// neutral. Vendor identity never selects a colour.
public enum WorkbenchNoticeTone: Equatable, Sendable {
    case attention
    case failure
    case inFlight
    case neutral
}

public enum WorkbenchNoticeAction: Equatable, Sendable {
    case focusPane(String)
    case focusHandoffTarget(String)
    case focusHandoffSource(String)
    case restartPane(String)
    case startPane(String)
    case retryDelivery(String)
    case reconnect
    case openWorktrees(String)
    case openWorkflow
    case stopRecipe
    case exitFocusCanvas
}

public struct WorkbenchNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: WorkbenchNoticeKind
    public let tone: WorkbenchNoticeTone
    public let title: String
    public let detail: String
    public let actionLabel: String?
    public let action: WorkbenchNoticeAction?

    public init(
        id: String,
        kind: WorkbenchNoticeKind,
        tone: WorkbenchNoticeTone,
        title: String,
        detail: String,
        actionLabel: String?,
        action: WorkbenchNoticeAction?
    ) {
        self.id = id
        self.kind = kind
        self.tone = tone
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
        self.action = action
    }
}

/// The active pane as the notice lane needs it: identity only.
public struct WorkbenchNoticePane: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kindLabel: String

    public init(id: String, name: String, kindLabel: String) {
        self.id = id
        self.name = name
        self.kindLabel = kindLabel
    }
}

/// One handoff reduced to the facts a notice can state. Built from a
/// `RelayHandoff` in the app; constructible directly in checks.
public struct WorkbenchNoticeActivity: Equatable, Sendable {
    public let id: String
    public let sourceName: String
    public let targetName: String
    public let kindLabel: String
    public let subject: String
    public let state: RelayHandoffState
    public let attention: RelayAttention?
    public let canRetrySafely: Bool

    public init(
        id: String,
        sourceName: String,
        targetName: String,
        kindLabel: String,
        subject: String,
        state: RelayHandoffState,
        attention: RelayAttention?,
        canRetrySafely: Bool
    ) {
        self.id = id
        self.sourceName = sourceName
        self.targetName = targetName
        self.kindLabel = kindLabel
        self.subject = subject
        self.state = state
        self.attention = attention
        self.canRetrySafely = canRetrySafely
    }

    public init(handoff: RelayHandoff) {
        self.init(
            id: handoff.id,
            sourceName: handoff.sourceName,
            targetName: handoff.targetName,
            kindLabel: handoff.kind.rawValue,
            subject: WorkbenchAccessibility.subject(handoff.text),
            state: handoff.state,
            attention: handoff.attention,
            canRetrySafely: handoff.canRetrySafely
        )
    }

    public var isInFlight: Bool {
        [.created, .delivered, .waiting, .answered].contains(state)
    }
}

public struct WorkbenchRecipeNotice: Equatable, Sendable {
    public let name: String
    public let leadName: String

    public init(name: String, leadName: String) {
        self.name = name
        self.leadName = leadName
    }
}

public struct WorkbenchWorkflowNotice: Equatable, Sendable {
    public let name: String
    public let phaseLabel: String
    public let modeLabel: String
    public let awaitsHumanDecision: Bool

    public init(name: String, phaseLabel: String, modeLabel: String, awaitsHumanDecision: Bool) {
        self.name = name
        self.phaseLabel = phaseLabel
        self.modeLabel = modeLabel
        self.awaitsHumanDecision = awaitsHumanDecision
    }

    public init(run: SupervisedWorkflowRun) {
        self.init(
            name: run.name,
            phaseLabel: run.phase.label,
            modeLabel: run.mode.label,
            awaitsHumanDecision: run.phase == .awaitingImplementationApproval
                || run.phase == .awaitingCompletionApproval
        )
    }
}

public struct WorkbenchWorktreeNotice: Equatable, Sendable {
    public let path: String
    public let writerNames: [String]

    public init(path: String, writerNames: [String]) {
        self.path = path
        self.writerNames = writerNames
    }
}

public struct WorkbenchNoticeInputs: Equatable, Sendable {
    public var activePane: WorkbenchNoticePane?
    public var activePaneState: WorkbenchPaneState
    public var connectionState: WorkbenchConnectionState
    public var worktreeCollisions: [WorkbenchWorktreeNotice]
    public var primaryActivity: WorkbenchNoticeActivity?
    public var attentionActivities: [WorkbenchNoticeActivity]
    public var recipe: WorkbenchRecipeNotice?
    public var workflow: WorkbenchWorkflowNotice?
    public var focusCanvasActive: Bool
    public var dockVisible: Bool
    public var protocolVersion: String

    public init(
        activePane: WorkbenchNoticePane?,
        activePaneState: WorkbenchPaneState,
        connectionState: WorkbenchConnectionState,
        worktreeCollisions: [WorkbenchWorktreeNotice],
        primaryActivity: WorkbenchNoticeActivity?,
        attentionActivities: [WorkbenchNoticeActivity],
        recipe: WorkbenchRecipeNotice?,
        workflow: WorkbenchWorkflowNotice?,
        focusCanvasActive: Bool,
        dockVisible: Bool,
        protocolVersion: String
    ) {
        self.activePane = activePane
        self.activePaneState = activePaneState
        self.connectionState = connectionState
        self.worktreeCollisions = worktreeCollisions
        self.primaryActivity = primaryActivity
        self.attentionActivities = attentionActivities
        self.recipe = recipe
        self.workflow = workflow
        self.focusCanvasActive = focusCanvasActive
        self.dockVisible = dockVisible
        self.protocolVersion = protocolVersion
    }
}

/// One prioritised list of notices for the strip above the terminal. The
/// first element is shown; the rest sit behind a count. Permission, failure,
/// protocol, relay and worktree facts are always present when their inputs
/// are, regardless of anything else on screen. In-flight activity joins the
/// lane only while the Collaboration Dock is hidden, because the dock is the
/// detailed in-window surface for it.
public enum WorkbenchNoticeProjection {
    public static func lane(_ inputs: WorkbenchNoticeInputs) -> [WorkbenchNotice] {
        var notices: [WorkbenchNotice] = []
        let pane = inputs.activePane

        // 1. A person is being asked for permission.
        let attention = inputs.attentionActivities
        for activity in attention where activity.attention == .permissionRequired {
            notices.append(WorkbenchNotice(
                id: "notice:permission:\(activity.id)",
                kind: .permission,
                tone: .attention,
                title: "\(activity.targetName) needs permission",
                detail: "\(activity.kindLabel) from \(activity.sourceName): \(activity.subject)",
                actionLabel: "Focus \(activity.targetName)",
                action: .focusHandoffTarget(activity.id)
            ))
        }

        // 2. An orchestration run is waiting on the person's decision.
        if let workflow = inputs.workflow, workflow.awaitsHumanDecision {
            notices.append(WorkbenchNotice(
                id: "notice:checkpoint",
                kind: .humanCheckpoint,
                tone: .attention,
                title: "Orchestration needs your decision",
                detail: "\(workflow.name) · \(workflow.phaseLabel) · \(workflow.modeLabel)",
                actionLabel: "Open",
                action: .openWorkflow
            ))
        }

        // 3. Failures: a non-zero exit of the active pane, then a failed or
        // interrupted primary handoff.
        if let pane, case let .exited(status) = inputs.activePaneState, let status, status != 0 {
            notices.append(WorkbenchNotice(
                id: "notice:exit:\(pane.id)",
                kind: .failure,
                tone: .failure,
                title: "\(pane.name) exited with status \(status)",
                detail: "Final terminal output is preserved. Restarting begins a new \(pane.kindLabel) process in the same pane and folder.",
                actionLabel: "Restart…",
                action: .restartPane(pane.id)
            ))
        }
        if let primary = inputs.primaryActivity, primary.state == .failed || primary.state == .interrupted {
            let verb = primary.state == .failed ? "failed" : "was interrupted"
            notices.append(WorkbenchNotice(
                id: "notice:failed:\(primary.id)",
                kind: .failure,
                tone: .failure,
                title: "\(primary.kindLabel) \(verb) · \(primary.sourceName) → \(primary.targetName)",
                detail: primary.subject,
                actionLabel: primary.canRetrySafely ? "Retry Delivery…" : "Focus \(primary.targetName)",
                action: primary.canRetrySafely ? .retryDelivery(primary.id) : .focusHandoffTarget(primary.id)
            ))
        }

        // 4. Protocol and relay state of the active pane.
        if let pane {
            switch inputs.activePaneState {
            case let .protocolStale(reportedVersion):
                notices.append(WorkbenchNotice(
                    id: "notice:protocol:\(pane.id)",
                    kind: .protocolStale,
                    tone: .attention,
                    title: "\(pane.name) needs a restart for protocol v\(inputs.protocolVersion)",
                    detail: "This pane reports \(reportedVersion.map { "protocol v\($0)" } ?? "no protocol version"). Its terminal remains usable, but cross-vendor actions are disabled until restart.",
                    actionLabel: "Restart…",
                    action: .restartPane(pane.id)
                ))
            case .relayUnavailable:
                notices.append(WorkbenchNotice(
                    id: "notice:relay:\(pane.id)",
                    kind: .relayUnavailable,
                    tone: .attention,
                    title: "\(pane.name) is not connected to the relay",
                    detail: "Its terminal remains usable, but Ask and Return are disabled until the pane restarts with relay credentials.",
                    actionLabel: "Restart…",
                    action: .restartPane(pane.id)
                ))
            default:
                break
            }
        }

        // 5. Shared worktree writers: one notice per bounded collision, in
        // input order, each opening its own worktree. Nothing is summarised
        // into a count; the lane's disclosure carries whatever is not on top.
        var seenWorktreePaths: Set<String> = []
        for collision in inputs.worktreeCollisions where seenWorktreePaths.insert(collision.path).inserted {
            let folder = collision.path.split(separator: "/").last.map(String.init) ?? collision.path
            notices.append(WorkbenchNotice(
                id: "notice:worktree:\(collision.path)",
                kind: .worktreeCollision,
                tone: .attention,
                title: "Shared worktree writers · \(folder)",
                detail: "\(collision.writerNames.joined(separator: ", ")) may write at \(collision.path). Permission evidence only; no file activity is inferred.",
                actionLabel: "Worktrees…",
                action: .openWorktrees(collision.path)
            ))
        }

        // 6. Coordination and terminal availability.
        switch inputs.connectionState {
        case .connected:
            break
        case .coreDisconnected:
            notices.append(WorkbenchNotice(
                id: "notice:core",
                kind: .connection,
                tone: .attention,
                title: "Relay disconnected",
                detail: "Terminal panes remain available. Ask, Return and agent handoffs pause until the local core reconnects.",
                actionLabel: "Reconnect",
                action: .reconnect
            ))
        case .terminalDisconnected:
            notices.append(WorkbenchNotice(
                id: "notice:terminal",
                kind: .connection,
                tone: .failure,
                title: "Terminal unavailable",
                detail: "Embedded Ghostty panes are not attached to this window.",
                actionLabel: nil,
                action: nil
            ))
        }

        // 7. Other authoritative attention on active handoffs.
        for activity in attention where activity.attention == .targetNotReady || activity.attention == .targetUnavailable {
            let state = activity.attention == .targetNotReady ? "is not ready" : "is unavailable"
            notices.append(WorkbenchNotice(
                id: "notice:target:\(activity.id)",
                kind: .targetAttention,
                tone: .attention,
                title: "\(activity.targetName) \(state)",
                detail: "\(activity.kindLabel) from \(activity.sourceName): \(activity.subject)",
                actionLabel: "Focus \(activity.targetName)",
                action: .focusHandoffTarget(activity.id)
            ))
        }

        // 8. A stopped or cleanly exited active pane.
        if let pane {
            switch inputs.activePaneState {
            case .stopped:
                notices.append(WorkbenchNotice(
                    id: "notice:stopped:\(pane.id)",
                    kind: .paneStopped,
                    tone: .neutral,
                    title: "\(pane.name) is stopped",
                    detail: "This restored seat has not started a subscription CLI session.",
                    actionLabel: "Start \(pane.kindLabel)",
                    action: .startPane(pane.id)
                ))
            case let .exited(status) where status == nil || status == 0:
                notices.append(WorkbenchNotice(
                    id: "notice:exited:\(pane.id)",
                    kind: .paneStopped,
                    tone: .neutral,
                    title: "\(pane.name) exited",
                    detail: "Final terminal output is preserved. Restarting begins a new \(pane.kindLabel) process in the same pane and folder.",
                    actionLabel: "Restart…",
                    action: .restartPane(pane.id)
                ))
            default:
                break
            }
        }

        // 9. In-flight activity, only while the dock is hidden and only when the
        // same handoff is not already listed as an attention item.
        if !inputs.dockVisible,
           let primary = inputs.primaryActivity,
           primary.isInFlight,
           !attention.contains(where: { $0.id == primary.id }) {
            notices.append(WorkbenchNotice(
                id: "notice:activity:\(primary.id)",
                kind: .activity,
                tone: .inFlight,
                title: "\(primary.sourceName) → \(primary.targetName)",
                detail: "\(primary.kindLabel) · \(primary.subject)",
                actionLabel: "Focus \(primary.targetName)",
                action: .focusHandoffTarget(primary.id)
            ))
        }

        // 10. Informational: orchestration in progress, submitted recipe, canvas.
        if let workflow = inputs.workflow, !workflow.awaitsHumanDecision {
            notices.append(WorkbenchNotice(
                id: "notice:workflow",
                kind: .workflow,
                tone: .neutral,
                title: "Orchestration · \(workflow.phaseLabel)",
                detail: "\(workflow.name) · \(workflow.modeLabel)",
                actionLabel: "Open",
                action: .openWorkflow
            ))
        }
        if let recipe = inputs.recipe {
            notices.append(WorkbenchNotice(
                id: "notice:recipe",
                kind: .recipe,
                tone: .neutral,
                title: "\(recipe.name) → \(recipe.leadName) submitted",
                detail: "The workspace lead received this recipe; its progress is in the dock and Status Center.",
                actionLabel: "Stop…",
                action: .stopRecipe
            ))
        }
        if inputs.focusCanvasActive, let pane {
            notices.append(WorkbenchNotice(
                id: "notice:canvas:\(pane.id)",
                kind: .focusCanvas,
                tone: .neutral,
                title: "Focus Canvas · \(pane.name)",
                detail: "Peers remain live and selectable.",
                actionLabel: "Return to Grid",
                action: .exitFocusCanvas
            ))
        }
        return notices
    }
}

public enum StatusCenterSegment: String, CaseIterable, Identifiable, Equatable, Sendable {
    case live
    case results
    case history
    case agents
    case health

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .live: "Live"
        case .results: "Results"
        case .history: "History"
        case .agents: "Agents"
        case .health: "Health"
        }
    }
}

public enum StatusCenterCountKind: Equatable, Sendable {
    case runningAgents
    case stoppedAgents
    case outstandingQuestions
    case trackedDelegations
    case unreadResults
    case failures
}

public enum StatusCenterSegmentProjection {
    /// Where a handoff is found: active work under Live, unread results under
    /// Results, everything else under History.
    public static func segment(isActive: Bool, hasUnreadResult: Bool) -> StatusCenterSegment {
        if isActive { return .live }
        if hasUnreadResult { return .results }
        return .history
    }

    public static func segment(for handoff: RelayHandoff, activeHandoffIDs: Set<String>) -> StatusCenterSegment {
        segment(isActive: activeHandoffIDs.contains(handoff.id), hasUnreadResult: handoff.hasUnreadResult)
    }

    /// Which segment a count cell opens.
    public static func segment(for count: StatusCenterCountKind) -> StatusCenterSegment {
        switch count {
        case .runningAgents, .stoppedAgents: .agents
        case .outstandingQuestions, .trackedDelegations: .live
        case .unreadResults: .results
        case .failures: .history
        }
    }
}
