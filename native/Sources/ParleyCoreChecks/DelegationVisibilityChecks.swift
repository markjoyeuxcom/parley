import Foundation
import ParleyCore

private enum DelegationCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func delegationExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DelegationCheckFailure.failed(message) }
}

private func delegationRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw DelegationCheckFailure.failed(message) }
    return value
}

private func reference(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
}

/// Builds a handoff exactly as the durable journal would decode it, so the
/// projection under test sees the same owned timestamps the app does.
private func delegationFixture(
    id: String = "d1",
    kind: RelayHandoffKind = .delegate,
    state: RelayHandoffState,
    transitions: [(RelayHandoffState, TimeInterval)],
    progressNote: String? = nil,
    progressUpdatedAt: TimeInterval? = nil,
    targetPaneID: String = "%target",
    targetName: String = "Claude"
) throws -> RelayHandoff {
    var object: [String: Any] = [
        "id": id,
        "idempotencyKey": "key-\(id)",
        "kind": kind.rawValue,
        "sourcePaneID": "%source",
        "sourceName": "Codex",
        "sourceKind": "codex",
        "sourceWorkspaceID": "workspace-a",
        "sourceWorkspaceName": "Project",
        "targetPaneID": targetPaneID,
        "targetName": targetName,
        "targetKind": "claude",
        "targetWorkspaceID": "workspace-a",
        "targetWorkspaceName": "Project",
        "text": "Implement the reviewed fix and verify it.",
        "submitted": true,
        "state": state.rawValue,
        "updatedAt": transitions.last?.1 ?? 0,
        "transitions": transitions.map { entry -> [String: Any] in
            ["state": entry.0.rawValue, "occurredAt": entry.1, "detail": NSNull()]
        },
    ]
    if let progressNote { object["progressNote"] = progressNote }
    if let progressUpdatedAt { object["progressUpdatedAt"] = progressUpdatedAt }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(RelayHandoff.self, from: data)
}

private func targetPane(
    id: String = "%target",
    kind: PaneKind = .claude,
    signal: VendorHookSignal? = .turnStarted,
    state: VendorRuntimeState? = .working,
    signaledAt: TimeInterval? = 1_302,
    isDead: Bool = false
) -> WorkbenchPane {
    WorkbenchPane(
        id: id,
        kind: kind,
        customName: "Claude",
        terminalTitle: "",
        cwd: "/tmp/project",
        currentCommand: "claude",
        isActive: false,
        workspaceID: "workspace-a",
        workspaceName: "Project",
        vendorRuntimeState: state,
        vendorRuntimeSignal: signal,
        vendorRuntimeSignaledAt: signaledAt.map(reference),
        isDead: isDead,
        isStarted: true
    )
}

private let activeTransitions: [(RelayHandoffState, TimeInterval)] = [
    (.created, 1_000), (.delivered, 1_002), (.waiting, 1_002),
]

