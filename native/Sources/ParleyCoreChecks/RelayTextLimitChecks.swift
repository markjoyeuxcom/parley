import Dispatch
import Foundation
import ParleyCore

private func limitExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RelayTextLimit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func limitRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "RelayTextLimit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// A message whose head says what it is and whose length is `count`.
private func message(_ head: String, count: Int) -> String {
    head + "\n" + String(repeating: "x", count: count - head.count - 1)
}

/// Review of 22 September 2026, M2: `RelayText.clean` kept only the last
/// 100,000 characters, so every later "too long" guard was dead and a long
/// review, answer or report lost its beginning while Parley reported success.
func checkRelayTextCleaningNeverDropsTheBeginning() throws {
    let long = message("Review the current repository changes below. Do not modify files.", count: 150_025)
    let cleaned = RelayText.clean(long)
    try limitExpect(cleaned.count == 150_025, "cleaning changed the length of plain text: \(cleaned.count)")
    try limitExpect(cleaned.hasPrefix("Review the current repository changes below."), "cleaning dropped the beginning of a long message")
}

/// Every broker route that carries text refuses it over the limit, with the
/// real count, and delivers or stores nothing; at the limit it is delivered
/// whole. The native editor dialog (`AppModel.editRelay`) enforces the same
/// limit for the routes that paste without the broker; it is modal and not
/// exercised here.
func checkOverLongRelayTextIsRefusedAndNothingIsDelivered() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-limit-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/\(id)", currentCommand: "x", isActive: false,
                      workspaceID: "@limit", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Limit",
                      inputAvailable: true)
    }
    let source = pane("source", .claude)
    let target = pane("target", .codex)
    let sourceToken = try credentials.token(for: source.id)
    let targetToken = try credentials.token(for: target.id)
    final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func append(_ text: String) { lock.withLock { texts.append(text) } }
        var all: [String] { lock.withLock { texts } }
        func reset() { lock.withLock { texts.removeAll() } }
    }
    let deliveries = Deliveries()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, target] },
        paste: { _, text in deliveries.append(text) },
        submit: { _, text in deliveries.append(text) },
        consultationTimeout: 10,
        livenessPollInterval: 0.01,
        contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json")),
        busyDraftStore: try ReviewedBusyDraftStore(file: directory.appendingPathComponent("reviewed-busy-drafts.json"))
    )
    let limit = RelayText.maximumCharacters
    let over = message("HEAD OF AN OVER-LONG MESSAGE", count: limit + 1)
    let atLimit = message("HEAD OF A MESSAGE AT THE LIMIT", count: limit)

    func refused(_ status: Int, _ text: String, _ route: String) throws {
        try limitExpect(status == 400, "\(route) over the limit returned \(status) instead of 400: \(text)")
        try limitExpect(limit == 100_000 && text.contains("100,001 characters") && text.contains("100,000-character limit"),
                        "\(route) did not state the real length and the limit: \(text)")
        try limitExpect(text.contains("nothing was sent"), "\(route) did not say that nothing was sent: \(text)")
        try limitExpect(deliveries.all.isEmpty, "\(route) delivered text while refusing it")
    }

    let relay = broker.handle(token: sourceToken, target: target.id, text: over)
    try refused(relay.status, relay.body.error ?? "", "relay")
    let paste = broker.handlePaste(token: sourceToken, target: target.id, text: over)
    try refused(paste.status, paste.body.error ?? "", "paste")
    let ask = broker.handleAsk(token: sourceToken, target: target.id, text: over)
    try refused(ask.status, ask.text, "ask")
    let delegated = broker.handleDelegate(token: sourceToken, target: target.id, text: over, idempotencyKey: "limit-over")
    try refused(delegated.status, delegated.body.error ?? delegated.body.note ?? "", "delegate")
    let many = broker.handleAskMany(token: sourceToken, targets: target.id, text: over)
    try refused(many.status, many.text, "ask-many")

    let whole = broker.handle(token: sourceToken, target: target.id, text: atLimit)
    try limitExpect(whole.status == 200, "a relay at the limit was refused: \(whole.body.error ?? "")")
    // Delivery adds Parley's attribution; the message itself arrives whole.
    try limitExpect(deliveries.all.count == 1 && deliveries.all[0].contains(atLimit), "a relay at the limit was not delivered whole")
    deliveries.reset()

    // An answer over the limit is refused and the consultation keeps waiting
    // for a real answer.
    final class AskResult: @unchecked Sendable { var response: RelayTextResponse? }
    let asked = AskResult()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        asked.response = broker.handleAsk(token: sourceToken, target: target.id, text: "A short question.")
        finished.signal()
    }
    let deadline = Date().addingTimeInterval(5)
    while broker.handoffs().first(where: { $0.kind == .ask && $0.state == .waiting }) == nil, Date() < deadline { usleep(10_000) }
    try limitExpect(broker.handoffs().contains { $0.kind == .ask && $0.state == .waiting }, "the short question never started waiting")
    deliveries.reset()
    let longAnswer = broker.handleAnswer(token: targetToken, consultationID: "current", text: over)
    try refused(longAnswer.status, longAnswer.text, "answer")
    try limitExpect(broker.handleAnswer(token: targetToken, consultationID: "current", text: "A short answer.").status == 200,
                    "the consultation did not accept a real answer after refusing a long one")
    try limitExpect(finished.wait(timeout: .now() + 5) == .success, "the ask never returned")
    try limitExpect(asked.response?.text == "A short answer.", "the ask did not return the real answer: \(String(describing: asked.response))")

    // A report over the limit is refused and the delegation stays open.
    deliveries.reset()
    let work = broker.handleDelegate(token: sourceToken, target: target.id, text: "Do a small thing.", idempotencyKey: "limit-work")
    let workID = try limitRequire(work.body.handoffID, "the short delegation returned no id")
    deliveries.reset()
    let longReport = broker.handleDelegationResult(token: targetToken, handoffID: workID, text: over, succeeded: true)
    try refused(longReport.status, longReport.text, "done")
    try limitExpect(broker.handoffs().first { $0.id == workID }?.state == .waiting, "a refused report changed the delegation's state")
    try limitExpect(longReport.text.contains("parley done <id> --file"), "the refused report did not point at done --file: \(longReport.text)")

    // A reviewed busy-queue draft sent with over-long edited text is refused
    // before the edit is stored: the queue keeps what the person last saved.
    let queued = broker.enqueueReviewedBusyAskFromUI(ReviewedBusyDraftCreateRequest(
        sourcePaneID: source.id, targetPaneID: target.id, text: "A queued question."))
    try limitExpect((200..<300).contains(queued.status), "a draft for a busy target was not queued: \(queued.status) \(queued.text)")
    let saved = try limitRequire(broker.reviewedBusyDrafts().first, "the queued draft is missing")
    let sent = broker.sendReviewedBusyAskFromUI(ReviewedBusyDraftSendRequest(draftID: saved.id, expectedUpdatedAt: saved.updatedAt, text: over))
    try refused(sent.status, sent.text, "reviewed busy-draft send")
    let kept = try limitRequire(broker.reviewedBusyDrafts().first { $0.id == saved.id }, "the refused send removed the queued draft")
    try limitExpect(kept.text == "A queued question." && kept.state == saved.state && kept.updatedAt == saved.updatedAt,
                    "the refused send changed the queued draft: \(kept)")
    try limitExpect(broker.handleDelegationResult(token: targetToken, handoffID: workID, text: "Done.", succeeded: true).status == 200,
                    "the delegation did not accept a real report after refusing a long one")
}

@MainActor let relayTextLimitChecks: [(String, () throws -> Void)] = [
    ("relay text cleaning never drops the beginning", checkRelayTextCleaningNeverDropsTheBeginning),
    ("over-long relay text is refused and nothing is delivered", checkOverLongRelayTextIsRefusedAndNothingIsDelivered),
]
