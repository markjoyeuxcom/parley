import Foundation
import ParleyCore

private func askExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NSError(domain: "AskCorrelation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func askRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw NSError(domain: "AskCorrelation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return value
}

private func correlationPane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/tmp",
        currentCommand: kind.rawValue, isActive: false, workspaceID: "workspace", relayEnabled: true,
        workspaceName: "Correlation", inputAvailable: true, automationPolicy: .askAndDelegate)
}

/// Collects what the broker submitted into a pane, so a check can read the
/// exact instructions a target receives.
private final class SubmittedText: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(pane: String, text: String)] = []

    func record(_ pane: String, _ text: String) { lock.withLock { entries.append((pane, text)) } }
    var all: [(pane: String, text: String)] { lock.withLock { entries } }
    func first(for pane: String) -> String? { lock.withLock { entries.first { $0.pane == pane }?.text } }
    var count: Int { lock.withLock { entries.count } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    var get: T? { lock.withLock { value } }
}

private func waitUntil(_ timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        usleep(20_000)
    }
    return predicate()
}

private struct CorrelationFixture {
    let broker: RelayBroker
    let submitted: SubmittedText
    let sourceToken: String
    let targetToken: String
    let otherToken: String
    let source: WorkbenchPane
    let target: WorkbenchPane
    let directory: URL
}

private func makeFixture(consultationTimeout: TimeInterval) throws -> CorrelationFixture {
    let directory = URL(fileURLWithPath: "/tmp/parley-askcorr-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
    let source = correlationPane("corr-source", .claude, "Source")
    let target = correlationPane("corr-target", .codex, "Target")
    let other = correlationPane("corr-other", .agy, "Other")
    let submitted = SubmittedText()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, target, other] },
        paste: { _, _ in },
        submit: { paneID, text in submitted.record(paneID, text) },
        consultationTimeout: consultationTimeout,
        handoffJournal: journal)
    return CorrelationFixture(
        broker: broker,
        submitted: submitted,
        sourceToken: try credentials.token(for: source.id),
        targetToken: try credentials.token(for: target.id),
        otherToken: try credentials.token(for: other.id),
        source: source,
        target: target,
        directory: directory)
}

/// The instructions delivered with a question must name that exact question.
///
/// `parley answer current` resolves to whichever consultation the target pane
/// currently holds unanswered, so a target that finishes an expired question's
/// work and answers with `current` lands its answer on a *different*, newer
/// question and Parley reports success. `AgentProtocol.text` already tells
/// agents to use the exact `parley answer <id>` a consultation supplies; the
/// generated prompt is what taught them otherwise.
func askAnswerCorrelationChecks() throws {
    let fixture = try makeFixture(consultationTimeout: 1)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let acceptedID = Box<String>()
    let outcome = Box<String>()

    // The Ask blocks its caller, so run it off this thread and read the
    // instructions the target was actually given.
    let question = "What is the exact failing check?"
    Thread.detachNewThread {
        let response = fixture.broker.handleAsk(
            token: fixture.sourceToken,
            target: fixture.target.id,
            text: question,
            idempotencyKey: "corr-prompt-key",
            onAccepted: { id in acceptedID.set(id) })
        outcome.set("\(response.status) \(response.text)")
    }
    // Evaluate the wait before building any failure text: askExpect takes its
    // condition as an autoclosure but its message eagerly, so reading state
    // inside the message would report it from before the wait ran.
    let delivered = waitUntil { acceptedID.get != nil && fixture.submitted.all.contains { $0.text.contains(question) } }
    try askExpect(delivered,
        "the question was never submitted to the target (ask returned: \(outcome.get ?? "still blocked"))")
    let handoffID = try askRequire(acceptedID.get, "the broker never reported an accepted consultation id")
    let prompt = try askRequire(fixture.submitted.all.first { $0.text.contains(question) }?.text,
        "nothing carrying the question was submitted to the target pane")

    try askExpect(prompt.contains(handoffID),
        "the delivered prompt does not name the exact consultation id, so a late answer can land on a different question")
    try askExpect(!prompt.contains("parley answer current"),
        "the delivered prompt still teaches `parley answer current`, which resolves to whichever question the pane currently holds")
}

/// A target whose question has expired must be told what became of it. A bare
/// "unknown consultation" reads like a fault and invites a retry of work that
/// can never be accepted.
func askExpiredAnswerDiagnosticChecks() throws {
    let fixture = try makeFixture(consultationTimeout: 1)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let acceptedID = Box<String>()
    let asked = Box<Int>()

    DispatchQueue.global().async {
        let response = fixture.broker.handleAsk(
            token: fixture.sourceToken,
            target: fixture.target.id,
            text: "This one will expire.",
            idempotencyKey: "corr-expire",
            onAccepted: { id in acceptedID.set(id) })
        asked.set(response.status)
    }
    try askExpect(waitUntil { acceptedID.get != nil }, "the question was never accepted")
    let handoffID = acceptedID.get ?? ""
    try askExpect(waitUntil(10) { asked.get != nil }, "the Ask never returned after its timeout")
    try askExpect(asked.get == 408, "an expired Ask should report a timeout, got \(asked.get.map(String.init) ?? "nothing")")

    // The target finishes late and answers the exact question it was given.
    let late = fixture.broker.handleAnswer(
        token: fixture.targetToken, consultationID: handoffID, text: "late but correct")
    try askExpect(late.status != 200, "an expired consultation accepted a late answer")
    try askExpect(late.text != "unknown consultation",
        "an expired consultation still reports a bare 'unknown consultation' to the pane that was asked")
    try askExpect(late.text.lowercased().contains("not accepted") || late.text.lowercased().contains("no longer"),
        "the refusal does not tell the target its answer was not delivered: \(late.text)")

    // A pane that was never the target learns nothing about it.
    let stranger = fixture.broker.handleAnswer(
        token: fixture.otherToken, consultationID: handoffID, text: "not mine")
    try askExpect(stranger.text == "unknown consultation",
        "a pane that was not the target was told about someone else's consultation: \(stranger.text)")
}

/// `parley answer current` stays correct for the ordinary single-question case;
/// this change narrows what teaches it, not what it does.
func askAnswerCurrentStillWorksChecks() throws {
    let fixture = try makeFixture(consultationTimeout: 30)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let acceptedID = Box<String>()
    let answer = Box<String>()

    DispatchQueue.global().async {
        let response = fixture.broker.handleAsk(
            token: fixture.sourceToken,
            target: fixture.target.id,
            text: "Answered through current.",
            idempotencyKey: "corr-current",
            onAccepted: { id in acceptedID.set(id) })
        answer.set(response.text)
    }
    try askExpect(waitUntil { acceptedID.get != nil }, "the question was never accepted")
    let accepted = fixture.broker.handleAnswer(
        token: fixture.targetToken, consultationID: "current", text: "still fine")
    try askExpect(accepted.status == 200, "current failed for a single waiting consultation: \(accepted.text)")
    try askExpect(waitUntil { answer.get != nil }, "the asker never received the answer")
    try askExpect(answer.get == "still fine", "the asker received the wrong text: \(answer.get ?? "nothing")")
}

@MainActor
let askCorrelationChecks: [(String, () throws -> Void)] = [
    ("a delivered question names its own consultation id rather than `current`", askAnswerCorrelationChecks),
    ("an expired consultation tells its target what became of it, and tells no one else", askExpiredAnswerDiagnosticChecks),
    ("`parley answer current` still answers a single waiting consultation", askAnswerCurrentStillWorksChecks),
]
