import Foundation
import ParleyCore

private func purgeExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ContextPurge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class PurgeFixture: @unchecked Sendable {
    let directory: URL
    let file: URL
    let credentials: RelayCredentials
    let store: AgentContextReviewStore
    let broker: RelayBroker
    let sourceToken: String
    let targetToken: String

    init() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("purge-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("context-reviews.json")
        credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
        sourceToken = try credentials.token(for: "source")
        targetToken = try credentials.token(for: "target")
        store = try AgentContextReviewStore(file: file)
        let panes = [
            WorkbenchPane(id: "source", kind: .codex, customName: "Builder", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: true, workspaceID: "workspace-a", relayEnabled: true, workspaceName: "Project", automationPolicy: .askAndDelegate),
            WorkbenchPane(id: "target", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: false, workspaceID: "workspace-b", relayEnabled: true, workspaceName: "Project", automationPolicy: .askAndDelegate),
        ]
        broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in },
            consultationTimeout: 3, handoffJournal: try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl")), contextReviewStore: store)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func returnedFile() throws -> AgentContextReview {
        let path = directory.appendingPathComponent("report.md")
        try "unique-returned-content".write(to: path, atomically: true, encoding: .utf8)
        let delegated = broker.handleDelegate(token: sourceToken, target: "Reviewer", text: "Review")
        try purgeExpect(delegated.status == 200, "could not delegate: \(delegated.body)")
        let returned = broker.handleDelegationFileResult(token: targetToken, handoffID: "current", path: path.path, text: "unique-returned-content")
        try purgeExpect(returned.status == 200, "could not return file: \(returned.text)")
        return broker.contextReviews().first!
    }

    func draft(token: String? = nil) throws -> AgentContextReview {
        let response = broker.handleContextDraft(token: token ?? sourceToken, name: "Draft", path: directory.appendingPathComponent("draft.md").path, text: "unique-draft-content")
        try purgeExpect(response.status == 201, "could not stage draft: \(response.text)")
        let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(response.text.utf8))
        return broker.contextReviews().first { $0.id == summary.id }!
    }
}

