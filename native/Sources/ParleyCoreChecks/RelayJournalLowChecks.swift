import Darwin
import Dispatch
import Foundation
import ParleyCore

private func lowExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RelayJournalLow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026 (4b656187): the busy queue was saved with
/// `Data.write(.atomic)` and then `chmod`ed, so the renamed file existed for a
/// moment as 0644 and was never synced. A crash in that moment, or a torn
/// file after power loss, is refused at the next launch ("not an owner-only
/// regular file"), and the coordination core does not start. The file must
/// never be seen with any group or other permission.
func checkBusyQueueIsNeverVisibleWithWiderPermissions() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-busyfile-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("reviewed-busy-drafts.json")
    let store = try ReviewedBusyDraftStore(file: file)

    final class Watch: @unchecked Sendable {
        let lock = NSLock()
        var running = true
        var widest: mode_t = 0
        var samples = 0
    }
    let watch = Watch()
    let poller = Thread {
        while watch.lock.withLock({ watch.running }) {
            var metadata = stat()
            if lstat(file.path, &metadata) == 0 {
                watch.lock.withLock { watch.widest |= metadata.st_mode & 0o077; watch.samples += 1 }
            }
        }
    }
    poller.start()
    defer { watch.lock.withLock { watch.running = false } }
    for index in 0..<300 {
        let draft = ReviewedBusyDraft(sourcePaneID: "source", sourceName: "Source", sourceKind: .claude, sourceWorkspaceID: "@w",
                                      sourceWorkspaceName: "W", targetPaneID: "target", targetName: "Target", targetKind: .codex,
                                      targetWorkspaceID: "@w", targetWorkspaceName: "W", text: "Queued \(index)", preserveFormatting: false)
        try store.record(draft)
        try store.remove(id: draft.id)
    }
    watch.lock.withLock { watch.running = false }
    let (widest, samples) = watch.lock.withLock { (watch.widest, watch.samples) }
    try lowExpect(samples > 100, "the poller saw the file only \(samples) times")
    try lowExpect(widest == 0, "the busy queue was visible with group or other permissions (\(String(widest, radix: 8)))")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != file.lastPathComponent }
    try lowExpect(leftovers.isEmpty, "saving the busy queue left files behind: \(leftovers)")
    _ = try ReviewedBusyDraftStore(file: file)
}

/// The shared write every owner-only store now uses: the file is owner-only
/// the moment it appears, and a write that cannot commit leaves nothing.
func checkOwnerOnlyFileWrite() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-owneronly-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("store.json")
    try OwnerOnlyFile.write(Data("first".utf8), to: file)
    try OwnerOnlyFile.write(Data("second".utf8), to: file)
    let mode = ((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try lowExpect(mode == 0o600, "the file is \(String(mode, radix: 8)), not 0600")
    try lowExpect(try String(contentsOf: file, encoding: .utf8) == "second", "the second write did not replace the first")
    // A commit that fails (the target is a directory) keeps nothing new.
    let blocked = directory.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: blocked.appendingPathComponent("inside"), withIntermediateDirectories: false)
    var refused = false
    do { try OwnerOnlyFile.write(Data("x".utf8), to: blocked) } catch { refused = true }
    try lowExpect(refused, "a write over a non-empty directory was reported as committed")
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    try lowExpect(entries == ["blocked", "store.json"], "a failed write left files behind: \(entries)")
}

/// A broker with an agent source, a target and a third pane that can make the
/// target busy, over a real context review store.
private struct ContextFixture {
    let directory: URL
    let credentials: RelayCredentials
    let broker: RelayBroker
    let store: AgentContextReviewStore
    let panes: ContextPanes
    let sourceToken: String

