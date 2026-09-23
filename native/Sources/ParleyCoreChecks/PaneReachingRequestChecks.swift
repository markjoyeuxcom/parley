import Dispatch
import Foundation
import ParleyCore

private func reachExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "PaneReachingRequest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func reachRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "PaneReachingRequest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// Runs `work` on another thread while the main run loop keeps turning, the
/// way the app's main thread does, so the core's `DispatchQueue.main.sync`
/// hop can be serviced.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    var result: Result<T, Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func offMain<T: Sendable>(within seconds: Double, _ work: @escaping @Sendable () throws -> T) throws -> T {
    try reachExpect(Thread.isMainThread, "this check only means something on the main thread")
    let box = ResultBox<T>()
    Thread { box.result = Result { try work() } }.start()
    let deadline = Date().addingTimeInterval(seconds)
    while box.result == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return try reachRequire(box.result, "the request did not return within \(seconds) s").get()
}

/// Review of 22 September 2026, M3: Retry Delivery and trusted capture into
/// an agent draft called the core on the main thread with a 3 s timeout,
/// while the core reaches the pane through `DispatchQueue.main.sync`. The UI
/// froze, reported failure, and the delivery or capture then happened
/// anyway. The client must refuse any request whose route reaches a pane on
/// the main thread, however short, and allow the core's slowest path.
func checkPaneReachingRequestsAreRefusedOnTheMainThread() throws {
    try reachExpect(Thread.isMainThread, "this check only means something on the main thread")
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-reach-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // No core is listening: a request that gets past the guard fails to connect.
    let client = RelayCoreClient(infoFile: root.appendingPathComponent("relay.json"), controlToken: "reach-control")
    let requests: [(String, @Sendable () throws -> RelayTextResponse)] = [
        ("retry", { try client.retryHandoff("00000000-0000-0000-0000-000000000000") }),
        ("trusted capture", { try client.captureTrustedContext(AgentContextTrustedCaptureRequest(reviewID: "review", kind: .visibleTerminal, paneID: "pane")) }),
    ]
    for (name, request) in requests {
        var onMain: Error?
        do { _ = try request() } catch { onMain = error }
        guard case RelayCoreError.mainThreadBlockingRequest? = onMain else {
            throw NSError(domain: "PaneReachingRequest", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(name) on the main thread was not refused: \(onMain.map { String(describing: $0) } ?? "it returned")"])
        }
        var offMainError: Error?
        do { _ = try offMain(within: 10, request) } catch { offMainError = error }
        if case RelayCoreError.mainThreadBlockingRequest? = offMainError {
            throw NSError(domain: "PaneReachingRequest", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) was refused off the main thread"])
        }
    }
}

/// The same two routes through a real control socket, with a pane that takes
/// longer than the old 3 s receive timeout and answers only through the main
/// thread: both must return their real result, not a timeout that hides a
/// delivery or capture that happened.
func checkSlowPaneReachingRequestsReturnTheirResult() throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-reach-\(UUID().uuidString.prefix(8))")
    let folder = directory.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: folder.path, currentCommand: "x", isActive: false,
                      workspaceID: "@reach", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Reach", inputAvailable: true)
    }
    let source = pane("source", .claude), target = pane("target", .codex)
    let sourceToken = try credentials.token(for: source.id)
    final class Pane: @unchecked Sendable {
        let lock = NSLock()
        var refuseNext = true
        var delivered: [String] = []
    }
    let state = Pane()
    let slow: TimeInterval = 4
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, target] },
        paste: { _, _ in },
        submit: { _, text in
            if state.lock.withLock({ () -> Bool in defer { state.refuseNext = false }; return state.refuseNext }) {
                throw ParleyWorkbenchError.unsafeRelayTarget("not ready yet")
            }
            // The real writer reaches Ghostty on the main thread.
            DispatchQueue.main.sync {
                Thread.sleep(forTimeInterval: slow)
                state.lock.withLock { state.delivered.append(text) }
            }
        },
        selectedText: { _ in
            DispatchQueue.main.sync {
                Thread.sleep(forTimeInterval: slow)
                return "the selected lines"
            }
        },
        contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: "reach-control")
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(infoFile: infoFile, controlToken: "reach-control")

    // Retry Delivery of a relay whose first attempt never started input.
    let first = broker.handle(token: sourceToken, target: target.id, text: "Please look.")
    let handoffID = try reachRequire(first.body.handoffID, "the relay returned no handoff id")
    try reachExpect(broker.handoffs().first { $0.id == handoffID }?.canRetrySafely == true, "the refused relay is not safely retryable")
    let retried = try offMain(within: slow + 20) { try client.retryHandoff(handoffID) }
    try reachExpect(retried.status == 200, "a slow retry reported \(retried.status): \(retried.text)")
    try reachExpect(state.lock.withLock { state.delivered.count } == 1, "the retry did not deliver exactly once")

    // Trusted capture of a pane's selection into an agent-staged draft.
    let staged = folder.appendingPathComponent("notes.md")
    try "# Notes\n".write(to: staged, atomically: true, encoding: .utf8)
    let draft = broker.handleContextDraft(token: sourceToken, name: "Notes", path: staged.path, text: "# Notes\n")
    try reachExpect(draft.status == 201, "the agent draft was not staged: \(draft.text)")
    let review = try reachRequire(broker.contextReviews().first, "the staged draft is missing")
    let captured = try offMain(within: slow + 20) {
        try client.captureTrustedContext(AgentContextTrustedCaptureRequest(reviewID: review.id, kind: .visibleTerminal, paneID: target.id))
    }
    try reachExpect(captured.status == 200, "a slow selection capture reported \(captured.status): \(captured.text)")
    let parts = try JSONDecoder().decode(AgentContextTrustedCaptureResponse.self, from: Data(captured.text.utf8)).parts
    try reachExpect(parts.count == 1 && parts[0].text.contains("the selected lines"), "the capture did not return the selection")
}

@MainActor let paneReachingRequestChecks: [(String, () throws -> Void)] = [
    ("pane-reaching requests are refused on the main thread", checkPaneReachingRequestsAreRefusedOnTheMainThread),
    ("slow pane-reaching requests return their result", checkSlowPaneReachingRequestsReturnTheirResult),
]
