import Foundation
import ParleyCore

private enum ChromeCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func chromeExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ChromeCheckFailure.failed(message) }
}

private func activity(
    _ id: String,
    state: RelayHandoffState,
    attention: RelayAttention? = nil,
    canRetry: Bool = false
) -> WorkbenchNoticeActivity {
    WorkbenchNoticeActivity(
        id: id,
        sourceName: "Codex",
        targetName: "Claude",
        kindLabel: "ask",
        subject: "Review the diff",
        state: state,
        attention: attention,
        canRetrySafely: canRetry
    )
}

private func inputs(
    paneState: WorkbenchPaneState = .running,
    connection: WorkbenchConnectionState = .connected,
    collisions: [WorkbenchWorktreeNotice] = [],
    primary: WorkbenchNoticeActivity? = nil,
    attention: [WorkbenchNoticeActivity] = [],
    recipe: WorkbenchRecipeNotice? = nil,
    workflow: WorkbenchWorkflowNotice? = nil,
    focusCanvas: Bool = false,
    dockVisible: Bool = true
) -> WorkbenchNoticeInputs {
    WorkbenchNoticeInputs(
        activePane: WorkbenchNoticePane(id: "%1", name: "Claude", kindLabel: "Claude"),
        activePaneState: paneState,
        connectionState: connection,
        worktreeCollisions: collisions,
        primaryActivity: primary,
        attentionActivities: attention,
        recipe: recipe,
        workflow: workflow,
        focusCanvasActive: focusCanvas,
        dockVisible: dockVisible,
        protocolVersion: AgentProtocol.version
    )
}

func checkChromeChipCaseIsSentenceCaseForStateLabels() throws {
    try chromeExpect(ChromeLabel.chipCase("UNREAD RESULT") == "Unread result", "an all-caps chip was not converted to sentence case")
    try chromeExpect(ChromeLabel.chipCase("PERMISSION REPORTED") == "Permission reported", "a two-word state chip lost its sentence case")
    try chromeExpect(ChromeLabel.chipCase("RESTART FOR PROTOCOL") == "Restart for protocol", "a three-word state chip was not converted")
    try chromeExpect(ChromeLabel.chipCase("EXITED 1") == "Exited 1", "a chip with a status number lost the number or its case")
    try chromeExpect(ChromeLabel.chipCase("COMPLETED") == "Completed", "a single-word chip was not converted")
    try chromeExpect(ChromeLabel.chipCase("@reviewer") == "@reviewer", "a routing role was rewritten")
    try chromeExpect(ChromeLabel.chipCase("v14") == "v14", "a version stamp was rewritten")
    try chromeExpect(ChromeLabel.chipCase("Needs Changes") == "Needs Changes", "mixed-case text was rewritten")
    try chromeExpect(ChromeLabel.chipCase("Claude → Codex") == "Claude → Codex", "a route label was rewritten")
    try chromeExpect(ChromeLabel.chipCase("") == "", "empty text did not stay empty")
    try chromeExpect(ChromeLabel.chipCase("AUTO") == "Auto", "an uppercase mode label was not converted")
}

