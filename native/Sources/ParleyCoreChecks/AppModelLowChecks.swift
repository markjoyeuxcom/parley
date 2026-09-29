import Dispatch
import Foundation
import ParleyCore

// Low findings in the app model, from the review of 22 September 2026 (35814533).

private func modelExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "AppModelLow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func modelFailure(_ message: String) -> NSError {
    NSError(domain: "AppModelLow", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

private func appSource(_ folder: String, _ file: String) throws -> SwiftSourceReader {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
}

/// The body of `func <name>(` in the reader's text.
private func functionBody(_ reader: SwiftSourceReader, _ signature: String) throws -> Substring {
    guard let found = reader.text.range(of: signature),
          let open = reader.text[found.upperBound...].firstIndex(of: "{"),
          let body = reader.balanced(at: open) else { throw modelFailure("\(signature) was not found") }
    return body
}

/// Ranges of every `Task.detached(...) { ... }` closure body in the text.
private func detachedClosures(_ reader: SwiftSourceReader) -> [Range<String.Index>] {
    let text = reader.text
    var ranges: [Range<String.Index>] = []
    var search = text.startIndex..<text.endIndex
    while let call = text.range(of: "Task.detached(", range: search) {
        search = call.upperBound..<text.endIndex
        guard let arguments = reader.balanced(at: text.index(before: call.upperBound)) else { continue }
        let afterArguments = text.index(after: arguments.endIndex)
        guard let open = text[afterArguments...].firstIndex(where: { !$0.isWhitespace }), text[open] == "{",
              let body = reader.balanced(at: open) else { continue }
        ranges.append(body.startIndex..<body.endIndex)
    }
    return ranges
}

/// Review Changes ran up to five Git processes, 5 s each, on the main actor
/// (Add Git Diff was already moved off it). Every repository read the app
/// model starts for a review or a context pack runs in a detached task.
func checkRepositoryReadsLeaveTheMainActor() throws {
    let reader = try appSource("ParleyNative", "AppModel.swift")
    let closures = detachedClosures(reader)
    let calls = try NSRegularExpression(pattern: "\\.(changes|gitDiff)\\(in:")
    let text = reader.text
    let matches = calls.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    try modelExpect(matches.count >= 2, "the review and context Git reads were not found in AppModel")
    let onMain = matches.filter { match in !closures.contains { $0.contains(match.lowerBound) } }
    let lines = onMain.map { text[..<$0.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count }
    try modelExpect(onMain.isEmpty, "a repository read runs on the main actor at stripped line(s) \(lines)")
}

private final class ModelPanes: @unchecked Sendable {
    let lock = NSLock()
    var panes: [WorkbenchPane]
    init(_ panes: [WorkbenchPane]) { self.panes = panes }
    var current: [WorkbenchPane] { lock.withLock { panes } }
}

private func modelPane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: "/private/\(id)", currentCommand: kind.rawValue,
                  isActive: false, workspaceID: "@model", relayEnabled: true, protocolVersion: AgentProtocol.version,
                  workspaceName: "Model", inputAvailable: true, automationPolicy: .askAndDelegate)
}

