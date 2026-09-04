import Dispatch
import Foundation
import ParleyCore

private enum RequestChangesCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private final class ChangesResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RelayTextResponse?

    var value: RelayTextResponse? { lock.withLock { stored } }
    func set(_ value: RelayTextResponse) { lock.withLock { stored = value } }
}

private func changesExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RequestChangesCheckFailure.failed(message) }
}

private func changesRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw RequestChangesCheckFailure.failed(message) }
    return value
}

private func changesEventually(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return condition()
}

private func changesDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-request-changes-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func changesPane(_ id: String, _ kind: PaneKind, _ name: String, cwd: String = "/private/project") -> WorkbenchPane {
    WorkbenchPane(
        id: id,
        kind: kind,
        customName: name,
        terminalTitle: "PRIVATE TITLE",
        cwd: cwd,
        currentCommand: "PRIVATE COMMAND",
        isActive: id == "%owner",
        workspaceID: "@changes",
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "Changes",
        inputAvailable: true
    )
}

/// Decodes a handoff exactly as the journal would, so the thread projection
/// is exercised on owned timestamps rather than broker wall-clock time.
private func threadFixture(
    id: String,
    kind: RelayHandoffKind,
    state: RelayHandoffState,
    transitions: [(RelayHandoffState, TimeInterval)],
    parent: String? = nil,
    relationship: RelayHandoffRelationship? = nil,
    resultText: String? = nil,
    sourceName: String = "Owner",
    targetName: String = "Implementer"
) throws -> RelayHandoff {
    var object: [String: Any] = [
        "id": id,
        "idempotencyKey": "key-\(id)",
        "kind": kind.rawValue,
        "sourcePaneID": "%\(sourceName.lowercased())",
        "sourceName": sourceName,
        "sourceKind": "codex",
        "sourceWorkspaceID": "@changes",
        "sourceWorkspaceName": "Changes",
        "targetPaneID": "%\(targetName.lowercased())",
        "targetName": targetName,
        "targetKind": "claude",
        "targetWorkspaceID": "@changes",
        "targetWorkspaceName": "Changes",
        "text": "Instruction for \(id)",
        "submitted": true,
        "state": state.rawValue,
        "updatedAt": transitions.last?.1 ?? 0,
        "transitions": transitions.map { entry -> [String: Any] in
            ["state": entry.0.rawValue, "occurredAt": entry.1, "detail": NSNull()]
        },
    ]
    if let parent { object["inReplyToHandoffID"] = parent }
    if let relationship { object["relationship"] = relationship.rawValue }
    if let resultText { object["resultText"] = resultText }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(RelayHandoff.self, from: data)
}