func checkDelegationVisibilityIsComputedFromOwnedTimestampsOnly() throws {
    let handoff = try delegationFixture(
        state: .waiting,
        transitions: activeTransitions,
        progressNote: "Parser checks are running.",
        progressUpdatedAt: 1_122
    )
    let target = targetPane()
    var rendered: [String] = []

    // 1. Three owned facts, each with its age, and no quiet state inside the window.
    let facts = try delegationRequire(
        DelegationVisibilityProjection.facts(for: handoff, target: target, now: reference(1_402)),
        "an active delegation with owned timestamps yielded no visibility facts"
    )
    try delegationExpect(facts.handoffID == handoff.id, "facts lost their handoff identity")
    try delegationExpect(facts.phase == .active, "an active delegation was not reported as active")
    try delegationExpect(
        facts.deliveredAt == reference(1_002),
        "elapsed time did not start at the recorded delivered transition"
    )
    try delegationExpect(facts.elapsed == 400, "elapsed since delivery was not computed from the delivered timestamp")
    try delegationExpect(facts.elapsedLabel == "Delivered 6m ago", "elapsed label was not a factual age: \(facts.elapsedLabel)")
    let progress = try delegationRequire(facts.progress, "the agent-declared progress note was dropped")
    try delegationExpect(progress.note == "Parser checks are running." && progress.age == 280, "progress note age was not derived from progressUpdatedAt")
    try delegationExpect(facts.progressLabel == "Progress note 4m ago", "progress label lost its age: \(facts.progressLabel)")
    try delegationExpect(
        facts.summary.contains("Parser checks are running.") && facts.summary.lowercased().contains("agent-declared"),
        "the compact summary omitted the agent-declared note text: \(facts.summary)"
    )
    try delegationExpect(
        facts.progressSummary == "Agent-declared 4m ago: Parser checks are running.",
        "the compact progress summary lost its note, age or provenance: \(facts.progressSummary)"
    )
    try delegationExpect(
        facts.summary.hasSuffix(facts.progressSummary),
        "the compact summary did not place the note last, where truncation is least harmful: \(facts.summary)"
    )
    let signal = try delegationRequire(facts.targetSignal, "the target's authenticated hook signal was dropped")
    try delegationExpect(
        signal.signal == .turnStarted && signal.vendor == .claude && signal.age == 100,
        "hook signal age was not derived from the target's authenticated hook timestamp"
    )
    try delegationExpect(
        facts.targetSignalLabel == "Claude hook · turn started · 1m ago",
        "target signal label lost provenance or age: \(facts.targetSignalLabel)"
    )
    try delegationExpect(facts.quiet == nil, "a delegation updated 100 seconds ago was called quiet")
    try delegationExpect(
        facts == DelegationVisibilityProjection.facts(for: handoff, target: target, now: reference(1_402)),
        "the projection is not deterministic for identical inputs"
    )
    rendered += [facts.elapsedLabel, facts.progressLabel, facts.targetSignalLabel, facts.summary, facts.accessibilityDescription]

    // 2. The ten-minute state counts from the latest owned timestamp, inclusive.
    let justBefore = try delegationRequire(
        DelegationVisibilityProjection.facts(for: handoff, target: target, now: reference(1_901)),
        "facts disappeared one second before the quiet window"
    )
    try delegationExpect(justBefore.quiet == nil, "the quiet state appeared before ten minutes had passed")
    let quiet = try delegationRequire(
        DelegationVisibilityProjection.facts(for: handoff, target: target, now: reference(1_902))?.quiet,
        "ten minutes without a progress note or hook signal produced no quiet state"
    )
    try delegationExpect(
        quiet.since == reference(1_302) && quiet.duration == 600,
        "the quiet state did not measure from the latest owned timestamp"
    )
    let later = try delegationRequire(
        DelegationVisibilityProjection.facts(for: handoff, target: target, now: reference(2_142)),
        "facts disappeared after the quiet window"
    )
    try delegationExpect(later.quiet?.duration == 840, "the quiet duration stopped growing")
    try delegationExpect(
        later.summary.hasPrefix(DelegationVisibility.quietTitle),
        "the quiet state did not lead the compact summary: \(later.summary)"
    )
    try delegationExpect(
        DelegationVisibility.quietTitle == "No explicit update for 10 minutes",
        "the quiet state is not named as the roadmap's factual state"
    )
    let quietDetail = try delegationRequire(later.quietDetail, "the quiet state has no informational detail")
    try delegationExpect(
        quietDetail.contains("14m") && quietDetail.lowercased().contains("not evidence"),
        "the quiet detail did not state the measured duration and its limits: \(quietDetail)"
    )
    rendered += [DelegationVisibility.quietTitle, quietDetail, later.summary, later.accessibilityDescription]

    // 3. A fresh progress note clears the quiet state; a hook signal alone also does.
    let freshNote = try delegationFixture(
        state: .waiting,
        transitions: activeTransitions,
        progressNote: "Checks pass; writing the report.",
        progressUpdatedAt: 1_850
    )
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: freshNote, target: target, now: reference(1_902))?.quiet == nil,
        "a progress note inside the window did not clear the quiet state"
    )
    let noNote = try delegationFixture(state: .waiting, transitions: activeTransitions)
    let recentSignal = targetPane(signaledAt: 1_890)
    let signalOnly = try delegationRequire(
        DelegationVisibilityProjection.facts(for: noNote, target: recentSignal, now: reference(1_902)),
        "a delegation without a progress note lost its facts"
    )
    try delegationExpect(signalOnly.progress == nil, "a missing progress note was fabricated")
    try delegationExpect(signalOnly.progressLabel == "No progress note reported", "missing progress was not stated plainly: \(signalOnly.progressLabel)")
    try delegationExpect(
        signalOnly.progressSummary == "No agent-declared progress note",
        "a missing note was not stated plainly in the compact summary: \(signalOnly.progressSummary)"
    )
    try delegationExpect(signalOnly.quiet == nil, "a hook signal inside the window did not clear the quiet state")

    // 4. A signal that predates delivery is still shown with its true age but
    //    never counts as an update inside the window.
    let staleSignal = targetPane(signaledAt: 900)
    let preDelivery = try delegationRequire(
        DelegationVisibilityProjection.facts(for: noNote, target: staleSignal, now: reference(1_700)),
        "a delegation with only a pre-delivery signal lost its facts"
    )
    try delegationExpect(preDelivery.targetSignal?.age == 800, "a pre-delivery signal lost its true age")
    try delegationExpect(
        preDelivery.quiet?.since == reference(1_002) && preDelivery.quiet?.duration == 698,
        "delivery itself did not anchor the quiet window when nothing newer exists"
    )

    // 5. Only authenticated, supported, live hook signals from the exact target count.
    for (label, pane) in [
        ("an unsupported vendor", targetPane(kind: .agy, signal: .turnEnded, state: .ready)),
        ("a dead pane", targetPane(isDead: true)),
        ("a pane without a hook signal", targetPane(signal: nil, state: nil, signaledAt: nil)),
        ("a different pane", targetPane(id: "%other")),
    ] {
        let projected = try delegationRequire(
            DelegationVisibilityProjection.facts(for: noNote, target: pane, now: reference(1_402)),
            "\(label) removed the delegation's owned facts entirely"
        )
        try delegationExpect(projected.targetSignal == nil, "\(label) fabricated an authenticated target signal")
        try delegationExpect(
            projected.targetSignalLabel == "No authenticated hook signal from Claude",
            "\(label) did not state the missing signal plainly: \(projected.targetSignalLabel)"
        )
        rendered.append(projected.targetSignalLabel)
    }
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: noNote, target: nil, now: reference(1_402))?.targetSignal == nil,
        "a missing target pane fabricated a hook signal"
    )

    // 6. No owned timestamps, or not a delegation: no state at all.
    let noTimestamps = try delegationFixture(state: .created, transitions: [])
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: noTimestamps, target: target, now: reference(9_000)) == nil,
        "a delegation without any recorded transition produced visibility state"
    )
    let ask = try delegationFixture(kind: .ask, state: .waiting, transitions: activeTransitions)
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: ask, target: target, now: reference(1_402)) == nil,
        "an Ask was projected as delegation visibility"
    )

    // 7. A returned delegation reports its factual duration and never a quiet state.
    let completed = try delegationFixture(
        state: .completed,
        transitions: activeTransitions + [(.completed, 2_262)],
        progressNote: "Implemented; tests pass.",
        progressUpdatedAt: 2_200
    )
    let returned = try delegationRequire(
        DelegationVisibilityProjection.facts(for: completed, target: target, now: reference(99_999)),
        "a returned delegation lost its facts"
    )
    try delegationExpect(returned.phase == .returned(.completed), "a completed delegation was not reported as returned")
    try delegationExpect(returned.elapsed == 1_260 && returned.endedAt == reference(2_262), "the returned duration was not measured between delivery and completion")
    try delegationExpect(returned.elapsedLabel == "Returned after 21m", "returned duration label was wrong: \(returned.elapsedLabel)")
    try delegationExpect(returned.quiet == nil, "a returned delegation was called quiet")
    try delegationExpect(returned.progress?.age == 99_999 - 2_200, "a returned delegation lost its last progress note age")
    rendered += [returned.elapsedLabel, returned.summary, returned.accessibilityDescription]
    let failed = try delegationFixture(state: .failed, transitions: activeTransitions + [(.failed, 2_262)])
    let ended = try delegationRequire(
        DelegationVisibilityProjection.facts(for: failed, target: target, now: reference(3_000)),
        "a failed delegation lost its facts"
    )
    try delegationExpect(ended.elapsedLabel == "Ended after 21m" && ended.quiet == nil, "a failed delegation was mislabelled: \(ended.elapsedLabel)")
    rendered.append(ended.elapsedLabel)

    // 8. Nothing rendered ever estimates or infers.
    let vocabulary = rendered.joined(separator: "\n").lowercased()
    for banned in ["thinking", "%", "remaining", "estimat", "stuck", "likely", "ready", "idle", "hung"] {
        try delegationExpect(!vocabulary.contains(banned), "delegation visibility rendered an inference or estimate: \(banned)")
    }
    try delegationExpect(
        later.accessibilityDescription.contains("agent-declared") && later.accessibilityDescription.contains("Claude hook"),
        "the accessibility description hid provenance: \(later.accessibilityDescription)"
    )
}