@MainActor
let contextPurgeChecks: [(String, () throws -> Void)] = [
    ("context purge: Clear History erases retained copies and keeps original project files", {
        let fixture = try PurgeFixture()
        _ = try fixture.returnedFile()
        let draft = try fixture.draft()
        let discard = fixture.broker.discardContextDraft(AgentContextDraftDiscard(reviewID: draft.id, expectedUpdatedAt: draft.updatedAt))
        try purgeExpect(discard.status == 200, "could not discard fixture draft")
        let response = fixture.broker.deleteAllHistory()
        try purgeExpect(response.status == 200, "clear failed: \(response.text)")
        try purgeExpect(fixture.broker.contextReviews().isEmpty, "Clear History retained context text in the running broker")
        try purgeExpect(fixture.store.reviews().isEmpty, "Clear History retained context in the store's memory")
        try purgeExpect(AgentContextReviewStore(file: fixture.file).reviews().isEmpty, "context reappeared after loading from disk")
        let saved = try String(contentsOf: fixture.file, encoding: .utf8)
        try purgeExpect(!saved.contains("unique-"), "the persisted JSON still contains deleted text")
        try purgeExpect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("report.md").path), "purge deleted an original project file")
        _ = try fixture.draft()
        try purgeExpect(!String(contentsOf: fixture.file, encoding: .utf8).contains("unique-returned-content"), "a later save resurrected returned text")
    }),
    ("context purge: workspace scope uses durable identity even for closed workspaces", {
        let fixture = try PurgeFixture()
        let returned = try fixture.returnedFile()
        let sourceDraft = try fixture.draft()
        let otherDraft = try fixture.draft(token: fixture.targetToken)
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as! [String: Any]
        var reviews = document["reviews"] as! [[String: Any]]
        let legacyIndex = reviews.firstIndex { $0["id"] as? String == returned.id }!
        reviews[legacyIndex].removeValue(forKey: "sourceWorkspaceID")
        reviews[legacyIndex].removeValue(forKey: "sourceWorkspaceName")
        document["reviews"] = reviews
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.file)
        // No live panes: a closed workspace must still be addressable by its
        // recorded ID. Both old workspaces deliberately share the same name.
        let reloaded = RelayBroker(credentials: fixture.credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in },
            handoffJournal: try RelayHandoffJournal(file: fixture.directory.appendingPathComponent("handoffs.jsonl")),
            contextReviewStore: try AgentContextReviewStore(file: fixture.file))
        let cleared = reloaded.deleteWorkspaceHistory(workspaceID: "workspace-a", workspaceName: "Project")
        try purgeExpect(cleared.status == 200, "scoped clear failed")
        let remaining = reloaded.contextReviews().map(\.id)
        try purgeExpect(!remaining.contains(sourceDraft.id) && !remaining.contains(returned.id), "closed-workspace context or linked returned file survived")
        try purgeExpect(remaining == [otherDraft.id], "scope erased context from a different workspace with the same name")
    }),
    ("context purge: native deletion validates revisions and persists an empty store", {
        let fixture = try PurgeFixture()
        let first = try fixture.returnedFile()
        let second = try fixture.draft()
        func deletion(_ values: [(AgentContextReview, Date)]) -> AgentContextDeletion {
            AgentContextDeletion(reviews: values.map { AgentContextDraftDiscard(reviewID: $0.0.id, expectedUpdatedAt: $0.1) })
        }
        let info = fixture.directory.appendingPathComponent("core")
        let server = RelayHTTPServer(broker: fixture.broker, infoFile: info, controlToken: "purge-control")
        try server.start()
        defer { server.stop() }
        let native = RelayCoreClient(infoFile: info, controlToken: "purge-control", allowsTrackedRequestsOnMainThread: true)
        let agent = RelayCoreClient(infoFile: info, controlToken: fixture.sourceToken, allowsTrackedRequestsOnMainThread: true)
        let current = deletion([(first, first.updatedAt), (second, second.updatedAt)])
        try purgeExpect(agent.deleteContextReviews(current).status == 401, "a pane credential erased saved context")
        let stale = deletion([(first, first.updatedAt), (second, second.updatedAt.addingTimeInterval(-1))])
        try purgeExpect(native.deleteContextReviews(stale).status == 409, "a stale revision was accepted")
        try purgeExpect(fixture.broker.contextReviews().count == 2, "a failed batch partially deleted its selection")
        try purgeExpect(native.deleteContextReviews(AgentContextDeletion(reviews: [])).status == 400, "empty selection widened into delete-all")
        try purgeExpect(native.deleteContextReviews(current).status == 200, "native deletion failed")
        try purgeExpect(fixture.broker.contextReviews().isEmpty && fixture.store.reviews().isEmpty, "deleted records survived in memory")
        try purgeExpect(AgentContextReviewStore(file: fixture.file).reviews().isEmpty, "deleted records survived on disk")
        try purgeExpect(fixture.broker.handoffs().count == 1, "context deletion erased the associated handoff receipt")
    }),
    ("context purge: write failure preserves records for retry", {
        let fixture = try PurgeFixture()
        let review = try fixture.returnedFile()
        let deletion = AgentContextDeletion(reviews: [AgentContextDraftDiscard(reviewID: review.id, expectedUpdatedAt: review.updatedAt)])
        // Invalid permissions force the existing store's validation to refuse
        // the mutation without depending on the test process's privileges.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
        try purgeExpect(fixture.broker.deleteContextReviews(deletion).status == 500, "an unsafe store claimed successful deletion")
        try purgeExpect(fixture.broker.contextReviews() == [review] && fixture.store.reviews() == [review], "failed deletion erased the in-memory record")
        try purgeExpect(fixture.broker.deleteAllHistory().status == 500, "history clear hid a context purge failure")
        try purgeExpect(fixture.broker.handoffs().count == 1, "failed context purge lost its handoff association")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        try purgeExpect(fixture.broker.deleteAllHistory().status == 200, "retry failed after storage was repaired")
        try purgeExpect(AgentContextReviewStore(file: fixture.file).reviews().isEmpty, "retry did not erase disk content")
    }),
    ("context purge: Clear History also forgets finished command results held for recovery", {
        let fixture = try PurgeFixture()
        fixture.broker.enableReviewedCommandRuns()
        let coordinator = fixture.broker.commandRuns!
        let run = try coordinator.request(token: fixture.sourceToken, argv: ["/usr/bin/true"], folder: fixture.directory.path)
        try coordinator.reject(id: run.id, revision: run.revision)
        try purgeExpect(fixture.broker.deleteAllHistory().status == 200, "history clear failed")
        try purgeExpect(!coordinator.owns(id: run.id), "cleared command history stayed in the recovery cache")
        var replayRefused = false
        do {
            _ = try coordinator.request(token: fixture.sourceToken, argv: ["/usr/bin/true"], folder: fixture.directory.path, idempotencyKey: run.idempotencyKey)
        } catch { replayRefused = true }
        try purgeExpect(replayRefused, "deleting a result made the same command request executable again")
    }),
    ("context purge: waiting approvals and approved Ask deliveries survive deletion", {
        let fixture = try PurgeFixture()
        let original = try fixture.draft()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = fixture.broker.handleContextAsk(token: fixture.sourceToken, draftID: original.id,
                target: "Reviewer", text: "Review this context", idempotencyKey: "purge-waiting-ask")
            finished.signal()
        }
        func waitUntil(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(2)
            while !condition() {
                try purgeExpect(Date() < deadline, "context Ask did not reach the expected state")
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try waitUntil { fixture.broker.contextReviews().first?.state == .awaitingReview }
        func deletion(_ review: AgentContextReview) -> AgentContextDeletion {
            AgentContextDeletion(reviews: [AgentContextDraftDiscard(reviewID: review.id, expectedUpdatedAt: review.updatedAt)])
        }
        let waiting = fixture.broker.contextReviews()[0]
        try purgeExpect(fixture.broker.deleteContextReviews(deletion(original)).status == 409, "a stale draft deletion cancelled a waiting Ask")
        try purgeExpect(fixture.broker.deleteContextReviews(deletion(waiting)).status == 409, "a current revision could erase a waiting Ask")
        try purgeExpect(fixture.broker.deleteAllHistory().status == 200, "history could not clear around a waiting Ask")
        try purgeExpect(fixture.broker.contextReviews()[0].state == .awaitingReview, "history clearing declined a waiting approval")
        try purgeExpect(fixture.broker.approveContextReview(reviewID: waiting.id, pack: waiting.pack, targetPaneID: "target").status == 200, "approval failed after clearing history")
        try waitUntil { !fixture.broker.consultations().isEmpty }
        let approved = fixture.broker.contextReviews()[0]
        try purgeExpect(approved.state == .approved, "fixture did not retain an approved delivery")
        try purgeExpect(fixture.broker.deleteContextReviews(deletion(approved)).status == 409, "an approved delivery was erased")
        try purgeExpect(fixture.broker.deleteAllHistory().status == 200, "history clear failed around an approved delivery")
        try purgeExpect(fixture.broker.contextReviews().count == 1 && fixture.broker.handoffs().count == 1, "clear erased active context or its handoff")
        try purgeExpect(fixture.broker.handleAnswer(token: fixture.targetToken, consultationID: "current", text: "Review returned").status == 200, "preserved Ask could not be answered")
        try purgeExpect(finished.wait(timeout: .now() + 3) == .success, "context Ask did not finish")
        try purgeExpect(fixture.broker.contextReviews()[0].state == .completed, "context Ask completion was lost")
        try purgeExpect(fixture.broker.deleteAllHistory().status == 200, "completed context could not be purged")
        try purgeExpect(fixture.store.reviews().isEmpty, "completed context remained on disk")
    }),
]
