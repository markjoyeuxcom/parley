import Foundation
import ParleyCore

private func idExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "DelegationId", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func idRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "DelegationId", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

/// Review of 22 September 2026, M4: the delegation prompt taught
/// `parley done current`. A cancels D1 (which does not interrupt B), B is no
/// longer busy, A delegates D2 to B; B finishes D1 and runs `done current`,
/// which resolves to D2, so D2 completes with D1's report and A's wait
/// returns it as success. The prompt must name its own id, and a report that
/// names a delegation that has closed must be refused, saying why.
func checkDelegationReportsNameTheirOwnId() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-delegation-id-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    let folder = directory.appendingPathComponent("worker", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    func pane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
        WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: folder.path, currentCommand: "x", isActive: false,
                      workspaceID: "@ids", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Ids", inputAvailable: true)
    }
    let lead = pane("lead", .claude), worker = pane("worker", .codex)
    let leadToken = try credentials.token(for: lead.id), workerToken = try credentials.token(for: worker.id)
    final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func append(_ text: String) { lock.withLock { texts.append(text) } }
        var last: String? { lock.withLock { texts.last } }
    }
    let prompts = Prompts()
    let broker = RelayBroker(credentials: credentials, panes: { [lead, worker] }, paste: { _, _ in },
                             submit: { _, text in prompts.append(text) }, livenessPollInterval: 0.01,
                             contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json")))

    let first = broker.handleDelegate(token: leadToken, target: worker.id, text: "First task.", idempotencyKey: "ids-first")
    let firstID = try idRequire(first.body.handoffID, "the first delegation returned no id")
    let prompt = try idRequire(prompts.last, "the first delegation delivered no prompt")
    for command in ["parley done \(firstID) \"", "parley done \(firstID) --file <path>", "parley fail \(firstID) \"", "parley progress \(firstID) \""] {
        try idExpect(prompt.contains(command), "the delegation prompt does not teach `\(command)`:\n\(prompt)")
    }
    for stale in ["done current", "fail current", "progress current"] {
        try idExpect(!prompt.contains(stale), "the delegation prompt still teaches `\(stale)`")
    }
    try idExpect(prompt.contains("use it verbatim") && prompt.contains("Do not substitute `current`"),
                 "the delegation prompt does not warn against `current`")

    // A cancels D1; B was not interrupted and is free for D2.
    try idExpect(broker.cancelHandoff(token: leadToken, handoffID: firstID).status == 200, "the lead could not cancel its delegation")
    let second = broker.handleDelegate(token: leadToken, target: worker.id, text: "Second task.", idempotencyKey: "ids-second")
    let secondID = try idRequire(second.body.handoffID, "the second delegation returned no id")

    // B finishes D1 and reports it by the id it was given.
    let late = broker.handleDelegationResult(token: workerToken, handoffID: firstID, text: "First task done.", succeeded: true)
    try idExpect(late.status == 404 && late.text.contains("was cancelled at") && late.text.contains("not accepted"),
                 "a report for the cancelled delegation was not refused with its state: \(late.status) \(late.text)")
    let lateProgress = broker.handleDelegationProgress(token: workerToken, handoffID: firstID, text: "still going")
    try idExpect(lateProgress.status == 404 && lateProgress.text.contains("was cancelled at"),
                 "progress for the cancelled delegation was not refused with its state: \(lateProgress.status) \(lateProgress.text)")
    let staged = folder.appendingPathComponent("result.md")
    try "# Result\n".write(to: staged, atomically: true, encoding: .utf8)
    let lateFile = broker.handleDelegationFileResult(token: workerToken, handoffID: firstID, path: staged.path, text: "# Result\n")
    try idExpect(lateFile.status == 404 && lateFile.text.contains("was cancelled at"),
                 "a result file for the cancelled delegation was not refused with its state: \(lateFile.status) \(lateFile.text)")
    try idExpect(broker.handoffs().first { $0.id == secondID }?.state == .waiting, "the late D1 report changed D2")
    // `current` could mean D1 or D2 in this run, so it is refused, never resolved to D2.
    for (name, response) in [
        ("done", broker.handleDelegationResult(token: workerToken, handoffID: "current", text: "First task done.", succeeded: true)),
        ("progress", broker.handleDelegationProgress(token: workerToken, handoffID: "current", text: "still going")),
        ("done --file", broker.handleDelegationFileResult(token: workerToken, handoffID: "current", path: staged.path, text: "# Result\n")),
    ] {
        try idExpect(response.status == 409 && response.text.contains("Name the delegation's id"),
                     "`\(name) current` after a cancelled delegation was not refused: \(response.status) \(response.text)")
    }
    try idExpect(broker.handoffs().first { $0.id == secondID }?.state == .waiting, "a `current` report changed D2")
    // Only the delegated pane learns why an id is closed.
    let probe = broker.handleDelegationResult(token: leadToken, handoffID: firstID, text: "Probe.", succeeded: true)
    try idExpect(probe.status == 404 && probe.text == "unknown active delegation", "another pane learned the delegation's state: \(probe.text)")

    // D2 receives its own report, and A's wait returns exactly that.
    try idExpect(broker.handleDelegationResult(token: workerToken, handoffID: secondID, text: "Second task done.", succeeded: true).status == 200,
                 "the second delegation did not accept its own report")
    let waited = broker.waitForTrackedWork(token: leadToken, handoffID: secondID)
    try idExpect(waited.status == 200 && waited.text == "Second task done.", "the lead's wait returned the wrong report: \(waited.text)")
    // A second report for a delegation that already completed says so too.
    let again = broker.handleDelegationResult(token: workerToken, handoffID: secondID, text: "Again.", succeeded: true)
    try idExpect(again.status == 404 && again.text.contains("already has a result"), "a repeated report was not refused with its state: \(again.text)")
    // A delegation that ended as failed says so.
    let third = broker.handleDelegate(token: leadToken, target: worker.id, text: "Third task.", idempotencyKey: "ids-third")
    let thirdID = try idRequire(third.body.handoffID, "the third delegation returned no id")
    try idExpect(broker.handleDelegationResult(token: workerToken, handoffID: thirdID, text: "Blocked.", succeeded: false).status == 200,
                 "the third delegation did not accept its failure")
    let afterFailure = broker.handleDelegationResult(token: workerToken, handoffID: thirdID, text: "Done after all.", succeeded: true)
    try idExpect(afterFailure.status == 404 && afterFailure.text.contains("already ended as failed"), "a report after failure was not refused with its state: \(afterFailure.text)")
}