func checkRequestChangesIsOneLinkedDelegateChild() throws {
    let directory = try changesDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
    let owner = changesPane("%owner", .codex, "Owner")
    let implementer = changesPane("%implementer", .claude, "Implementer")
    let reviewer = changesPane("%reviewer", .copilot, "Reviewer")
    let outsider = changesPane("%outsider", .agy, "Outsider")
    let ownerToken = try credentials.token(for: owner.id)
    let implementerToken = try credentials.token(for: implementer.id)
    let reviewerToken = try credentials.token(for: reviewer.id)
    let outsiderToken = try credentials.token(for: outsider.id)
    let panes = [owner, implementer, reviewer, outsider]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "request-changes-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let control = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "wrong-control")

    // Missing parent: refused before anything is created.
    let missing = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Revise the missing result.",
        idempotencyKey: "changes-missing-parent",
        inReplyToHandoffID: "00000000-0000-0000-0000-000000000000"
    )
    try changesExpect(missing.status == 404, "a Request Changes child accepted a missing parent: \(missing.status)")
    try changesExpect(broker.handoffs().isEmpty, "a refused Request Changes still created a handoff")

    // Parent without a returned result: refused.
    let delegated = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Implement the reviewed change.",
        idempotencyKey: "changes-parent"
    )
    let parentID = try changesRequire(delegated.body.handoffID, "parent delegation returned no identity")
    let premature = broker.handleDelegate(
        token: ownerToken,
        target: reviewer.id,
        text: "Revise before you have even finished.",
        idempotencyKey: "changes-premature",
        inReplyToHandoffID: parentID
    )
    try changesExpect(premature.status == 409, "a Request Changes child linked a parent without a returned result: \(premature.status)")
    try changesExpect(broker.handoffs().count == 1, "a refused premature Request Changes created a handoff")

    let completed = broker.handleDelegationResult(
        token: implementerToken,
        handoffID: parentID,
        text: "Implemented with deterministic checks.",
        succeeded: true
    )
    try changesExpect(completed.status == 200, "parent delegation did not complete")

    // Parent must be a Delegate: an answered Ask is refused as a parent.
    let askBox = ChangesResponseBox()
    DispatchQueue.global(qos: .utility).async {
        askBox.set(broker.handleAsk(
            token: ownerToken,
            target: reviewer.id,
            text: "Is the change sound?",
            idempotencyKey: "changes-ask-parent"
        ))
    }
    try changesExpect(
        changesEventually { broker.consultations().contains(where: { $0.targetPaneID == reviewer.id }) },
        "the Ask parent fixture never became a consultation"
    )
    let consultation = try changesRequire(
        broker.consultations().first(where: { $0.targetPaneID == reviewer.id }),
        "the Ask consultation disappeared"
    )
    try changesExpect(
        broker.handleAnswer(token: reviewerToken, consultationID: consultation.id, text: "Yes.").status == 200,
        "the Ask parent fixture could not be answered"
    )
    try changesExpect(changesEventually { askBox.value?.status == 200 }, "the Ask parent fixture did not return")
    let askParent = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Revise an Ask.",
        idempotencyKey: "changes-ask-as-parent",
        inReplyToHandoffID: consultation.id
    )
    try changesExpect(askParent.status == 409, "a Request Changes child linked an Ask parent: \(askParent.status)")

    // Forged lineage: a pane that neither initiated nor received the parent.
    for (label, token) in [("an unrelated pane", outsiderToken), ("the reviewer", reviewerToken)] {
        let forged = broker.handleDelegate(
            token: token,
            target: implementer.id,
            text: "Revise someone else's delegation.",
            idempotencyKey: "changes-forged-\(label.count)",
            inReplyToHandoffID: parentID
        )
        try changesExpect(forged.status == 403, "\(label) forged Request Changes lineage: \(forged.status) \(forged.body.error ?? "")")
    }
    try changesExpect(
        broker.handoffs().count { $0.inReplyToHandoffID == parentID } == 0,
        "a refused lineage attempt still recorded a child"
    )

    // Busy rule: a linked child is refused, never queued or drafted.
    let occupying = broker.handleDelegate(
        token: reviewerToken,
        target: implementer.id,
        text: "Unrelated tracked work.",
        idempotencyKey: "changes-occupy"
    )
    let occupyingID = try changesRequire(occupying.body.handoffID, "the occupying delegation was not created")
    let busy = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Revise while busy.",
        idempotencyKey: "changes-busy",
        inReplyToHandoffID: parentID
    )
    try changesExpect(busy.status == 409 && (busy.body.error ?? "").contains("tracked work"), "a busy target accepted a linked child: \(busy.status) \(busy.body.error ?? "")")
    try changesExpect(broker.reviewedBusyDrafts().isEmpty, "a refused linked child entered the reviewed busy queue")
    try changesExpect(
        broker.handoffs().count { $0.inReplyToHandoffID == parentID } == 0,
        "a busy refusal still recorded a linked child"
    )
    try changesExpect(
        broker.cancelHandoff(token: reviewerToken, handoffID: occupyingID).status == 200,
        "could not release the occupying delegation"
    )

    // The initiating pane names its parent: exactly one linked Delegate child.
    let child = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Revise the result: add the restart-recovery check.",
        idempotencyKey: "changes-child",
        inReplyToHandoffID: parentID
    )
    try changesExpect(child.status == 200, "the initiating pane could not request changes: \(child.status) \(child.body.error ?? "")")
    let childID = try changesRequire(child.body.handoffID, "the linked child returned no identity")
    let replay = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Revise the result: add the restart-recovery check.",
        idempotencyKey: "changes-child",
        inReplyToHandoffID: parentID
    )
    try changesExpect(replay.body.handoffID == childID, "an idempotent replay created a second child")
    let differentParent = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Revise the result: add the restart-recovery check.",
        idempotencyKey: "changes-child",
        inReplyToHandoffID: consultation.id
    )
    try changesExpect(differentParent.status == 409, "one idempotency key served two different parents")
    let children = broker.handoffs().filter { $0.inReplyToHandoffID == parentID }
    try changesExpect(children.count == 1, "expected exactly one linked child, found \(children.count)")
    let linked = try changesRequire(children.first, "the linked child disappeared")
    try changesExpect(linked.id == childID && linked.kind == .delegate, "the linked child is not a Delegate")
    try changesExpect(linked.relationship == .requestChanges, "the linked child lost its requestChanges relationship")
    try changesExpect(linked.state == .waiting, "the linked child did not enter normal tracked delivery")
    try changesExpect(linked.transitions.first?.origin == nil, "a pane-initiated child was recorded as human-originated")
    let parentAfterChild = try changesRequire(broker.handoffs().first(where: { $0.id == parentID }), "the parent disappeared")
    try changesExpect(parentAfterChild.humanVerdict == nil && parentAfterChild.reviewRevision == nil, "a vendor request for changes became a human verdict")

    let revised = broker.handleDelegationResult(
        token: implementerToken,
        handoffID: childID,
        text: "Revised: restart-recovery check added.",
        succeeded: true
    )
    try changesExpect(revised.status == 200, "the implementer could not return the revised result")

    // Thread and export on the existing handoffs.
    let all = broker.handoffs()
    let thread = HandoffThreadProjection.thread(containing: parentID, in: all)
    try changesExpect(
        thread.map(\.label) == ["Delegation", "Result", "Request changes", "Revised result"],
        "the Status Center thread is not Delegation → Result → Request changes → Revised result: \(thread.map(\.label))"
    )
    try changesExpect(
        HandoffThreadProjection.thread(containing: childID, in: all) == thread,
        "the thread differs depending on which member is selected"
    )
    let markdown = CollaborationHistoryMarkdown.document(
        handoffs: all.filter { $0.id == parentID || $0.id == childID },
        scopeName: "Changes"
    )
    try changesExpect(markdown.contains("- In reply to: `\(parentID)`"), "history export lost the child's parent")
    try changesExpect(markdown.contains("- Relationship: requestChanges"), "history export lost the requestChanges relationship")
    try changesExpect(
        markdown.contains("- Thread: Delegation → Result → Request changes → Revised result"),
        "history export lost the chronological thread"
    )
    try changesExpect(markdown.contains("- Linked children: `\(childID)`"), "history export lost the parent's link to its child")

    let eventResponse = broker.agentEvents(token: ownerToken, since: "beginning")
    let eventPage = try JSONDecoder().decode(RelayAgentEventPage.self, from: Data(eventResponse.text.utf8))
    try changesExpect(eventPage.events.contains(where: {
        $0.handoffID == childID && $0.inReplyToHandoffID == parentID && $0.relationship == .requestChanges
    }), "content-minimal events lost Request Changes lineage")

    // Native route: human-originated, native-control-only, same lineage rules.
    let rejected = try unauthorized.requestChangesFromUI(
        sourcePaneID: owner.id,
        targetPaneID: implementer.id,
        text: "Unauthenticated UI must not do this.",
        idempotencyKey: "changes-ui-unauthorized",
        inReplyToHandoffID: parentID
    )
    try changesExpect(rejected.status == 401, "an unauthenticated UI created a linked child: \(rejected.status)")
    let uiAskParent = try control.requestChangesFromUI(
        sourcePaneID: owner.id,
        targetPaneID: implementer.id,
        text: "Revise an Ask from the UI.",
        idempotencyKey: "changes-ui-ask-parent",
        inReplyToHandoffID: consultation.id
    )
    try changesExpect(uiAskParent.status == 409, "the native route linked an Ask parent: \(uiAskParent.status)")
    let uiChild = try control.requestChangesFromUI(
        sourcePaneID: owner.id,
        targetPaneID: implementer.id,
        text: """
        Revise again:

            keep this indentation
        """,
        idempotencyKey: "changes-ui-child",
        inReplyToHandoffID: parentID
    )
    try changesExpect(uiChild.status == 200, "the native Request Changes route failed: \(uiChild.status) \(uiChild.text)")
    let uiLinked = try changesRequire(
        broker.handoffs().first(where: { $0.inReplyToHandoffID == parentID && $0.id != childID }),
        "the native route created no linked child"
    )
    try changesExpect(uiLinked.kind == .delegate && uiLinked.relationship == .requestChanges, "the native child lost its kind or relationship")
    try changesExpect(uiLinked.transitions.first?.origin == .human, "the native child was not recorded as human-originated")
    try changesExpect(uiLinked.text.contains("\n\n    keep this indentation"), "the native child flattened the edited formatting")
    try changesExpect(
        broker.handleDelegationResult(token: implementerToken, handoffID: uiLinked.id, text: "Revised twice.", succeeded: true).status == 200,
        "the second revision could not be returned"
    )

    // The receiving pane may also name the parent it received.
    let fromReceiver = broker.handleDelegate(
        token: implementerToken,
        target: owner.id,
        text: "Please clarify the acceptance criteria before I revise again.",
        idempotencyKey: "changes-from-receiver",
        inReplyToHandoffID: parentID
    )
    try changesExpect(fromReceiver.status == 200, "the receiving pane could not link the parent it received: \(fromReceiver.status) \(fromReceiver.body.error ?? "")")

    let durable = journal.handoffs()
    try changesExpect(
        durable.contains(where: { $0.id == childID && $0.inReplyToHandoffID == parentID && $0.relationship == .requestChanges }),
        "the durable journal lost Request Changes lineage"
    )
}

