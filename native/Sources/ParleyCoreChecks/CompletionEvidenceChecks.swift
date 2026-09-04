import Foundation
import ParleyCore

private enum EvidenceCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func evidenceExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw EvidenceCheckFailure.failed(message) }
}

private func evidenceRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw EvidenceCheckFailure.failed(message) }
    return value
}

private let implementedBody = "- Added the evidence parser.\n- Wired the inspector block."
private let testedBody = "- `npm test` — 58 pass, 0 fail\n- `swift build` — Build complete"
private let unableBody = "- Rendered UI: this pane has no display, so the block was not observed."

private func section(_ heading: String, _ body: String, level: Int = 2) -> String {
    "\(String(repeating: "#", count: level)) \(heading)\n\n\(body)\n"
}

private func evidenceHandoff(id: String = "evidence-1", kind: RelayHandoffKind = .delegate, reviewID: String? = "review-1") throws -> RelayHandoff {
    var object: [String: Any] = [
        "id": id, "idempotencyKey": "k-\(id)", "kind": kind.rawValue,
        "sourcePaneID": "%owner", "sourceName": "Owner", "sourceKind": "codex",
        "sourceWorkspaceID": "@ev", "targetPaneID": "%implementer", "targetName": "Implementer",
        "targetKind": "claude", "targetWorkspaceID": "@ev", "text": "Implement it.", "submitted": true,
        "state": "completed", "updatedAt": 6_000,
        "resultText": "Implementer returned report.md (200 UTF-8 bytes) for explicit review. Context review ID: \(reviewID ?? "none").",
        "transitions": [["state": "created", "occurredAt": 5_000], ["state": "delivered", "occurredAt": 5_001], ["state": "completed", "occurredAt": 6_000]],
    ]
    if let reviewID { object["resultContextReviewID"] = reviewID }
    return try JSONDecoder().decode(RelayHandoff.self, from: try JSONSerialization.data(withJSONObject: object))
}

private func evidenceReview(
    id: String = "review-1",
    parts: [ContextPackPart]
) -> AgentContextReview {
    AgentContextReview(
        id: id,
        sourcePaneID: "%implementer",
        sourcePaneName: "Implementer",
        sourcePaneKind: .claude,
        sourceFolder: "/private/project",
        pack: ContextPack(name: "Delegation result from Implementer", parts: parts),
        detail: "Returned from tracked delegation evidence-1; awaiting explicit human review."
    )
}

private func agentPart(_ text: String, referenceID: String? = "evidence-1", kind: ContextPackSourceKind = .agentFileDraft) -> ContextPackPart {
    ContextPackPart(
        source: ContextPackSource(
            kind: kind,
            label: "report.md",
            detail: "/private/project/report.md · provided by Implementer; not independently read by Parley",
            referenceID: referenceID
        ),
        capturedText: text
    )
}