    init(_ name: String, consultationTimeout: TimeInterval = 5, livenessPollInterval: TimeInterval = 0.02) throws {
        directory = URL(fileURLWithPath: "/tmp/parley-\(name)-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
        let panes = ContextPanes(directory.path)
        self.panes = panes
        store = try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
        broker = RelayBroker(credentials: credentials, panes: { panes.current }, paste: { _, _ in }, submit: { _, _ in },
                             consultationTimeout: consultationTimeout, livenessPollInterval: livenessPollInterval, contextReviewStore: store)
        sourceToken = try credentials.token(for: "source")
        _ = try credentials.token(for: "target")
        _ = try credentials.token(for: "lead")
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func stage(_ name: String) throws -> AgentContextReview {
        let file = directory.appendingPathComponent("\(name).md")
        try "staged \(name)\n".write(to: file, atomically: true, encoding: .utf8)
        let staged = broker.handleContextDraft(token: sourceToken, name: name, path: file.path, text: "staged \(name)\n")
        try lowExpect(staged.status == 201, "the draft was not staged: \(staged.text)")
        guard let review = broker.contextReviews().first(where: { $0.pack.parts.contains { $0.text.contains("staged \(name)") } }) else {
            throw NSError(domain: "RelayJournalLow", code: 2, userInfo: [NSLocalizedDescriptionKey: "the staged draft is missing"])
        }
        return review
    }
}

private final class ContextPanes: @unchecked Sendable {
    let lock = NSLock()
    var panes: [WorkbenchPane]
    var reads = 0
    init(_ folder: String) {
        func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
            WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: folder, currentCommand: "x", isActive: false,
                          workspaceID: "@low", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Low",
                          inputAvailable: true, isStarted: true)
        }
        panes = [pane("source", .claude), pane("target", .codex), pane("lead", .agy)]
    }
    var current: [WorkbenchPane] { lock.withLock { reads += 1; return panes } }
}

/// An agent's own context Ask that the person approved, refused before any
/// delivery (the target was busy), was marked failed and the approval lost.
/// Nothing was sent, so it goes back to a draft, as the person's own send does.
func checkRefusedContextAskReturnsToDraft() throws {
    let fixture = try ContextFixture("ctxrefused")
    defer { fixture.cleanup() }
    let busy = fixture.broker.handleDelegate(token: try fixture.credentials.token(for: "lead"), target: "target", text: "Busy.", idempotencyKey: "low-busy")
    try lowExpect(busy.status == 200, "the fixture could not make the target busy")
    let draft = try fixture.stage("refused")
    final class Result: @unchecked Sendable { let lock = NSLock(); var response: RelayTextResponse? }
    let result = Result()
    let token = fixture.sourceToken
    Thread.detachNewThread {
        let response = fixture.broker.handleContextAsk(token: token, draftID: draft.id, target: "target", text: "Please review.")
        result.lock.withLock { result.response = response }
    }
    let deadline = Date().addingTimeInterval(3)
    while fixture.broker.contextReviews().first(where: { $0.id == draft.id })?.state != .awaitingReview, Date() < deadline { usleep(10_000) }
    let awaiting = try lowRequire(fixture.broker.contextReviews().first { $0.id == draft.id }, "the draft disappeared")
    try lowExpect(awaiting.state == .awaitingReview, "the agent's Ask never awaited review")
    _ = fixture.broker.approveContextReview(reviewID: draft.id, pack: awaiting.pack, targetPaneID: "target")
    let finishDeadline = Date().addingTimeInterval(5)
    while result.lock.withLock({ result.response }) == nil, Date() < finishDeadline { usleep(10_000) }
    let response = try lowRequire(result.lock.withLock { result.response }, "the agent's context Ask never returned")
    try lowExpect(response.status != 200, "a context Ask to a busy target was delivered")
    let after = try lowRequire(fixture.broker.contextReviews().first { $0.id == draft.id }, "the review disappeared")
    try lowExpect(after.state == .draft && (after.detail ?? "").hasPrefix("Not sent"),
                  "a context Ask refused before delivery was left \(after.state) (\(after.detail ?? "")) instead of a draft")
}