func checkRequestChangesShimFormNamesItsParent() throws {
    let directory = try changesDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let ownerToken = try credentials.token(for: "%owner")
    let implementerToken = try credentials.token(for: "%implementer")
    let panes = [
        changesPane("%owner", .codex, "Codex", cwd: directory.path),
        changesPane("%implementer", .claude, "Claude", cwd: directory.path),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3,
        livenessPollInterval: 0.01
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }
    let runner = ProcessCommandRunner(timeout: 5)
    let executable = shimDirectory.appendingPathComponent("parley").path
    let script = try String(contentsOfFile: executable, encoding: .utf8)
    try changesExpect(
        script.contains("parley delegate <pane> --parent <id>"),
        "the managed shim usage does not show the parent-naming Delegate form"
    )
    func environment(_ token: String, key: String) -> [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_TOKEN": token,
            "PARLEY_IDEMPOTENCY_KEY": key,
        ]) { _, supplied in supplied }
    }

    let delegated = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "Implement the selected change."],
        environment: environment(ownerToken, key: "shim-changes-parent"),
        input: nil
    )
    try changesExpect(delegated.status == 0, "parley delegate did not reach the local broker")
    let parentID = try changesRequire(
        try JSONDecoder().decode(RelayResponseBody.self, from: delegated.stdout).handoffID,
        "delegate shim returned no handoff id"
    )
    try changesExpect(
        broker.handleDelegationResult(token: implementerToken, handoffID: parentID, text: "Done.", succeeded: true).status == 200,
        "the parent could not be completed"
    )

    let missingValue = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "--parent"],
        environment: environment(ownerToken, key: "shim-changes-missing"),
        input: nil
    )
    try changesExpect(missingValue.status == 2, "--parent without an id was not refused by the shim: \(missingValue.status)")
    let malformed = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "--parent", "not/an/id", "Revise."],
        environment: environment(ownerToken, key: "shim-changes-malformed"),
        input: nil
    )
    try changesExpect(malformed.status == 2, "a malformed parent id was not refused by the shim: \(malformed.status)")
    try changesExpect(broker.handoffs().count == 1, "a refused shim form still reached the broker")

    let unknownParent = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "--parent", "00000000-0000-0000-0000-000000000000", "Revise."],
        environment: environment(ownerToken, key: "shim-changes-unknown"),
        input: nil
    )
    try changesExpect(unknownParent.status != 0, "an unknown parent id succeeded through the shim")

    let child = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "--parent", parentID, "Revise the result with a recovery check."],
        environment: environment(ownerToken, key: "shim-changes-child"),
        input: nil
    )
    try changesExpect(child.status == 0, "the parent-naming Delegate form failed: \(child.status) \(child.stderrText)")
    let receipt = try JSONDecoder().decode(RelayResponseBody.self, from: child.stdout)
    let childID = try changesRequire(receipt.handoffID, "the linked child returned no id through the shim")
    let linked = try changesRequire(broker.handoffs().first(where: { $0.id == childID }), "the linked child disappeared")
    try changesExpect(
        linked.kind == .delegate && linked.inReplyToHandoffID == parentID && linked.relationship == .requestChanges,
        "the shim form did not record requestChanges lineage"
    )
    try changesExpect(
        linked.text == "Revise the result with a recovery check.",
        "the shim leaked the --parent option into the task text: \(linked.text)"
    )
    try changesExpect(receipt.state == .waiting, "the linked child did not enter normal tracked delivery")
}