func checkCompletionEvidenceParsesThreeHeadingsInAnyOrder() throws {
    let blocks: [(CompletionEvidenceSection, String)] = [
        (.implemented, section("Implemented", implementedBody)),
        (.tested, section("Tested", testedBody)),
        (.unableToTest, section("Unable to test", unableBody)),
    ]
    let bodies: [CompletionEvidenceSection: String] = [.implemented: implementedBody, .tested: testedBody, .unableToTest: unableBody]
    var orders: [[Int]] = []
    for a in 0..<3 { for b in 0..<3 where b != a { for c in 0..<3 where c != a && c != b { orders.append([a, b, c]) } } }
    try evidenceExpect(orders.count == 6, "expected six orders")
    for order in orders {
        let text = "# Completion report\n\nIntro paragraph.\n\n" + order.map { blocks[$0].1 }.joined(separator: "\n")
        let evidence = try evidenceRequire(CompletionEvidenceProjection.evidence(in: text), "order \(order) produced no evidence")
        try evidenceExpect(evidence.sections == order.map { blocks[$0].0 }, "order \(order) was not preserved: \(evidence.sections)")
        for (section, body) in bodies {
            try evidenceExpect(evidence.body(for: section) == body, "order \(order) altered the \(section.heading) body: \(evidence.body(for: section) ?? "nil")")
        }
        try evidenceExpect(evidence.missing.isEmpty && evidence.duplicateHeadingCount == 0, "order \(order) reported missing or duplicate headings")
        try evidenceExpect(evidence.ignoredHeadingCount == 1, "the unrelated title heading was not counted as ignored: \(evidence.ignoredHeadingCount)")
    }
    let template = try evidenceRequire(CompletionEvidenceProjection.evidence(in: CompletionEvidenceProjection.template), "the documented template does not parse")
    try evidenceExpect(template.sections == [.implemented, .tested, .unableToTest], "the documented template does not carry the three headings in order")
    try evidenceExpect(
        CompletionEvidenceProjection.template.contains("## Implemented") && CompletionEvidenceProjection.template.contains("## Tested") && CompletionEvidenceProjection.template.contains("## Unable to test"),
        "the template lost a heading"
    )
    let lowered = CompletionEvidenceProjection.template.lowercased()
    try evidenceExpect(lowered.contains("command") && lowered.contains("outcome") && lowered.contains("reason"), "the template does not ask for each command, its outcome, and a reason")
}

func checkCompletionEvidenceIgnoresUnknownHeadingsAndPreservesBodies() throws {
    let fenced = "Run it:\n\n```sh\n# not a heading\nnpm test\n```\n\n- list item one\n- list item two\n\n    indented code line"
    let text = """
    ## Notes
    These notes are not evidence.

    ## Tested
    \(fenced)

    ### Unable to test
    \(unableBody)

    ## Follow-ups
    Also not evidence.

    #Implemented
    Missing space, not a heading.

    Tested
    ------
    Setext is not recognised.

        # Tested
    An indented code block is not a heading.

    ## Tested:
    Punctuation is not recognised.

       ###### implemented ###\(String(repeating: " ", count: 3))
    \(implementedBody)
    """
    let evidence = try evidenceRequire(CompletionEvidenceProjection.evidence(in: text), "mixed document produced no evidence")
    try evidenceExpect(evidence.sections == [.tested, .unableToTest, .implemented], "sections were not recognised in document order: \(evidence.sections)")
    let tested = try evidenceRequire(evidence.body(for: .tested), "Tested body missing")
    try evidenceExpect(tested == fenced, "the Tested body was not preserved as plain text: \(tested.debugDescription)")
    try evidenceExpect(tested.contains("# not a heading") && tested.contains("- list item two") && tested.contains("    indented code line"), "fence, list or indentation content was lost")
    let implemented = try evidenceRequire(evidence.body(for: .implemented), "case-insensitive, indented, closed heading was not recognised")
    try evidenceExpect(implemented == implementedBody, "the Implemented body was altered: \(implemented.debugDescription)")
    try evidenceExpect(evidence.body(for: .unableToTest) == unableBody, "the level-3 Unable to test body was altered")
    let allBodies = evidence.entries.map(\.body).joined(separator: "\n")
    for leaked in ["These notes are not evidence.", "Also not evidence.", "Missing space, not a heading.", "Setext is not recognised.", "An indented code block is not a heading.", "Punctuation is not recognised."] {
        try evidenceExpect(!allBodies.contains(leaked), "non-evidence text became evidence: \(leaked)")
    }
    try evidenceExpect(evidence.ignoredHeadingCount == 3, "unknown headings (Notes, Follow-ups, Tested:) were not counted as ignored: \(evidence.ignoredHeadingCount)")

    let spaced = "##   UNABLE   TO   TEST   \n\(unableBody)\n"
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: spaced)?.body(for: .unableToTest) == unableBody, "case and internal whitespace policy was not applied")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: "## Tested (all)\nbody") == nil, "extra words in a heading were recognised")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: "## Implemented\r\nbody\r\n")?.body(for: .implemented) == "body", "CRLF input was not normalised")
}