/// A late answer was always refused as "timed out", even when the Ask had
/// failed because the target's pane closed.
func checkLateAnswerNamesTheRealFailure() throws {
    let fixture = try ContextFixture("lateanswer")
    defer { fixture.cleanup() }
    final class Result: @unchecked Sendable { let lock = NSLock(); var response: RelayTextResponse? }
    let result = Result()
    let token = fixture.sourceToken
    Thread.detachNewThread {
        let response = fixture.broker.handleAsk(token: token, target: "target", text: "Are you there?", idempotencyKey: "low-late")
        result.lock.withLock { result.response = response }
    }
    let deadline = Date().addingTimeInterval(3)
    while fixture.broker.consultations().isEmpty, Date() < deadline { usleep(10_000) }
    let consultation = try lowRequire(fixture.broker.consultations().first, "the Ask never waited")
    // The target's pane dies: the Ask fails for that reason, well before its timeout.
    fixture.panes.lock.withLock { fixture.panes.panes = fixture.panes.panes.map { var pane = $0; if pane.id == "target" { pane.isDead = true }; return pane } }
    let failDeadline = Date().addingTimeInterval(3)
    while result.lock.withLock({ result.response }) == nil, Date() < failDeadline { usleep(10_000) }
    try lowExpect(result.lock.withLock { result.response }?.status == 410, "the Ask did not fail when its target's pane closed")
    // The pane comes back and its agent answers late.
    fixture.panes.lock.withLock { fixture.panes.panes = fixture.panes.panes.map { var pane = $0; pane.isDead = false; return pane } }
    let late = fixture.broker.handleAnswer(token: try fixture.credentials.token(for: "target"), consultationID: consultation.id, text: "Here now.")
    try lowExpect(late.status != 200, "a late answer was accepted")
    try lowExpect(!late.text.contains("timed out") && late.text.contains("pane closed"),
                  "the late answer was not told the real reason the Ask ended: \(late.text)")
}

/// A context Ask that timed out waiting for approval was saved with `try?`:
/// a failed save was dropped, so after a restart the store still showed a
/// pending approval nobody could answer. It goes through the path that keeps
/// the failure and retries it.
func checkContextAskTimeoutIsPersistedOrRetried() throws {
    let fixture = try ContextFixture("ctxtimeout", consultationTimeout: 1)
    defer { fixture.cleanup() }
    let draft = try fixture.stage("timeout")
    let token = fixture.sourceToken
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = fixture.broker.handleContextAsk(token: token, draftID: draft.id, target: "target", text: "Please review.")
        finished.signal()
    }
    let deadline = Date().addingTimeInterval(3)
    while fixture.broker.contextReviews().first(where: { $0.id == draft.id })?.state != .awaitingReview, Date() < deadline { usleep(10_000) }
    // The store refuses to write while the timeout lands: its own check
    // rejects a file that is not owner-only (it re-protects its directory,
    // so a read-only directory would not do).
    let storeFile = fixture.directory.appendingPathComponent("context-reviews.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeFile.path)
    try lowExpect(finished.wait(timeout: .now() + 5) == .success, "the context Ask never timed out")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeFile.path)
    // Reading reviews retries a save that failed.
    _ = fixture.broker.contextReviews()
    let reloaded = try AgentContextReviewStore(file: fixture.directory.appendingPathComponent("context-reviews.json")).reviews()
    try lowExpect(reloaded.first { $0.id == draft.id }?.state == .failed,
                  "the timed-out context Ask was never saved: the store still says \(String(describing: reloaded.first { $0.id == draft.id }?.state))")
}