func checkWorkbenchNoticeLaneIsPrioritisedAndNeverHidesFacts() throws {
    let permission = activity("h-permission", state: .delivered, attention: .permissionRequired)
    let failed = activity("h-failed", state: .failed, canRetry: true)
    let waiting = activity("h-waiting", state: .waiting)
    let collision = WorkbenchWorktreeNotice(path: "/repo", writerNames: ["Claude", "Codex"])
    let checkpoint = WorkbenchWorkflowNotice(name: "Plan", phaseLabel: "Awaiting completion approval", modeLabel: "Auto", awaitsHumanDecision: true)
    let running = WorkbenchWorkflowNotice(name: "Plan", phaseLabel: "Implementing", modeLabel: "Auto", awaitsHumanDecision: false)
    let recipe = WorkbenchRecipeNotice(name: "Review", leadName: "Codex")

    let everything = WorkbenchNoticeProjection.lane(inputs(
        paneState: .protocolStale(reportedVersion: "13"),
        connection: .coreDisconnected,
        collisions: [collision],
        primary: waiting,
        attention: [permission],
        recipe: recipe,
        workflow: checkpoint,
        focusCanvas: true,
        dockVisible: false
    ))
    try chromeExpect(
        everything.map(\.kind) == [.permission, .humanCheckpoint, .protocolStale, .worktreeCollision, .connection, .activity, .recipe, .focusCanvas],
        "the notice lane order drifted: \(everything.map(\.kind))"
    )
    try chromeExpect(everything.first?.tone == .attention, "the top notice was not toned as attention")
    try chromeExpect(everything.filter { $0.kind == .workflow || $0.kind == .humanCheckpoint }.count == 1, "a checkpoint workflow was listed twice")
    try chromeExpect(everything.first?.action == .focusHandoffTarget("h-permission"), "the permission notice did not offer to focus the target")
    try chromeExpect(everything.contains { $0.kind == .worktreeCollision && $0.title.contains("Shared worktree") && $0.detail.contains("/repo") }, "the worktree collision lost its path")

    let again = WorkbenchNoticeProjection.lane(inputs(
        paneState: .protocolStale(reportedVersion: "13"),
        connection: .coreDisconnected,
        collisions: [collision],
        primary: waiting,
        attention: [permission],
        recipe: recipe,
        workflow: checkpoint,
        focusCanvas: true,
        dockVisible: false
    ))
    try chromeExpect(again == everything, "the notice lane is not deterministic for identical inputs")

    let dockShown = WorkbenchNoticeProjection.lane(inputs(primary: waiting, attention: [permission], dockVisible: true))
    try chromeExpect(dockShown.map(\.kind) == [.permission], "with the dock visible the lane kept in-flight activity or dropped the permission fact")

    let dockHidden = WorkbenchNoticeProjection.lane(inputs(primary: waiting, dockVisible: false))
    try chromeExpect(dockHidden.map(\.kind) == [.activity] && dockHidden.first?.tone == .inFlight, "with the dock hidden the lane did not carry the compact activity line")

    let exitedBadly = WorkbenchNoticeProjection.lane(inputs(paneState: .exited(status: 2), primary: failed))
    try chromeExpect(exitedBadly.map(\.kind) == [.failure, .failure], "a non-zero exit and a failed delivery were not both reported as failures: \(exitedBadly.map(\.kind))")
    try chromeExpect(exitedBadly.allSatisfy { $0.tone == .failure }, "failures were not toned red")
    try chromeExpect(exitedBadly.first?.action == .restartPane("%1"), "the exited pane did not offer a restart")
    try chromeExpect(exitedBadly.last?.action == .retryDelivery("h-failed"), "a safely retryable failure did not offer retry")

    let exitedCleanly = WorkbenchNoticeProjection.lane(inputs(paneState: .exited(status: 0)))
    try chromeExpect(exitedCleanly.map(\.kind) == [.paneStopped] && exitedCleanly.first?.tone == .neutral, "a clean exit was presented as a failure")

    let stopped = WorkbenchNoticeProjection.lane(inputs(paneState: .stopped))
    try chromeExpect(stopped.first?.action == .startPane("%1") && stopped.first?.actionLabel == "Start Claude", "a stopped pane did not offer to start its vendor")

    let relay = WorkbenchNoticeProjection.lane(inputs(paneState: .relayUnavailable))
    try chromeExpect(relay.map(\.kind) == [.relayUnavailable] && relay.first?.tone == .attention, "a relay-unavailable pane was not surfaced as attention")

    let notReady = WorkbenchNoticeProjection.lane(inputs(attention: [activity("h-nr", state: .delivered, attention: .targetNotReady)]))
    try chromeExpect(notReady.map(\.kind) == [.targetAttention], "a target-not-ready attention was dropped")

    let quiet = WorkbenchNoticeProjection.lane(inputs())
    try chromeExpect(quiet.isEmpty, "a healthy idle workbench produced notices: \(quiet.map(\.kind))")

    let runningWorkflow = WorkbenchNoticeProjection.lane(inputs(recipe: recipe, workflow: running))
    try chromeExpect(runningWorkflow.map(\.kind) == [.workflow, .recipe] && runningWorkflow.allSatisfy { $0.tone == .neutral }, "informational workflow and recipe notices were mis-toned or mis-ordered")

    let terminalDown = WorkbenchNoticeProjection.lane(inputs(connection: .terminalDisconnected))
    try chromeExpect(terminalDown.first?.kind == .connection && terminalDown.first?.tone == .failure && terminalDown.first?.action == nil, "a missing terminal was not reported as a failure without a fake action")
}