func checkDelegationVisibilityRequiresAnExactDeliveredTransition() throws {
    let target = targetPane()
    let createdOnly = try delegationFixture(state: .created, transitions: [(.created, 1_000)])
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: createdOnly, target: target, now: reference(1_402)) == nil,
        "a created-only delegation was described as delivered"
    )
    let notedButUndelivered = try delegationFixture(
        state: .created,
        transitions: [(.created, 1_000)],
        progressNote: "Starting.",
        progressUpdatedAt: 1_100
    )
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: notedButUndelivered, target: target, now: reference(1_402)) == nil,
        "a progress note without a delivered transition produced delivery facts"
    )
    let failedBeforeDelivery = try delegationFixture(
        state: .failed,
        transitions: [(.created, 1_000), (.failed, 1_001)]
    )
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: failedBeforeDelivery, target: target, now: reference(3_000)) == nil,
        "a delegation that failed before delivery was given a delivery duration"
    )
    let cancelledBeforeDelivery = try delegationFixture(
        state: .cancelled,
        transitions: [(.created, 1_000), (.cancelled, 1_001)]
    )
    try delegationExpect(
        DelegationVisibilityProjection.facts(for: cancelledBeforeDelivery, target: target, now: reference(3_000)) == nil,
        "a delegation cancelled before delivery was given a delivery duration"
    )

    // The delivered transition is the only anchor, wherever it sits.
    let delivered = try delegationFixture(
        state: .waiting,
        transitions: [(.created, 1_000), (.delivered, 1_050), (.waiting, 1_050)]
    )
    let facts = try delegationRequire(
        DelegationVisibilityProjection.facts(for: delivered, target: target, now: reference(1_402)),
        "a delivered delegation lost its facts"
    )
    try delegationExpect(
        facts.deliveredAt == reference(1_050) && facts.elapsed == 352,
        "elapsed was not anchored on the exact delivered transition"
    )
}