/// A voice send refused before any input (Copilot's folder trust, a delivery
/// already in progress) was shown as "Check delivery in the pane", which
/// offers only copy or discard. The same classification decides whether the
/// broker offers a safe Retry, and there the registry's failures after the
/// paste used the "not ready" error, so a Retry could paste the text twice.
func checkDeliveryRefusalsBeforeInputAreKnown() throws {
    // One classification, by error type.
    let refusals: [Error] = [ParleyWorkbenchError.copilotTrustRequired, ParleyWorkbenchError.unsafeRelayTarget("Codex"),
                             ParleyWorkbenchError.paneNotFound("p"), ParleyWorkbenchError.noRelayText, ParleyWorkbenchError.deliveryInProgress,
                             VoiceError.unavailable("changed")]
    for refused in refusals {
        try modelExpect(ParleyWorkbenchError.refusedBeforeInput(refused), "\(refused) was not recognised as a refusal before input")
    }
    let started: [Error] = [ParleyWorkbenchError.deliveryInterrupted("Codex", reason: "fixture"), ParleyWorkbenchError.commandFailed("x"), NSError(domain: "other", code: 1)]
    for started in started {
        try modelExpect(!ParleyWorkbenchError.refusedBeforeInput(started), "\(started) was taken for a refusal before input")
    }

    // The voice session keeps the draft reviewable after a refusal before input.
    var session = VoiceSession()
    session.deliveryFailed(ParleyWorkbenchError.copilotTrustRequired, afterAttempt: true)
    try modelExpect(session.phase == .review, "a Copilot trust refusal left voice delivery uncertain")
    session.deliveryFailed(ParleyWorkbenchError.deliveryInProgress, afterAttempt: true)
    try modelExpect(session.phase == .review, "a delivery already in progress left voice delivery uncertain")
    session.deliveryFailed(ParleyWorkbenchError.deliveryInterrupted("Codex", reason: "fixture"), afterAttempt: true)
    try modelExpect(session.phase == .deliveryUncertain && session.message?.contains("Inspect the destination") == true,
                    "a failure after the paste was not reported as uncertain")
    session.deliveryFailed(NSError(domain: "unknown", code: 1), afterAttempt: false)
    try modelExpect(session.phase == .review, "a failure before the attempt was reported as uncertain")

    // The app hands the error itself to the session, which classifies it.
    let model = try functionBody(try appSource("ParleyNative", "AppModel.swift"), "func deliverVoice(submit: Bool)")
    try modelExpect(model.contains("voice.session.deliveryFailed(error, afterAttempt: attempted)") && !model.contains("mayHaveDelivered:"),
                    "deliverVoice decides \"may have delivered\" without classifying the error")

    // The controller raises exactly those refusals on the voice path.
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-voice-refusal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    controller.configureRelay(RelayRuntime(infoFile: root.appendingPathComponent("runtime/relay-url"), shimDirectory: root.appendingPathComponent("runtime/bin"),
        transportDirectory: root.appendingPathComponent("runtime/relay"), credentials: try RelayCredentials(file: root.appendingPathComponent("runtime/relay-tokens.json")), runtimeMarker: "DEV"))
    var nested: Error?
    var deliveries = 0
    var reenter: (() -> Void)?
    controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, voicePaste: { _, _, _, _ in
        deliveries += 1
        reenter?()
    }, interrupt: { _ in }, captureSelectedText: { _ in "" }, terminate: { _ in }, terminateAll: {}))
    _ = try controller.createWorkspace(folder: root.appendingPathComponent("project").path)
    let copilot = try controller.createPane(kind: .copilot, cwd: root.appendingPathComponent("project").path)
    try controller.terminalDidAttach(paneID: copilot.id)
    let live = try controller.listPanes().first { $0.id == copilot.id }!
    let destination = VoiceDestination(pane: live)
    do {
        try controller.pasteVoice("hello", destination: destination, submit: true)
        throw modelFailure("an untrusted Copilot pane accepted voice input")
    } catch {
        try modelExpect(ParleyWorkbenchError.refusedBeforeInput(error) && deliveries == 0, "Copilot's trust refusal was not a refusal before input: \(error)")
    }
    try controller.confirmCopilotFolderTrust(paneID: copilot.id, expectedGeneration: live.launchGeneration, expectedFolder: live.cwd)
    reenter = {
        do { try controller.pasteVoice("again", destination: destination, submit: true) } catch { nested = error }
    }
    try controller.pasteVoice("hello", destination: destination, submit: true)
    try modelExpect(deliveries == 1, "a delivery nested inside another reached the pane")
    guard let nested else { throw modelFailure("a nested delivery to the same pane was not refused") }
    try modelExpect(nested as? ParleyWorkbenchError == .deliveryInProgress && ParleyWorkbenchError.refusedBeforeInput(nested),
                    "a delivery already in progress was not refused before input: \(nested)")
}