func checkCompletionEvidenceDuplicateEmptyMissingAndBounds() throws {
    let duplicate = section("Tested", testedBody) + "\n" + section("Tested", "second copy must be ignored") + "\n" + section("Implemented", implementedBody)
    let evidence = try evidenceRequire(CompletionEvidenceProjection.evidence(in: duplicate), "duplicate document produced no evidence")
    try evidenceExpect(evidence.sections == [.tested, .implemented], "duplicate heading changed the section list: \(evidence.sections)")
    try evidenceExpect(evidence.body(for: .tested) == testedBody, "the first Tested body did not win")
    try evidenceExpect(evidence.duplicateHeadingCount == 1, "the duplicate was not counted: \(evidence.duplicateHeadingCount)")
    try evidenceExpect(!evidence.entries.map(\.body).joined().contains("second copy"), "a duplicate section's body became evidence")
    try evidenceExpect(evidence.missing == [.unableToTest], "the missing heading was not reported: \(evidence.missing)")

    let emptyTested = "## Implemented\n\(implementedBody)\n\n## Tested\n\n\n## Unable to test\n\(unableBody)\n"
    let withEmpty = try evidenceRequire(CompletionEvidenceProjection.evidence(in: emptyTested), "a document with one empty section produced no evidence")
    try evidenceExpect(withEmpty.sections == [.implemented, .tested, .unableToTest] && withEmpty.body(for: .tested) == "", "an empty recognised section was not retained with an empty body")
    try evidenceExpect(withEmpty.missing.isEmpty, "an empty section was reported as missing")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: "## Implemented\n\n## Tested\n") == nil, "recognised headings with no content at all counted as evidence")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: "# Report\n\nPlain prose without the headings.\n\n## Summary\nDone.") == nil, "a file without the headings produced an evidence block")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: "") == nil, "empty text produced evidence")

    try evidenceExpect(CompletionEvidence.maximumBytes == ContextPackBuilder.defaultMaximumPartBytes, "the evidence bound differs from the staged part bound")
    let padding = String(repeating: "x", count: CompletionEvidence.maximumBytes - section("Tested", testedBody).utf8.count)
    let atBound = section("Tested", testedBody) + padding
    try evidenceExpect(atBound.utf8.count == CompletionEvidence.maximumBytes, "bound fixture is mis-sized")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: atBound) != nil, "text exactly at the bound was refused")
    try evidenceExpect(CompletionEvidenceProjection.evidence(in: atBound + "x") == nil, "text over the bound was parsed")
}