func checkHandoffThreadProjectionOrdersLineageChronologically() throws {
    let parent = try threadFixture(
        id: "parent",
        kind: .delegate,
        state: .completed,
        transitions: [(.created, 1_000), (.delivered, 1_002), (.waiting, 1_002), (.completed, 1_500)],
        resultText: "Done."
    )
    let child = try threadFixture(
        id: "child",
        kind: .delegate,
        state: .completed,
        transitions: [(.created, 1_600), (.delivered, 1_601), (.waiting, 1_601), (.completed, 1_900)],
        parent: "parent",
        relationship: .requestChanges,
        resultText: "Revised."
    )
    let verify = try threadFixture(
        id: "verify",
        kind: .ask,
        state: .completed,
        transitions: [(.created, 1_950), (.delivered, 1_951), (.waiting, 1_951), (.completed, 1_980)],
        parent: "child",
        relationship: .verify,
        resultText: "Verified.",
        targetName: "Reviewer"
    )
    let pending = try threadFixture(
        id: "pending",
        kind: .delegate,
        state: .waiting,
        transitions: [(.created, 2_000), (.delivered, 2_001), (.waiting, 2_001)],
        parent: "parent",
        relationship: .requestChanges
    )
    let unrelated = try threadFixture(
        id: "unrelated",
        kind: .delegate,
        state: .completed,
        transitions: [(.created, 900), (.delivered, 901), (.waiting, 901), (.completed, 950)],
        resultText: "Other."
    )
    let handoffs = [pending, unrelated, verify, child, parent]

    let thread = HandoffThreadProjection.thread(containing: "child", in: handoffs)
    try changesExpect(
        thread.map(\.label) == ["Delegation", "Result", "Request changes", "Revised result", "Verify", "Answer", "Request changes"],
        "thread entries are not chronological across the whole lineage: \(thread.map(\.label))"
    )
    try changesExpect(
        thread.map(\.handoffID) == ["parent", "parent", "child", "child", "verify", "verify", "pending"],
        "thread entries lost their handoff identity or order: \(thread.map(\.handoffID))"
    )
    try changesExpect(
        thread.map(\.occurredAt.timeIntervalSinceReferenceDate) == [1_000, 1_500, 1_600, 1_900, 1_950, 1_980, 2_000],
        "thread entries are not stamped with owned transition times"
    )
    try changesExpect(!thread.contains(where: { $0.handoffID == "unrelated" }), "an unrelated handoff entered the thread")
    try changesExpect(Set(thread.map(\.id)).count == thread.count, "thread entry ids are not unique")
    for member in ["parent", "verify", "pending"] {
        try changesExpect(
            HandoffThreadProjection.thread(containing: member, in: handoffs) == thread,
            "the thread differs when entered from \(member)"
        )
    }
    try changesExpect(
        HandoffThreadProjection.thread(containing: "child", in: handoffs.reversed()) == thread,
        "thread order depends on input order"
    )
    try changesExpect(
        HandoffThreadProjection.summary(thread) == "Delegation → Result → Request changes → Revised result → Verify → Answer → Request changes",
        "the thread summary is not the arrow-joined chronological labels: \(HandoffThreadProjection.summary(thread))"
    )
    try changesExpect(
        HandoffThreadProjection.members(containing: "child", in: handoffs).map(\.id) == ["parent", "child", "verify", "pending"],
        "thread members are not the root and its descendants in creation order"
    )

    let lone = HandoffThreadProjection.thread(containing: "unrelated", in: handoffs)
    try changesExpect(lone.map(\.label) == ["Delegation", "Result"], "a lone delegation did not project its own two steps: \(lone.map(\.label))")
    try changesExpect(HandoffThreadProjection.members(containing: "unrelated", in: handoffs).count == 1, "a lone delegation gained thread members")
    try changesExpect(HandoffThreadProjection.thread(containing: "missing", in: handoffs).isEmpty, "an unknown handoff produced thread entries")

    // A malformed cycle terminates and still yields a bounded thread.
    let loopA = try threadFixture(id: "loop-a", kind: .delegate, state: .completed, transitions: [(.created, 10), (.delivered, 11), (.completed, 20)], parent: "loop-b", relationship: .requestChanges, resultText: "A")
    let loopB = try threadFixture(id: "loop-b", kind: .delegate, state: .completed, transitions: [(.created, 30), (.delivered, 31), (.completed, 40)], parent: "loop-a", relationship: .requestChanges, resultText: "B")
    let looped = HandoffThreadProjection.thread(containing: "loop-a", in: [loopA, loopB])
    try changesExpect(looped.count == 4 && Set(looped.map(\.handoffID)) == ["loop-a", "loop-b"], "a lineage cycle was not bounded: \(looped.map(\.id))")
}