/// The broker offers Retry Delivery only when input never began. A refusal
/// because another delivery was in progress is one; an interruption after the
/// paste is not, whatever error it carries.
func checkBrokerRetriesOnlyDeliveriesThatNeverStarted() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-model-retry-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "source")
    _ = try credentials.token(for: "target")
    let panes = ModelPanes([modelPane("source", .agy, "Agy"), modelPane("target", .codex, "Codex")])
    let failures = ModelFailures()
    let broker = RelayBroker(credentials: credentials, panes: { panes.current }, paste: { _, _ in },
                             submit: { _, _ in if let failure = failures.next() { throw failure } })
    failures.set([ParleyWorkbenchError.deliveryInProgress, ParleyWorkbenchError.deliveryInterrupted("Codex", reason: "fixture")])
    let refused = broker.handle(token: sourceToken, target: "codex", text: "First.", idempotencyKey: "model-in-progress")
    let refusedRecord = broker.handoffs().first { $0.id == refused.body.handoffID }
    try modelExpect(refusedRecord?.retryDisposition == .safe, "a delivery refused as in progress was not safe to retry")
    let interrupted = broker.handle(token: sourceToken, target: "codex", text: "Second.", idempotencyKey: "model-interrupted")
    let interruptedRecord = broker.handoffs().first { $0.id == interrupted.body.handoffID }
    try modelExpect(interruptedRecord?.retryDisposition == .uncertain && interruptedRecord?.canRetrySafely == false,
                    "a delivery interrupted after its paste was offered a retry")
}

private final class ModelFailures: @unchecked Sendable {
    let lock = NSLock()
    var queue: [Error] = []
    func set(_ errors: [Error]) { lock.withLock { queue = errors } }
    func next() -> Error? { lock.withLock { queue.isEmpty ? nil : queue.removeFirst() } }
}