/// The store keeps at most 100 reviews, but the broker's own map kept every
/// one, so Status Center listed reviews the store had already dropped.
func checkBrokerForgetsReviewsTheStorePruned() throws {
    let fixture = try ContextFixture("ctxprune")
    defer { fixture.cleanup() }
    for index in 0..<106 {
        let draft = try fixture.stage("pruned-\(index)")
        try lowExpect(fixture.broker.discardContextDraft(token: fixture.sourceToken, draftID: draft.id).status < 300, "draft \(index) could not be discarded")
    }
    let kept = try AgentContextReviewStore(file: fixture.directory.appendingPathComponent("context-reviews.json")).reviews().count
    let listed = fixture.broker.contextReviews().count
    try lowExpect(kept <= 100, "the store kept \(kept) reviews")
    try lowExpect(listed == kept, "the broker lists \(listed) reviews while the store keeps \(kept)")
}

/// Every broker change wakes every parked waiter, and each one read the
/// workbench's panes (and, for an Ask, the credential file under its lock) on
/// every wake: with many waiters, a busy broker multiplied that work. A waiter
/// checks liveness at most once per poll interval however often it is woken.
func checkWaitersCheckLivenessOncePerInterval() throws {
    let fixture = try ContextFixture("wakeups", consultationTimeout: 20, livenessPollInterval: 0.5)
    defer { fixture.cleanup() }
    let broker = fixture.broker
    let token = fixture.sourceToken
    let targetToken = try fixture.credentials.token(for: "target")
    func burst() throws -> Int {
        Thread.sleep(forTimeInterval: 0.6) // the waiter's first check is behind it
        let before = fixture.panes.lock.withLock { fixture.panes.reads }
        for _ in 0..<300 {
            _ = try broker.recordActivity(RelayActivityEventRequest(kind: .workspaceCreated, workspaceID: "@low", workspaceName: "Low"))
        }
        Thread.sleep(forTimeInterval: 0.1)
        return fixture.panes.lock.withLock { fixture.panes.reads } - before
    }

    // An Ask waiting for its answer.
    let asked = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = broker.handleAsk(token: token, target: "target", text: "Waiting.", idempotencyKey: "low-wakeups")
        asked.signal()
    }
    let deadline = Date().addingTimeInterval(3)
    while broker.consultations().isEmpty, Date() < deadline { usleep(10_000) }
    let consultation = try lowRequire(broker.consultations().first, "the Ask never waited")
    let askReads = try burst()
    _ = broker.handleAnswer(token: targetToken, consultationID: consultation.id, text: "Answered.")
    _ = asked.wait(timeout: .now() + 5)
    try lowExpect(askReads <= 3, "a waiting Ask read the panes \(askReads) times during 300 broker changes")

    // A `parley wait` on a delegation.
    let delegated = broker.handleDelegate(token: token, target: "target", text: "Work.", idempotencyKey: "low-wakeups-delegate")
    let handoffID = try lowRequire(delegated.body.handoffID, "the delegation returned no id")
    let waited = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = broker.waitForTrackedWork(token: token, handoffID: handoffID)
        waited.signal()
    }
    let waitReads = try burst()
    _ = broker.handleDelegationResult(token: targetToken, handoffID: handoffID, text: "Done.", succeeded: true)
    _ = waited.wait(timeout: .now() + 5)
    try lowExpect(waitReads <= 3, "a waiting delegation read the panes \(waitReads) times during 300 broker changes")
}

private func lowRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "RelayJournalLow", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

@MainActor let relayJournalLowChecks: [(String, () throws -> Void)] = [
    ("a refused context ask returns to a draft", checkRefusedContextAskReturnsToDraft),
    ("a late answer names the real failure", checkLateAnswerNamesTheRealFailure),
    ("a context ask timeout is persisted or retried", checkContextAskTimeoutIsPersistedOrRetried),
    ("the broker forgets reviews the store pruned", checkBrokerForgetsReviewsTheStorePruned),
    ("waiters check liveness once per interval", checkWaitersCheckLivenessOncePerInterval),
    ("owner-only files are written durably and never left half-committed", checkOwnerOnlyFileWrite),
    ("the busy queue is never visible with wider permissions", checkBusyQueueIsNeverVisibleWithWiderPermissions),
]
