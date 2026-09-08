import Foundation
import ParleyCore

private enum DraftMenuCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func draftExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DraftMenuCheckFailure.failed(message) }
}

private let draftNow = Date(timeIntervalSince1970: 1_800_000_000)

private func draftReview(
    _ id: String,
    state: AgentContextReviewState,
    name: String,
    file: String = "report.md",
    target: String? = nil,
    ageSeconds: TimeInterval
) -> AgentContextReview {
    let stamp = draftNow.addingTimeInterval(-ageSeconds)
    return AgentContextReview(
        id: id,
        sourcePaneID: "%1",
        sourcePaneName: "Claude",
        sourcePaneKind: .claude,
        sourceFolder: "/private/project",
        pack: ContextPack(
            name: name,
            parts: [ContextPackPart(
                source: ContextPackSource(kind: .agentFileDraft, label: file, detail: "agent-provided"),
                capturedText: "claimed"
            )],
            origin: .agentProposed
        ),
        state: state,
        requestedTargetName: target,
        createdAt: stamp,
        updatedAt: stamp
    )
}

/// The Context menu must tell drafts apart and put a blocked pane's approval
/// first, cap the saved list and never hide the rest.
func checkAgentDraftMenuSeparatesWaitingApprovalsFromSavedDrafts() throws {
    var reviews: [AgentContextReview] = []
    for index in 1...10 {
        reviews.append(draftReview("d\(index)", state: .draft, name: "Delegation result from Claude", file: "report-\(index).md", ageSeconds: TimeInterval(index * 60)))
    }
    reviews.append(draftReview("a-old", state: .awaitingReview, name: "Idle readings", target: "Codex", ageSeconds: 30 * 60))
    reviews.append(draftReview("a-new", state: .awaitingReview, name: "Claude context", file: "notes.md", ageSeconds: 5))
    reviews.append(draftReview("approved", state: .approved, name: "Sent already", ageSeconds: 1))
    reviews.append(draftReview("rejected", state: .rejected, name: "Declined already", ageSeconds: 1))
    reviews.shuffle()

    let lane = AgentDraftMenuProjection.lane(reviews: reviews, now: draftNow)
    try draftExpect(lane.waiting.map(\.id) == ["a-new", "a-old"], "waiting approvals were not listed newest first: \(lane.waiting.map(\.id))")
    try draftExpect(lane.waiting.allSatisfy(\.isWaiting), "a waiting approval lost its waiting flag")
    try draftExpect(lane.saved.map(\.id) == (1...8).map { "d\($0)" }, "saved drafts were not the newest eight: \(lane.saved.map(\.id))")
    try draftExpect(lane.saved.allSatisfy { !$0.isWaiting }, "a saved draft was flagged as waiting")
    try draftExpect(lane.olderCount == 2, "older drafts beyond the cap were miscounted: \(lane.olderCount)")
    try draftExpect(lane.editableCount == 10, "the bulk-discard count included non-editable reviews: \(lane.editableCount)")
    try draftExpect(AgentDraftMenuProjection.maximumSaved == 8, "the menu cap moved away from eight")

    try draftExpect(lane.waiting[1].title == "Claude → Codex · Idle readings · 30 min", "a named pack lost its name, target or age: \(lane.waiting[1].title)")
    try draftExpect(lane.waiting[0].title == "Claude · notes.md · now", "a generic pack name hid the staged file: \(lane.waiting[0].title)")
    try draftExpect(lane.saved[0].title == "Claude · report-1.md · 1 min", "a returned delegation file was not named: \(lane.saved[0].title)")
    try draftExpect(Set(lane.saved.map(\.title)).count == lane.saved.count, "two saved drafts shared one label")

    try draftExpect(AgentDraftMenuProjection.age(from: draftNow.addingTimeInterval(-59), to: draftNow) == "now", "a fresh draft was not 'now'")
    try draftExpect(AgentDraftMenuProjection.age(from: draftNow.addingTimeInterval(-3_599), to: draftNow) == "59 min", "minutes rounded wrongly")
    try draftExpect(AgentDraftMenuProjection.age(from: draftNow.addingTimeInterval(-3_600), to: draftNow) == "1 h", "an hour was not shown as hours")
    try draftExpect(AgentDraftMenuProjection.age(from: draftNow.addingTimeInterval(-86_400 * 3), to: draftNow) == "3 d", "days were not shown as days")
    try draftExpect(AgentDraftMenuProjection.age(from: draftNow.addingTimeInterval(120), to: draftNow) == "now", "a future timestamp produced a negative age")

    let empty = AgentDraftMenuProjection.lane(reviews: [], now: draftNow)
    try draftExpect(empty.waiting.isEmpty && empty.saved.isEmpty && empty.olderCount == 0 && empty.editableCount == 0, "an empty review list produced menu rows")
}

/// A pack says who assembled it. Agent-staged packs must not claim the
/// person's selection before approval, and older records still decode.
func checkContextPackOriginIsStatedHonestlyInTheHeader() throws {
    try draftExpect(
        ContextPackOrigin.agentProposed.headerStatement.hasPrefix("Agent-proposed context; not approved or sent."),
        "the agent-proposed header does not open with its status"
    )
    try draftExpect(
        !ContextPackOrigin.agentProposed.headerStatement.contains("selected by the person")
            && !ContextPackOrigin.agentApproved.headerStatement.contains("selected by the person"),
        "an agent pack claimed the person selected it"
    )
    try draftExpect(
        ContextPackOrigin.agentApproved.headerStatement.contains("approved delivery")
            && ContextPackOrigin.agentApproved.headerStatement.contains("not independently verified"),
        "the approved header dropped the person's approval or the unverified provenance"
    )

    let part = ContextPackPart(
        source: ContextPackSource(kind: .agentFileDraft, label: "report.md", detail: "agent-provided"),
        capturedText: "claimed"
    )
    let builder = ContextPackBuilder(environment: ["PATH": "/usr/bin:/bin"])
    let proposed = try builder.render(ContextPack(name: "Readings", parts: [part], origin: .agentProposed))
    try draftExpect(proposed.contains("Agent-proposed context; not approved or sent."), "the rendered draft did not state it was unapproved")
    try draftExpect(!proposed.contains("explicitly selected by the person"), "the rendered draft claimed the person's selection")
    let approved = try builder.render(ContextPack(name: "Readings", parts: [part], origin: .agentApproved))
    try draftExpect(approved.contains("The person reviewed and approved delivery"), "the rendered approved pack did not state the approval")
    let person = try builder.render(ContextPack(name: "Readings", parts: [part]))
    try draftExpect(person.contains("explicitly selected by the person"), "a person-selected pack lost its header")

    let legacy = Data(#"{"id":"legacy","name":"Old pack","note":"","parts":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(ContextPack.self, from: legacy)
    try draftExpect(decoded.origin == .personSelected, "a record without an origin did not decode as person-selected")
    let encoded = try JSONEncoder().encode(ContextPack(id: "keep", name: "Kept", parts: [part], origin: .agentApproved))
    let roundTrip = try JSONDecoder().decode(ContextPack.self, from: encoded)
    try draftExpect(roundTrip.origin == .agentApproved, "an origin did not survive a round trip")
    try draftExpect(roundTrip == ContextPack(id: "keep", name: "Kept", parts: [part], origin: .agentApproved), "a round-tripped pack lost a field")
}