/// After the text is in the pane, a failure (the pane went away before Enter,
/// Enter refused, the reviewed voice destination changed) is an interruption:
/// the registry used "not ready" for these, which the broker reads as input
/// never having begun. The steps run here as the registry runs them, with
/// each one scripted to fail in turn.
func checkRegistryFailuresAfterThePasteAreInterruptions() throws {
    func run(submit: Bool = true, failLive: Int? = nil, failValidate: Int? = nil, pasteWrites: Bool = true, enterWorks: Bool = true)
        -> (log: [String], error: Error?) {
        var log: [String] = []
        var liveCalls = 0, validateCalls = 0
        let steps = PaneInputDelivery.Steps(
            settle: { log.append("settle \($0)") },
            requireLive: {
                liveCalls += 1; log.append("live")
                if liveCalls == failLive { throw ParleyWorkbenchError.unsafeRelayTarget("pane") }
            },
            validate: {
                validateCalls += 1; log.append("validate")
                if validateCalls == failValidate { throw VoiceError.unavailable("the destination changed") }
            },
            paste: { log.append("paste \($0)"); return pasteWrites },
            enter: { log.append("enter"); return enterWorks })
        do {
            try PaneInputDelivery.deliver("hello", into: "pane", name: "Codex", submit: submit,
                timing: PaneSubmissionTiming(afterFocus: 0.1, afterPaste: 0.25, beforeRestoringFocus: 0.1), steps: steps)
            return (log, nil)
        } catch { return (log, error) }
    }
    let delivered = run()
    try modelExpect(delivered.error == nil && delivered.log == ["settle 0.1", "live", "validate", "paste hello", "settle 0.25", "live", "validate", "enter"],
                    "a delivery ran its steps as \(delivered.log)")
    let pasteOnly = run(submit: false)
    try modelExpect(pasteOnly.error == nil && pasteOnly.log == ["settle 0.1", "live", "validate", "paste hello"],
                    "a paste without Enter ran \(pasteOnly.log)")
    for (name, result) in [("a pane gone before the paste", run(failLive: 1)), ("a destination changed before the paste", run(failValidate: 1)),
                           ("a surface that took no text", run(pasteWrites: false))] {
        guard let error = result.error else { throw modelFailure("\(name) delivered") }
        try modelExpect(ParleyWorkbenchError.refusedBeforeInput(error) && !result.log.contains("enter"),
                        "\(name) was not a refusal before input: \(error)")
    }
    try modelExpect(!run(failLive: 1).log.contains { $0.hasPrefix("paste") }, "text was pasted into a pane that had gone")
    for (name, result) in [("a pane gone before Enter", run(failLive: 2)), ("a destination changed before Enter", run(failValidate: 2)),
                           ("Enter refused", run(enterWorks: false))] {
        guard let error = result.error else { throw modelFailure("\(name) delivered") }
        guard case ParleyWorkbenchError.deliveryInterrupted("Codex", _)? = error as? ParleyWorkbenchError,
              !ParleyWorkbenchError.refusedBeforeInput(error) else {
            throw modelFailure("\(name) after the paste was reported as \(error), not an interruption")
        }
    }
    guard case ParleyWorkbenchError.deliveryInterrupted(_, let reason)? = run(failValidate: 2).error as? ParleyWorkbenchError,
          reason.contains("the destination changed") else { throw modelFailure("an interruption lost its cause") }

    // The registry delivers through exactly these steps.
    let reader = try appSource("ParleyNative", "GhosttyPaneRegistry.swift")
    let body = try functionBody(reader, "private func deliver(_ text: String, to entry: Entry")
    try modelExpect(body.contains("PaneInputDelivery.deliver(") && !body.contains("sendKey(.enter) else")
                    && !body.contains("deliveryInterrupted"), "the registry runs its own delivery steps instead of PaneInputDelivery")
    // And hands it the real steps, not placeholders that would always pass.
    for wiring in ["submit: submit", "timing: timing", "settleTerminalInput(for: $0)", "try requireLiveTarget(paneID, entry)",
                   "validate: validate", "entry.view.paste(text: $0)", "entry.view.sendKey(.enter)"] {
        try modelExpect(body.contains(wiring), "the registry does not pass \(wiring) to PaneInputDelivery")
    }
}

/// Switching the release channel while a check ran showed the Beta result
/// under Stable: the check ran on and published its result.
func checkReleaseChannelChangeDiscardsACheckInFlight() throws {
    let reader = try appSource("ParleyNative", "AppModel.swift")
    let change = try functionBody(reader, "func setReleaseChannel(_ channel: UpdateChannel)")
    try modelExpect(change.contains("releaseTask?.cancel()") && change.contains("releaseChecking = false"),
                    "changing the channel leaves the previous channel's check running")
    let check = try functionBody(reader, "func checkForUpdates()")
    guard let assignment = check.range(of: "self.releaseCheck = result") else { throw modelFailure("checkForUpdates no longer publishes a result") }
    try modelExpect(check[..<assignment.lowerBound].contains("self.releaseChannel == channel"),
                    "a result is published without confirming it is for the current channel")
}