/// Review of 22 September 2026, "Text that contradicts behaviour": wording
/// shown to agents or the person must say what Parley does.
func checkProtocolHelpAndTeamTextMatchBehaviour() throws {
    let help = ParleyHelpGuide.topics.map(\.searchableText).joined(separator: "\n")
    // Delegated work names its id; `current` is never what Parley teaches.
    for text in [AgentProtocol.text, help] {
        for stale in ["done current", "fail current", "progress current", "answer current \""] {
            try idExpect(!text.contains(stale), "agent or Help text still teaches `\(stale)`")
        }
    }
    try idExpect(AgentProtocol.text.contains("`parley done <id> \"<report>\"`") && AgentProtocol.text.contains("Do not substitute `current`"),
                 "the protocol does not teach reporting delegated work by its id")
    // A host team with the vendor's automatic reviewer is how it runs unattended.
    for (name, text) in [("protocol", AgentProtocol.text), ("team approval", TeamSessionDisclosure.approval), ("Help", help)] {
        try idExpect(!text.contains("not unattended"), "the \(name) still says a host team is never unattended")
        try idExpect(text.contains("automatic reviewer"), "the \(name) does not mention the vendor's automatic reviewer")
    }
    // Command-run switches reset on every launch.
    for (name, text) in [("parley help", AgentProtocol.commandHelp), ("Help", help)] {
        try idExpect(!text.contains("persistent Settings switches"), "\(name) still calls the command-run switches persistent")
    }
    // Help items that described removed or changed behaviour.
    for stale in ["The Managed by Parley list", "currently reopen balanced", "In a container for Claude Code and Codex", "does not publish the browser-login callback port"] {
        try idExpect(!help.contains(stale), "Help still says: \(stale)")
    }
}

@MainActor let delegationIdChecks: [(String, () throws -> Void)] = [
    ("delegation reports name their own id", checkDelegationReportsNameTheirOwnId),
    ("protocol, help and team text match behaviour", checkProtocolHelpAndTeamTextMatchBehaviour),
]