func checkRequestChangesCopyIsTitleCaseAndNamesALinkedDelegate() throws {
    // Person-facing action, composer button and chips use title case.
    try changesExpect(RelayHandoffRelationship.requestChanges.label == "Request Changes", "the Request Changes action label is not title case: \(RelayHandoffRelationship.requestChanges.label)")
    try changesExpect(RelayHandoffRelationship.challenge.label == "Challenge" && RelayHandoffRelationship.verify.label == "Verify", "Challenge or Verify labels changed")
    try changesExpect(ChromeLabel.chipCase("Request Changes") == "Request Changes", "the chip rule rewrote the title-case action label")

    // Thread prose stays sentence case.
    let parent = try threadFixture(
        id: "copy-parent",
        kind: .delegate,
        state: .completed,
        transitions: [(.created, 1_000), (.delivered, 1_001), (.completed, 1_500)],
        resultText: "Done."
    )
    let child = try threadFixture(
        id: "copy-child",
        kind: .delegate,
        state: .waiting,
        transitions: [(.created, 1_600), (.delivered, 1_601), (.waiting, 1_601)],
        parent: "copy-parent",
        relationship: .requestChanges
    )
    let thread = HandoffThreadProjection.thread(containing: "copy-child", in: [parent, child])
    try changesExpect(thread.map(\.label) == ["Delegation", "Result", "Request changes"], "thread prose is not sentence case: \(thread.map(\.label))")

    // Messages for Request Changes name a linked Delegate, never a reviewer, review or Ask.
    let requestChangesCopy = [
        LinkedHandoffCopy.notRelayReady(.requestChanges),
        LinkedHandoffCopy.targetBusy(.requestChanges, targetName: "Implementer"),
        LinkedHandoffCopy.resultTooLarge(.requestChanges),
    ]
    for message in requestChangesCopy {
        try changesExpect(message.contains("linked Delegate"), "Request Changes copy does not name the linked Delegate: \(message)")
        let lowered = message.lowercased()
        for banned in ["reviewer", "linked review", "linked ask"] {
            try changesExpect(!lowered.contains(banned), "Request Changes copy describes a \(banned): \(message)")
        }
    }
    try changesExpect(
        LinkedHandoffCopy.targetBusy(.requestChanges, targetName: "Implementer").hasPrefix("Implementer already has tracked work."),
        "the busy message lost the exact target name"
    )

    // Challenge and Verify keep their existing copy exactly.
    for relationship in [RelayHandoffRelationship.challenge, .verify] {
        try changesExpect(
            LinkedHandoffCopy.notRelayReady(relationship)
                == "The selected result no longer has a relay-ready source and explicit reviewer pane. Nothing was sent.",
            "\(relationship.label) lost its not-ready copy"
        )
        try changesExpect(
            LinkedHandoffCopy.targetBusy(relationship, targetName: "Reviewer")
                == "Reviewer already has tracked work. Finish or cancel it before starting this linked review.",
            "\(relationship.label) lost its busy copy"
        )
        try changesExpect(
            LinkedHandoffCopy.resultTooLarge(relationship)
                == "This result is too large for one linked Ask. Add the selected result to a Context Pack and review its visible sources instead.",
            "\(relationship.label) lost its oversize copy"
        )
    }
}