/// Move and Prepare to Uninstall refuse while a handoff is active, and read
/// the 500 most recently updated handoffs to decide. That holds only while
/// history retention (at most 500 finished records, active ones exempt)
/// matches the window: more than 500 active handoffs, or either bound
/// changing, and active work falls outside it. They ask the broker for its
/// active handoffs instead, whatever the history holds.
func checkActiveHandoffsAreReadWhole() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-model-active-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let leadToken = try credentials.token(for: "lead")
    _ = try credentials.token(for: "worker")
    _ = try credentials.token(for: "reader")
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"), maximumHandoffs: 700)
    let panes = ModelPanes([modelPane("lead", .claude, "Lead"), modelPane("worker", .codex, "Worker"), modelPane("reader", .agy, "Reader")])
    let broker = RelayBroker(credentials: credentials, panes: { panes.current }, paste: { _, _ in }, submit: { _, _ in }, handoffJournal: journal)
    let delegated = broker.handleDelegate(token: leadToken, target: "worker", text: "Long work.", idempotencyKey: "model-active-delegation")
    guard let delegationID = delegated.body.handoffID else { throw modelFailure("the fixture delegation failed: \(delegated.status)") }
    for index in 0..<20 {
        let response = broker.handle(token: leadToken, target: "reader", text: "note \(index)", idempotencyKey: "model-active-\(index)")
        try modelExpect(response.status == 200, "fixture relay \(index) failed with \(response.status)")
    }
    try modelExpect(broker.handoffs().count == 21, "the fixture history is not the delegation and twenty relays")
    try modelExpect(broker.activeHandoffs().map(\.id) == [delegationID], "the active listing is not exactly the waiting delegation")
    try modelExpect(RelayHandoffState.allCases.filter(\.isActive) == [.created, .delivered, .waiting, .answered],
                    "the active states changed")

    let infoFile = directory.appendingPathComponent("relay-url")
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: "model-active-control")
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(infoFile: infoFile, controlToken: "model-active-control", allowsTrackedRequestsOnMainThread: true)
    try modelExpect(try client.activeHandoffs().map(\.id) == [delegationID], "the control route did not return the active delegation")

    let reader = try appSource("ParleyNative", "AppModel.swift")
    for signature in ["private func verifiedActiveHandoffCount(", "func prepareToUninstall()"] {
        let body = try functionBody(reader, signature)
        try modelExpect(body.contains(".activeHandoffs()") && !body.contains(".handoffs(limit:"),
                        "\(signature) still decides from the newest 500 handoffs")
    }
}

/// Shells report their working directory at every prompt. An unchanged path
/// used to write the whole state file and refresh the model each time.
func checkUnchangedWorkingDirectoryWritesNothing() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-cwd-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project"), other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    _ = try controller.createWorkspace(folder: project.path)
    let shell = try controller.createPane(kind: .shell, cwd: project.path)
    try modelExpect(try controller.terminalDidChangeWorkingDirectory(paneID: shell.id, path: other.path), "a changed folder was not reported as a change")
    let baseline = controller.persistWriteCount
    for _ in 0..<5 {
        try modelExpect(try !controller.terminalDidChangeWorkingDirectory(paneID: shell.id, path: other.path), "an unchanged folder was reported as a change")
    }
    try modelExpect(controller.persistWriteCount == baseline, "an unchanged folder wrote the state file \(controller.persistWriteCount - baseline) times")
    try modelExpect(try controller.terminalDidChangeWorkingDirectory(paneID: shell.id, path: project.path)
                    && controller.persistWriteCount == baseline + 1, "a changed folder was not written once")
    try modelExpect(try controller.listPanes().first { $0.id == shell.id }?.cwd == project.path, "the changed folder was not applied")

    let reader = try appSource("ParleyNative", "GhosttyPaneRegistry.swift")
    guard let callback = reader.text.range(of: "onWorkingDirectory: {"),
          let body = reader.balanced(at: reader.text.index(before: callback.upperBound)) else {
        throw modelFailure("the registry's working-directory callback was not found")
    }
    try modelExpect(body.contains("== true") && body.contains("onPaneStateChanged"),
                    "the registry refreshes the model for an unchanged folder")
}

@MainActor let appModelLowChecks: [(String, () throws -> Void)] = [
    ("repository reads leave the main actor", checkRepositoryReadsLeaveTheMainActor),
    ("delivery refusals before input are known", checkDeliveryRefusalsBeforeInputAreKnown),
    ("the broker retries only deliveries that never started", checkBrokerRetriesOnlyDeliveriesThatNeverStarted),
    ("registry failures after the paste are interruptions", checkRegistryFailuresAfterThePasteAreInterruptions),
    ("a release channel change discards a check in flight", checkReleaseChannelChangeDiscardsACheckInFlight),
    ("active handoffs are read whole", checkActiveHandoffsAreReadWhole),
    ("an unchanged working directory writes nothing", checkUnchangedWorkingDirectoryWritesNothing),
]