func checkDelegateRecipeGuidanceRequestsMilestonesAndFileResults() throws {
    try delegationExpect(HandoffRecipe.defaults.count == 5, "the default recipe set changed size")
    let recipe = try delegationRequire(
        HandoffRecipe.defaults.first(where: { $0.kind == .delegate }),
        "there is no default Delegate recipe"
    )
    try delegationExpect(
        recipe.instructions.contains("parley progress current"),
        "the default Delegate guidance does not ask for a progress note at each milestone"
    )
    try delegationExpect(
        recipe.instructions.lowercased().contains("milestone"),
        "the default Delegate guidance does not tie progress notes to milestones"
    )
    try delegationExpect(
        recipe.instructions.contains("parley done current --file <path>"),
        "the default Delegate guidance does not show the complete file-result syntax with its <path> placeholder"
    )
    try delegationExpect(recipe.instructions.contains("{{targets}}"), "the default Delegate guidance lost its explicit targets placeholder")
    let rendered = try recipe.render(targets: ["%codex"])
    try delegationExpect(
        rendered.contains("%codex") && rendered.count <= RelayText.maximumCharacters,
        "the default Delegate guidance no longer renders within relay limits"
    )

    // The guidance is a default, not a rule: the local store still accepts an
    // edited instruction for the same recipe.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-delegate-recipe-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HandoffRecipeStore(file: directory.appendingPathComponent("handoff-recipes.json"))
    let fresh = try store.recipes()
    try delegationExpect(
        fresh.first(where: { $0.kind == .delegate })?.instructions == recipe.instructions,
        "a fresh store did not serve the updated default Delegate guidance"
    )
    let edited = HandoffRecipe(
        id: recipe.id,
        name: recipe.name,
        kind: recipe.kind,
        instructions: "Delegate the audit to {{targets}} and wait for the result."
    )
    try store.save(edited)
    let saved = try store.recipes()
    try delegationExpect(
        saved.first(where: { $0.id == recipe.id })?.instructions == edited.instructions,
        "the Delegate guidance stopped being editable"
    )
}