func checkCompletionEvidenceOnlyReadsTheExactReturnedFile() throws {
    let text = section("Implemented", implementedBody) + "\n" + section("Tested", testedBody) + "\n" + section("Unable to test", unableBody)
    let handoff = try evidenceHandoff()
    let review = evidenceReview(parts: [agentPart(text)])
    let evidence = try evidenceRequire(CompletionEvidenceProjection.evidence(for: handoff, review: review), "the exact returned file produced no evidence")
    try evidenceExpect(evidence.sections == [.implemented, .tested, .unableToTest], "the returned file's sections were not projected")

    try evidenceExpect(CompletionEvidenceProjection.evidence(for: handoff, review: nil) == nil, "a missing review produced evidence")
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: handoff, review: evidenceReview(id: "review-2", parts: [agentPart(text)])) == nil, "a review with a different id was interpreted")
    let withoutReview = try evidenceHandoff(reviewID: nil)
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: withoutReview, review: review) == nil, "a handoff without a result review was interpreted")
    let ask = try evidenceHandoff(kind: .ask)
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: ask, review: review) == nil, "an Ask was interpreted as a delegation result")
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: handoff, review: evidenceReview(parts: [agentPart(text, referenceID: "some-other-handoff")])) == nil, "a part returned for another delegation was interpreted")
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: handoff, review: evidenceReview(parts: [agentPart(text, kind: .file)])) == nil, "a person-authored trusted capture was interpreted as agent evidence")
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: handoff, review: evidenceReview(parts: [agentPart(text, referenceID: nil)])) == nil, "an agent draft without delegation lineage was interpreted")

    // Added trusted parts are never parsed; only the exact returned file is.
    let trusted = ContextPackPart(
        source: ContextPackSource(kind: .file, label: "notes.md", detail: "/private/project/notes.md", referenceID: nil),
        capturedText: "## Tested\nPerson-authored text that must not be read as agent evidence."
    )
    let mixed = evidenceReview(parts: [trusted, agentPart(section("Implemented", implementedBody))])
    let onlyAgent = try evidenceRequire(CompletionEvidenceProjection.evidence(for: handoff, review: mixed), "the agent file beside a trusted part was not interpreted")
    try evidenceExpect(onlyAgent.sections == [.implemented], "a trusted part's headings leaked into the evidence: \(onlyAgent.sections)")
    let twoAgentFiles = evidenceReview(parts: [agentPart(section("Implemented", implementedBody)), agentPart(section("Tested", testedBody))])
    try evidenceExpect(CompletionEvidenceProjection.evidence(for: handoff, review: twoAgentFiles) == nil, "an ambiguous pack with two returned files was interpreted")

    // The staged bytes are read, not a later human edit, and nothing is mutated.
    let edited = evidenceReview(parts: [agentPart(section("Implemented", implementedBody)).replacingText(section("Implemented", implementedBody) + "\n## Tested\nAdded during human review.")])
    let staged = try evidenceRequire(CompletionEvidenceProjection.evidence(for: handoff, review: edited), "an edited review lost its staged evidence")
    try evidenceExpect(staged.sections == [.implemented], "a human edit changed the agent-declared evidence: \(staged.sections)")
    let before = review
    _ = CompletionEvidenceProjection.evidence(for: handoff, review: review)
    try evidenceExpect(review == before && review.pack.parts.first?.capturedText == text, "projection mutated the staged review")
}

func checkCompletionEvidenceWordingIsAgentDeclared() throws {
    try evidenceExpect(CompletionEvidence.label == "AGENT-DECLARED", "the evidence label is not AGENT-DECLARED: \(CompletionEvidence.label)")
    let statics = [CompletionEvidence.label, CompletionEvidence.disclaimer, CompletionEvidenceProjection.template]
        + CompletionEvidenceSection.allCases.map(\.heading)
    for text in statics {
        let lowered = text.lowercased()
        for banned in ["passed", "verified", "trusted", "successful", "success"] {
            try evidenceExpect(!lowered.contains(banned), "Parley-authored evidence wording claims an outcome (\(banned)): \(text)")
        }
    }
    try evidenceExpect(CompletionEvidence.disclaimer.lowercased().contains("ran nothing") && CompletionEvidence.disclaimer.lowercased().contains("claim"), "the disclaimer does not state that these are unchecked claims: \(CompletionEvidence.disclaimer)")
    let claims = "## Tested\n- `npm test` — passed, verified by me\n"
    let evidence = try evidenceRequire(CompletionEvidenceProjection.evidence(in: claims), "agent claims produced no evidence")
    try evidenceExpect(evidence.body(for: .tested) == "- `npm test` — passed, verified by me", "the agent's own wording was rewritten instead of being shown as a claim")

    let searchable = ParleyHelpGuide.topics.map(\.searchableText).joined(separator: "\n").lowercased()
    for concept in ["completion evidence", "## implemented", "## tested", "## unable to test", "agent-declared"] {
        try evidenceExpect(searchable.contains(concept), "the in-app help omitted \(concept)")
    }
}