func checkWorkbenchNoticeLaneRepresentsEveryWorktreeCollision() throws {
    let first = WorkbenchWorktreeNotice(path: "/repo/app", writerNames: ["Claude", "Codex"])
    let second = WorkbenchWorktreeNotice(path: "/repo/site", writerNames: ["Agy", "Copilot"])
    let lane = WorkbenchNoticeProjection.lane(inputs(collisions: [first, second]))
    let collisions = lane.filter { $0.kind == .worktreeCollision }

    try chromeExpect(lane.map(\.kind) == [.worktreeCollision, .worktreeCollision], "two collision inputs did not produce two collision notices: \(lane.map(\.kind))")
    try chromeExpect(collisions.map(\.action) == [.openWorktrees("/repo/app"), .openWorktrees("/repo/site")], "each collision is not independently actionable in input order: \(collisions.map(\.action))")
    try chromeExpect(Set(collisions.map(\.id)).count == collisions.count, "collision notice IDs are not unique: \(collisions.map(\.id))")
    try chromeExpect(Set(lane.map(\.id)).count == lane.count, "lane IDs are not unique: \(lane.map(\.id))")
    try chromeExpect(collisions[0].detail.contains("/repo/app") && collisions[0].detail.contains("Claude, Codex"), "the first collision lost its path or writers")
    try chromeExpect(collisions[1].detail.contains("/repo/site") && collisions[1].detail.contains("Agy, Copilot"), "the second collision lost its path or writers")
    try chromeExpect(collisions.allSatisfy { !$0.title.lowercased().contains("more") }, "a collision title still claims additional facts instead of listing them: \(collisions.map(\.title))")
    try chromeExpect(collisions[0].title != collisions[1].title, "two collisions share one title, so the disclosure cannot tell them apart")
    try chromeExpect(collisions.allSatisfy { $0.tone == .attention }, "a collision was not toned as attention")

    let reversed = WorkbenchNoticeProjection.lane(inputs(collisions: [second, first]))
    try chromeExpect(reversed.map(\.action) == [.openWorktrees("/repo/site"), .openWorktrees("/repo/app")], "collision order does not follow the bounded input order deterministically")

    let repeated = WorkbenchNoticeProjection.lane(inputs(collisions: [first, first]))
    try chromeExpect(repeated.map(\.kind) == [.worktreeCollision] && Set(repeated.map(\.id)).count == 1, "a repeated path produced duplicate notice IDs: \(repeated.map(\.id))")
}

func checkStatusCenterSegmentsMapHandoffsAndCounts() throws {
    try chromeExpect(StatusCenterSegmentProjection.segment(isActive: true, hasUnreadResult: false) == .live, "active work did not map to Live")
    try chromeExpect(StatusCenterSegmentProjection.segment(isActive: false, hasUnreadResult: true) == .results, "an unread result did not map to Results")
    try chromeExpect(StatusCenterSegmentProjection.segment(isActive: true, hasUnreadResult: true) == .live, "active work with a result did not stay under Live")
    try chromeExpect(StatusCenterSegmentProjection.segment(isActive: false, hasUnreadResult: false) == .history, "a completed read record did not map to History")
    try chromeExpect(StatusCenterSegmentProjection.segment(for: .runningAgents) == .agents, "running count did not open Agents")
    try chromeExpect(StatusCenterSegmentProjection.segment(for: .stoppedAgents) == .agents, "stopped count did not open Agents")
    try chromeExpect(StatusCenterSegmentProjection.segment(for: .outstandingQuestions) == .live, "questions count did not open Live")
    try chromeExpect(StatusCenterSegmentProjection.segment(for: .trackedDelegations) == .live, "delegations count did not open Live")
    try chromeExpect(StatusCenterSegmentProjection.segment(for: .unreadResults) == .results, "results count did not open Results")
    try chromeExpect(StatusCenterSegmentProjection.segment(for: .failures) == .history, "failures count did not open History")
    try chromeExpect(StatusCenterSegment.allCases.map(\.label) == ["Live", "Results", "History", "Agents", "Health"], "segment labels drifted")
}
