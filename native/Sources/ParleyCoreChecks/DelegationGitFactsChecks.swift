import Dispatch
import Foundation
import ParleyCore

private enum GitFactsCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): message }
    }
}

private func gitExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GitFactsCheckFailure.failed(message) }
}

private func gitRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw GitFactsCheckFailure.failed(message) }
    return value
}

private final class GitFactsRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var respond: ([String]) throws -> CommandOutput

    init(respond: @escaping ([String]) throws -> CommandOutput) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String], input: Data?) throws -> CommandOutput {
        lock.withLock { recorded.append(Call(executable: executable.path, arguments: arguments)) }
        return try respond(arguments)
    }
}

private func porcelain(_ entries: [String]) -> Data {
    Data((entries.joined(separator: "\u{0}") + "\u{0}").utf8)
}

private let oid = "0123456789abcdef0123456789abcdef01234567"
private let otherOID = "89abcdef0123456789abcdef0123456789abcdef"
private let reference = Date(timeIntervalSinceReferenceDate: 5_000)

private func snapshot(
    folder: String = "/private/project",
    head: String? = oid,
    branch: String? = "main",
    detached: Bool = false,
    paths: [String],
    count: Int? = nil,
    unavailable: String? = nil,
    at: TimeInterval = 5_000
) -> DelegationGitSnapshot {
    DelegationGitSnapshot(
        capturedAt: Date(timeIntervalSinceReferenceDate: at),
        folder: folder,
        headRevision: head,
        branch: branch,
        isDetached: detached,
        dirtyPaths: paths,
        dirtyPathCount: count ?? paths.count,
        unavailableReason: unavailable
    )
}

private func gitDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-git-facts-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func checkDelegationGitSnapshotIsBoundedPathsOnly() throws {
    let folder = try gitDirectory().path
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let dirty = porcelain([
        "# branch.oid \(oid)",
        "# branch.head main",
        "# branch.upstream origin/main",
        "# branch.ab +0 -0",
        "1 .M N... 100644 100644 100644 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 native/App.swift",
        "2 R. N... 100644 100644 100644 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 R100 new/path.swift",
        "old/path.swift",
        "u UU N... 100644 100644 100644 100644 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 abcdef0abcdef0abcdef0abcdef0abcdef0abcdef0 conflict.txt",
        "? native/New File.swift",
        "? native/App.swift",
    ])
    let runner = GitFactsRunner { _ in CommandOutput(stdout: dirty, status: 0) }
    let capture = DelegationGitSnapshotCapture(
        runner: runner,
        gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
        clock: { reference }
    )
    let captured = try gitRequire(capture.snapshot(in: folder), "a dirty repository produced no Git facts")

    // Fixed executable and argv, one command, no content-bearing subcommand.
    try gitExpect(runner.calls.count == 1, "capture ran \(runner.calls.count) commands instead of one")
    try gitExpect(runner.calls.first?.executable == "/usr/bin/git", "capture invoked something other than git directly")
    try gitExpect(
        runner.calls.first?.arguments == [
            "-C", folder, "-c", "core.fsmonitor=false",
            "status", "--porcelain=v2", "--branch", "--untracked-files=normal", "-z",
        ],
        "capture did not use the fixed status argv: \(runner.calls.first?.arguments ?? [])"
    )
    try gitExpect(
        DelegationGitFacts.arguments(for: folder) == runner.calls.first?.arguments,
        "the published argv differs from the one the capture ran"
    )
    for banned in ["diff", "show", "log", "blame", "cat-file", "-p", "--patch"] {
        try gitExpect(!(runner.calls.first?.arguments.contains(banned) ?? true), "capture argv contains content-bearing option \(banned)")
    }

    // Paths only, deduplicated and sorted; modes, hashes and scores are dropped.
    try gitExpect(captured.isAvailable && captured.unavailableReason == nil, "an available snapshot was marked unavailable")
    try gitExpect(captured.capturedAt == reference && captured.folder == folder, "snapshot lost its owned capture time or folder")
    try gitExpect(captured.headRevision == oid && captured.branch == "main" && !captured.isDetached, "snapshot lost HEAD or branch: \(captured)")
    try gitExpect(
        captured.dirtyPaths == ["conflict.txt", "native/App.swift", "native/New File.swift", "new/path.swift", "old/path.swift"],
        "dirty paths were not the sorted, deduplicated path list: \(captured.dirtyPaths)"
    )
    try gitExpect(captured.dirtyPathCount == 5 && !captured.isTruncated, "dirty path count or truncation was wrong")
    try gitExpect(captured.shortRevision == "0123456", "short revision is not the seven-character prefix")
    try gitExpect(captured.summary == "HEAD 0123456 · main · 5 dirty paths", "summary was not compact and factual: \(captured.summary)")
    let encoded = String(decoding: try JSONEncoder().encode(captured), as: UTF8.self)
    for leaked in ["100644", "abcdef0abcdef0", "R100", ".M N...", "UU"] {
        try gitExpect(!encoded.contains(leaked), "the stored snapshot leaked a non-path column: \(leaked)")
    }

    // Cap at 200 with the true count retained.
    let many = porcelain(["# branch.oid \(oid)", "# branch.head main"] + (0..<250).map { "? file-\(String(format: "%03d", $0)).txt" })
    let capped = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in CommandOutput(stdout: many, status: 0) }, clock: { reference })
            .snapshot(in: folder),
        "a large dirty set produced no snapshot"
    )
    try gitExpect(DelegationGitSnapshot.maximumPaths == 200, "the path cap is not 200")
    try gitExpect(capped.dirtyPaths.count == 200 && capped.dirtyPathCount == 250 && capped.isTruncated, "the cap did not keep 200 of 250 honestly")
    try gitExpect(capped.dirtyPaths.first == "file-000.txt" && capped.dirtyPaths.last == "file-199.txt", "the retained 200 are not the first 200 in sorted order")
    try gitExpect(capped.summary == "HEAD 0123456 · main · 250 dirty paths (200 listed)", "truncated summary hid the cap: \(capped.summary)")

    // Clean tree, detached HEAD and an unborn branch.
    let clean = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in CommandOutput(stdout: porcelain(["# branch.oid \(oid)", "# branch.head main"]), status: 0) }, clock: { reference })
            .snapshot(in: folder),
        "a clean repository produced no snapshot"
    )
    try gitExpect(clean.dirtyPaths.isEmpty && clean.dirtyPathCount == 0 && clean.summary == "HEAD 0123456 · main · clean", "clean tree summary was wrong: \(clean.summary)")
    let detached = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in CommandOutput(stdout: porcelain(["# branch.oid \(oid)", "# branch.head (detached)", "1 .M N... 100644 100644 100644 abcdef0 abcdef0 a.txt"]), status: 0) }, clock: { reference })
            .snapshot(in: folder),
        "a detached HEAD produced no snapshot"
    )
    try gitExpect(detached.isDetached && detached.branch == nil && detached.headRevision == oid, "detached HEAD was not recorded as detached with its revision")
    try gitExpect(detached.summary == "HEAD 0123456 · detached · 1 dirty path", "detached summary was wrong: \(detached.summary)")
    let unborn = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in CommandOutput(stdout: porcelain(["# branch.oid (initial)", "# branch.head main"]), status: 0) }, clock: { reference })
            .snapshot(in: folder),
        "an unborn branch produced no snapshot"
    )
    try gitExpect(unborn.headRevision == nil && unborn.branch == "main" && unborn.summary == "no commits yet · main · clean", "unborn branch summary was wrong: \(unborn.summary)")
    try gitExpect(DelegationGitSnapshot.label == "Shared worktree: not attribution", "the Git facts label is not 'Shared worktree: not attribution'")
}

func checkDelegationGitCaptureFailuresAreInformational() throws {
    let folder = try gitDirectory().path
    defer { try? FileManager.default.removeItem(atPath: folder) }

    let notRepository = GitFactsRunner { _ in
        CommandOutput(stderr: Data("fatal: not a git repository (or any of the parent directories): .git\n".utf8), status: 128)
    }
    try gitExpect(
        DelegationGitSnapshotCapture(runner: notRepository, clock: { reference }).snapshot(in: folder) == nil,
        "a non-Git working folder recorded Git facts"
    )

    let unreadable = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in
            CommandOutput(stderr: Data("fatal: unable to read tree 0123456\n".utf8), status: 128)
        }, clock: { reference }).snapshot(in: folder),
        "an unreadable repository recorded nothing instead of an informational reason"
    )
    try gitExpect(
        !unreadable.isAvailable && unreadable.unavailableReason == "git status exited 128" && unreadable.dirtyPaths.isEmpty && unreadable.headRevision == nil,
        "unreadable repository facts were not informational: \(unreadable)"
    )
    try gitExpect(unreadable.summary == "Git facts unavailable: git status exited 128", "unavailable summary was wrong: \(unreadable.summary)")
    let stored = String(decoding: try JSONEncoder().encode(unreadable), as: UTF8.self)
    try gitExpect(!stored.contains("unable to read tree"), "the stored reason leaked git's stderr text")

    let timedOut = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in CommandOutput(status: 124) }, clock: { reference }).snapshot(in: folder),
        "a timed-out capture recorded nothing"
    )
    try gitExpect(timedOut.unavailableReason == "git status timed out", "timeout reason was wrong: \(timedOut.unavailableReason ?? "nil")")

    struct SpawnFailure: Error {}
    let failedToStart = try gitRequire(
        DelegationGitSnapshotCapture(runner: GitFactsRunner { _ in throw SpawnFailure() }, clock: { reference }).snapshot(in: folder),
        "a capture that could not start recorded nothing"
    )
    try gitExpect(failedToStart.unavailableReason == "git status could not start", "spawn failure reason was wrong: \(failedToStart.unavailableReason ?? "nil")")

    let neverRun = GitFactsRunner { _ in CommandOutput(status: 0) }
    let missingFolder = folder + "/moved-away"
    let missing = try gitRequire(
        DelegationGitSnapshotCapture(runner: neverRun, clock: { reference }).snapshot(in: missingFolder),
        "a missing working folder recorded nothing"
    )
    try gitExpect(missing.unavailableReason == "the working folder is missing" && missing.folder == missingFolder, "missing folder reason was wrong: \(missing.unavailableReason ?? "nil")")
    try gitExpect(neverRun.calls.isEmpty, "git ran against a missing working folder")

    try gitExpect(
        DelegationGitFacts.compare(delegation: snapshot(paths: ["a"]), returned: unreadable) == nil
            && DelegationGitFacts.compare(delegation: nil, returned: snapshot(paths: [])) == nil,
        "a comparison was derived from an unavailable or missing side"
    )
}

func checkDelegationGitComparisonDerivesChangedPathsHonestly() throws {
    let before = snapshot(paths: ["a.swift", "b.swift"])
    let after = snapshot(paths: ["b.swift", "c.swift", "d.swift"], at: 5_600)
    let changed = try gitRequire(DelegationGitFacts.compare(delegation: before, returned: after), "two available snapshots produced no comparison")
    try gitExpect(changed.changedPaths == ["a.swift", "c.swift", "d.swift"] && changed.changedPathCount == 3, "changed paths are not the sorted status difference: \(changed.changedPaths)")
    try gitExpect(!changed.isLowerBound && !changed.headMoved && !changed.folderChanged, "a plain comparison claimed a bound, moved HEAD or folder change")
    try gitExpect(changed.title == "3 paths changed since delegated", "title was wrong: \(changed.title)")
    try gitExpect(changed.detail == nil, "a plain comparison carried a detail: \(changed.detail ?? "")")

    let same = try gitRequire(DelegationGitFacts.compare(delegation: before, returned: before), "identical snapshots produced no comparison")
    try gitExpect(same.changedPaths.isEmpty && same.title == "No path changes since delegated", "identical snapshots were not reported as unchanged: \(same.title)")

    let one = try gitRequire(DelegationGitFacts.compare(delegation: before, returned: snapshot(paths: ["a.swift"])), "single change produced no comparison")
    try gitExpect(one.title == "1 path changed since delegated", "singular title was wrong: \(one.title)")

    let moved = try gitRequire(DelegationGitFacts.compare(delegation: before, returned: snapshot(head: otherOID, paths: ["a.swift", "b.swift"])), "moved HEAD produced no comparison")
    try gitExpect(moved.headMoved, "a different HEAD revision was not reported")
    let movedDetail = try gitRequire(moved.detail, "moved HEAD carried no detail")
    try gitExpect(movedDetail.contains("HEAD moved since delegated") && movedDetail.contains("committed paths are not listed"), "moved HEAD detail was not honest: \(movedDetail)")
    try gitExpect(!movedDetail.lowercased().contains("by ") && !movedDetail.lowercased().contains("author"), "moved HEAD detail implied attribution: \(movedDetail)")

    let truncatedBefore = snapshot(paths: (0..<200).map { "f\(String(format: "%03d", $0))" }, count: 250)
    let bounded = try gitRequire(DelegationGitFacts.compare(delegation: truncatedBefore, returned: snapshot(paths: [])), "truncated input produced no comparison")
    try gitExpect(bounded.isLowerBound && bounded.changedPathCount == 200 && bounded.title == "At least 200 paths changed since delegated", "a truncated input did not yield a lower bound: \(bounded.title)")
    try gitExpect(bounded.detail?.contains("truncated") == true, "truncation was not surfaced in the detail: \(bounded.detail ?? "nil")")

    let wide = try gitRequire(
        DelegationGitFacts.compare(delegation: snapshot(paths: []), returned: snapshot(paths: (0..<230).map { "g\(String(format: "%03d", $0))" }.sorted().prefix(200).map { $0 }, count: 230)),
        "wide change produced no comparison"
    )
    try gitExpect(wide.changedPaths.count == 200 && wide.isLowerBound, "the changed list was not capped at 200 with a lower bound")

    let elsewhere = try gitRequire(DelegationGitFacts.compare(delegation: before, returned: snapshot(folder: "/private/other", paths: ["a.swift", "b.swift"])), "folder change produced no comparison")
    try gitExpect(elsewhere.folderChanged && elsewhere.detail?.contains("working folder changed") == true, "a changed working folder was not surfaced: \(elsewhere.detail ?? "nil")")
}

func checkDelegationGitFactsAreRecordedWithoutChangingOutcomes() throws {
    let directory = try gitDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let implementerFolder = directory.appendingPathComponent("impl", isDirectory: true)
    try FileManager.default.createDirectory(at: implementerFolder, withIntermediateDirectories: true)

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
    func pane(_ id: String, _ kind: PaneKind, _ name: String, cwd: String) -> WorkbenchPane {
        WorkbenchPane(
            id: id, kind: kind, customName: name, terminalTitle: "", cwd: cwd, currentCommand: "x",
            isActive: false, workspaceID: "@git", relayEnabled: true,
            protocolVersion: AgentProtocol.version, workspaceName: "Git", inputAvailable: true
        )
    }
    let owner = pane("%owner", .codex, "Owner", cwd: "/private/owner")
    let implementer = pane("%implementer", .claude, "Implementer", cwd: implementerFolder.path)
    let ownerToken = try credentials.token(for: owner.id)
    let implementerToken = try credentials.token(for: implementer.id)

    final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var folders: [String] = []
        var queue: [DelegationGitSnapshot?] = []
        var unlockedProbes: [Bool] = []
        weak var broker: RelayBroker?
    }
    let probe = Probe()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [owner, implementer] },
        paste: { _, _ in },
        submit: { _, _ in },
        gitFacts: { folder in
            // Prove the capture runs outside the coordination lock: a
            // broker read from another thread must complete promptly.
            let released = DispatchSemaphore(value: 0)
            let target = probe.broker
            DispatchQueue.global(qos: .utility).async {
                _ = target?.handoffs()
                released.signal()
            }
            let unlocked = released.wait(timeout: .now() + 2) == .success
            return probe.lock.withLock {
                probe.folders.append(folder)
                probe.unlockedProbes.append(unlocked)
                return probe.queue.isEmpty ? nil : probe.queue.removeFirst()
            }
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal,
        contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
    )
    probe.broker = broker

    // 1. Delegate records the target folder's facts; done records them again.
    let atDelegation = snapshot(folder: implementerFolder.path, paths: ["a.swift"])
    let atReturn = snapshot(folder: implementerFolder.path, paths: ["a.swift", "b.swift"], at: 5_300)
    probe.lock.withLock { probe.queue = [atDelegation, atReturn] }
    let first = broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Implement it.", idempotencyKey: "git-facts-1")
    try gitExpect(first.status == 200 && first.body.state == .waiting, "delegation with Git facts did not deliver normally")
    let firstID = try gitRequire(first.body.handoffID, "first delegation returned no id")
    var handoff = try gitRequire(broker.handoffs().first(where: { $0.id == firstID }), "first delegation disappeared")
    try gitExpect(handoff.gitFactsAtDelegation == atDelegation, "delegation-time Git facts were not recorded: \(String(describing: handoff.gitFactsAtDelegation))")
    try gitExpect(handoff.gitFactsAtReturn == nil, "return-time facts appeared before any result")
    let done = broker.handleDelegationResult(token: implementerToken, handoffID: firstID, text: "Done.", succeeded: true)
    try gitExpect(done.status == 200, "done failed with Git facts enabled: \(done.text)")
    handoff = try gitRequire(broker.handoffs().first(where: { $0.id == firstID }), "first delegation disappeared after done")
    try gitExpect(handoff.state == .completed && handoff.gitFactsAtReturn == atReturn, "return-time Git facts were not recorded on completion")
    try gitExpect(probe.folders == [implementerFolder.path, implementerFolder.path], "capture did not inspect the target pane's working folder twice: \(probe.folders)")

    // 2. Unavailable facts at return never change the outcome.
    let unavailable = snapshot(folder: implementerFolder.path, head: nil, branch: nil, paths: [], unavailable: "git status timed out")
    probe.lock.withLock { probe.queue = [atDelegation, unavailable] }
    let second = broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Again.", idempotencyKey: "git-facts-2")
    let secondID = try gitRequire(second.body.handoffID, "second delegation returned no id")
    let failed = broker.handleDelegationResult(token: implementerToken, handoffID: secondID, text: "Blocked.", succeeded: false)
    try gitExpect(failed.status == 200, "fail was rejected with Git facts enabled: \(failed.text)")
    let secondHandoff = try gitRequire(broker.handoffs().first(where: { $0.id == secondID }), "second delegation disappeared")
    try gitExpect(secondHandoff.state == .failed && secondHandoff.resultText == "Blocked.", "an unavailable Git capture altered the failure outcome")
    try gitExpect(secondHandoff.gitFactsAtReturn?.unavailableReason == "git status timed out", "the unavailable reason was not retained informationally")

    // 3. A non-Git folder records nothing and delivery is unchanged.
    probe.lock.withLock { probe.queue = [nil, nil] }
    let third = broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Plain folder.", idempotencyKey: "git-facts-3")
    let thirdID = try gitRequire(third.body.handoffID, "third delegation returned no id")
    try gitExpect(broker.handleDelegationResult(token: implementerToken, handoffID: thirdID, text: "Done.", succeeded: true).status == 200, "done failed for a non-Git folder")
    let thirdHandoff = try gitRequire(broker.handoffs().first(where: { $0.id == thirdID }), "third delegation disappeared")
    try gitExpect(thirdHandoff.state == .completed && thirdHandoff.gitFactsAtDelegation == nil && thirdHandoff.gitFactsAtReturn == nil, "a non-Git folder recorded Git facts or changed the outcome")

    // 4. The file-result path records return-time facts too.
    probe.lock.withLock { probe.queue = [atDelegation, atReturn] }
    let fourth = broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Return a file.", idempotencyKey: "git-facts-4")
    let fourthID = try gitRequire(fourth.body.handoffID, "fourth delegation returned no id")
    let resultFile = implementerFolder.appendingPathComponent("result.md")
    try "# Result\n".write(to: resultFile, atomically: true, encoding: .utf8)
    let fileDone = broker.handleDelegationFileResult(token: implementerToken, handoffID: fourthID, path: resultFile.path, text: "# Result\n")
    try gitExpect(fileDone.status == 200, "done --file failed with Git facts enabled: \(fileDone.text)")
    let fourthHandoff = try gitRequire(broker.handoffs().first(where: { $0.id == fourthID }), "fourth delegation disappeared")
    try gitExpect(fourthHandoff.state == .completed && fourthHandoff.gitFactsAtReturn == atReturn, "done --file did not record return-time Git facts")

    // 5. Never under the lock; durable; backward decodable.
    try gitExpect(!probe.unlockedProbes.isEmpty && probe.unlockedProbes.allSatisfy { $0 }, "Git capture ran while the coordination lock was held")
    let durable = try gitRequire(journal.handoffs().first(where: { $0.id == firstID }), "journal lost the first delegation")
    try gitExpect(durable.gitFactsAtDelegation == atDelegation && durable.gitFactsAtReturn == atReturn, "journal round trip lost Git facts")
    let reloaded = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
    try gitExpect(reloaded.handoffs().first(where: { $0.id == firstID })?.gitFactsAtReturn == atReturn, "reloading the journal lost Git facts")
    var legacy = try gitRequire(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(durable)) as? [String: Any], "could not build a legacy fixture")
    legacy.removeValue(forKey: "gitFactsAtDelegation")
    legacy.removeValue(forKey: "gitFactsAtReturn")
    let decoded = try JSONDecoder().decode(RelayHandoff.self, from: try JSONSerialization.data(withJSONObject: legacy))
    try gitExpect(decoded.gitFactsAtDelegation == nil && decoded.gitFactsAtReturn == nil && decoded.id == firstID, "an old handoff without Git facts did not decode")
    try gitExpect(AgentProtocol.version == "19", "Git facts checks did not use the current shared protocol")
}

func checkDelegationGitFactsExportPreservesPathsOnly() throws {
    func fixture(delegation: DelegationGitSnapshot?, returned: DelegationGitSnapshot?) throws -> RelayHandoff {
        var object: [String: Any] = [
            "id": "git-export", "idempotencyKey": "k", "kind": "delegate",
            "sourcePaneID": "%owner", "sourceName": "Owner", "sourceKind": "codex",
            "sourceWorkspaceID": "@git", "targetPaneID": "%implementer", "targetName": "Implementer",
            "targetKind": "claude", "targetWorkspaceID": "@git", "text": "Implement it.", "submitted": true,
            "state": "completed", "updatedAt": 5_600, "resultText": "Done.",
            "transitions": [["state": "created", "occurredAt": 5_000], ["state": "delivered", "occurredAt": 5_001], ["state": "completed", "occurredAt": 5_600]],
        ]
        let encoder = JSONEncoder()
        if let delegation { object["gitFactsAtDelegation"] = try JSONSerialization.jsonObject(with: encoder.encode(delegation)) }
        if let returned { object["gitFactsAtReturn"] = try JSONSerialization.jsonObject(with: encoder.encode(returned)) }
        return try JSONDecoder().decode(RelayHandoff.self, from: try JSONSerialization.data(withJSONObject: object))
    }
    let before = snapshot(paths: ["a.swift", "b.swift"])
    let after = snapshot(paths: ["b.swift", "c.swift", "d.swift"], at: 5_600)
    let markdown = CollaborationHistoryMarkdown.document(handoffs: [try fixture(delegation: before, returned: after)], scopeName: "Git")
    try gitExpect(markdown.contains("### Git facts (shared worktree: not attribution)"), "export lost the labelled Git facts section")
    try gitExpect(markdown.contains("- At delegation: HEAD 0123456 · main · 2 dirty paths"), "export lost the delegation-time facts")
    try gitExpect(markdown.contains("- At return: HEAD 0123456 · main · 3 dirty paths"), "export lost the return-time facts")
    try gitExpect(markdown.contains("- 3 paths changed since delegated"), "export lost the derived change count")
    for path in ["a.swift", "c.swift", "d.swift"] {
        try gitExpect(markdown.contains("  - `\(path)`"), "export lost changed path \(path)")
    }
    try gitExpect(!markdown.contains("  - `b.swift`"), "export listed an unchanged path as changed")
    try gitExpect(markdown.contains("Paths only. Other panes and the person edit this tree; nothing here says who changed a file."), "export lost the attribution disclaimer")
    for banned in ["@@", "+++ ", "--- a/", "Author:"] {
        try gitExpect(!markdown.contains(banned), "export contained diff or authorship content: \(banned)")
    }

    let truncated = snapshot(paths: (0..<200).map { "p\(String(format: "%03d", $0))" }, count: 250, at: 5_600)
    let truncatedMarkdown = CollaborationHistoryMarkdown.document(handoffs: [try fixture(delegation: snapshot(paths: []), returned: truncated)], scopeName: "Git")
    try gitExpect(truncatedMarkdown.contains("- At least 200 paths changed since delegated"), "export hid the lower bound for a truncated list")
    try gitExpect(truncatedMarkdown.contains("truncated"), "export hid truncation")

    let unavailable = snapshot(head: nil, branch: nil, paths: [], unavailable: "git status timed out", at: 5_600)
    let unavailableMarkdown = CollaborationHistoryMarkdown.document(handoffs: [try fixture(delegation: before, returned: unavailable)], scopeName: "Git")
    try gitExpect(unavailableMarkdown.contains("- At return: Git facts unavailable: git status timed out"), "export hid an informational capture failure")
    try gitExpect(!unavailableMarkdown.contains("changed since delegated"), "export derived a change count from an unavailable side")

    let none = CollaborationHistoryMarkdown.document(handoffs: [try fixture(delegation: nil, returned: nil)], scopeName: "Git")
    try gitExpect(!none.contains("Git facts"), "export invented a Git facts section for a non-Git delegation")
}

private final class GitRaceBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

private func gitEventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return condition()
}

func checkDelegationCancelledDuringGitCaptureIsNeverSubmitted() throws {
    let directory = try gitDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"))
    func pane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
        WorkbenchPane(
            id: id, kind: kind, customName: name, terminalTitle: "", cwd: directory.path, currentCommand: "x",
            isActive: false, workspaceID: "@race", relayEnabled: true,
            protocolVersion: AgentProtocol.version, workspaceName: "Race", inputAvailable: true
        )
    }
    let owner = pane("%owner", .codex, "Owner")
    let implementer = pane("%implementer", .claude, "Implementer")
    let ownerToken = try credentials.token(for: owner.id)
    let implementerToken = try credentials.token(for: implementer.id)

    let captureStarted = DispatchSemaphore(value: 0)
    let releaseCapture = DispatchSemaphore(value: 0)
    let submits = GitRaceBox<[String]>()
    submits.set([])
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [owner, implementer] },
        paste: { _, _ in },
        submit: { paneID, _ in
            submits.set((submits.value ?? []) + [paneID])
        },
        gitFacts: { folder in
            captureStarted.signal()
            _ = releaseCapture.wait(timeout: .now() + 5)
            return snapshot(folder: folder, paths: ["a.swift"])
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    // 1. Cancel through the initiating credential while creation-time capture blocks.
    let response = GitRaceBox<RelayResponse>()
    DispatchQueue.global(qos: .utility).async {
        response.set(broker.handleDelegate(
            token: ownerToken,
            target: implementer.id,
            text: "Cancel me during capture.",
            idempotencyKey: "git-race-create"
        ))
    }
    try gitExpect(captureStarted.wait(timeout: .now() + 3) == .success, "creation-time Git capture never started")
    let created = try gitRequire(
        broker.handoffs().first(where: { $0.text == "Cancel me during capture." }),
        "the delegation was not recorded before capture"
    )
    try gitExpect(created.state == .created, "the delegation was not in the created state during capture: \(created.state)")
    let cancelled = broker.cancelHandoff(token: ownerToken, handoffID: created.id)
    try gitExpect(cancelled.status == 200, "the initiating pane could not cancel during capture: \(cancelled.text)")
    releaseCapture.signal()
    try gitExpect(gitEventually { response.value != nil }, "handleDelegate did not return after capture was released")
    let outcome = try gitRequire(response.value, "no delegate response")
    try gitExpect(submits.value?.isEmpty == true, "the cancelled task was still submitted to the target: \(submits.value ?? [])")
    try gitExpect(
        outcome.status != 200 && outcome.body.ok == false && outcome.body.state == .cancelled && outcome.body.handoffID == created.id,
        "handleDelegate did not report the cancelled terminal state: status \(outcome.status) ok \(outcome.body.ok) state \(String(describing: outcome.body.state))"
    )
    let final = try gitRequire(broker.handoffs().first(where: { $0.id == created.id }), "the cancelled delegation disappeared")
    try gitExpect(final.state == .cancelled, "the delegation did not remain cancelled: \(final.state)")
    try gitExpect(final.transitions.map(\.state) == [.created, .cancelled], "terminal history was rewritten: \(final.transitions.map(\.state))")
    try gitExpect(final.gitFactsAtDelegation == nil, "Git facts were attached to a cancelled delegation after its terminal state")
    try gitExpect(journal.handoffs().first(where: { $0.id == created.id })?.transitions.map(\.state) == [.created, .cancelled], "the journal recorded a post-cancellation transition")

    // Idempotent replay settles on the recorded outcome and never delivers later.
    let replay = broker.handleDelegate(
        token: ownerToken,
        target: implementer.id,
        text: "Cancel me during capture.",
        idempotencyKey: "git-race-create"
    )
    try gitExpect(replay.status != 200 && replay.body.handoffID == created.id && replay.body.state == .cancelled, "an idempotent replay did not settle on the cancelled outcome: \(replay.status)")
    try gitExpect(submits.value?.isEmpty == true, "an idempotent replay delivered a cancelled task")
    try gitExpect(broker.handoffs().count == 1, "an idempotent replay created a second handoff")

    // A fresh delegation still delivers normally after the fix.
    let fresh = GitRaceBox<RelayResponse>()
    DispatchQueue.global(qos: .utility).async {
        fresh.set(broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Deliver me.", idempotencyKey: "git-race-fresh"))
    }
    try gitExpect(captureStarted.wait(timeout: .now() + 3) == .success, "fresh capture never started")
    releaseCapture.signal()
    try gitExpect(gitEventually { fresh.value != nil }, "the fresh delegation did not return")
    let freshOutcome = try gitRequire(fresh.value, "no fresh response")
    try gitExpect(freshOutcome.status == 200 && freshOutcome.body.state == .waiting, "an uncancelled delegation no longer delivers: \(freshOutcome.status)")
    try gitExpect(submits.value == [implementer.id], "the fresh delegation was not submitted exactly once: \(submits.value ?? [])")
    let freshID = try gitRequire(freshOutcome.body.handoffID, "fresh delegation returned no id")
    try gitExpect(broker.handoffs().first(where: { $0.id == freshID })?.gitFactsAtDelegation?.dirtyPaths == ["a.swift"], "the fresh delegation lost its creation-time Git facts")

    // 2. Cancellation during the target's done capture: the result is refused
    //    and the cancelled outcome stands. (Existing behaviour, asserted.)
    let doneResponse = GitRaceBox<RelayTextResponse>()
    DispatchQueue.global(qos: .utility).async {
        doneResponse.set(broker.handleDelegationResult(token: implementerToken, handoffID: freshID, text: "Done anyway.", succeeded: true))
    }
    try gitExpect(captureStarted.wait(timeout: .now() + 3) == .success, "return-time Git capture never started")
    try gitExpect(broker.cancelHandoff(freshID).status == 200, "native cancellation failed during return-time capture")
    releaseCapture.signal()
    try gitExpect(gitEventually { doneResponse.value != nil }, "done did not return after capture was released")
    let doneOutcome = try gitRequire(doneResponse.value, "no done response")
    try gitExpect(doneOutcome.status == 404, "a result for a delegation cancelled during capture was accepted: \(doneOutcome.status) \(doneOutcome.text)")
    let cancelledFresh = try gitRequire(broker.handoffs().first(where: { $0.id == freshID }), "the fresh delegation disappeared")
    try gitExpect(
        cancelledFresh.state == .cancelled && cancelledFresh.resultText == nil && cancelledFresh.gitFactsAtReturn == nil
            && !cancelledFresh.transitions.map(\.state).contains(.completed),
        "a late result rewrote a cancelled delegation"
    )
}

func checkDelegationGitPathDisplayEscapesControlCharacters() throws {
    let cases: [(String, String)] = [
        ("plain/path.swift", "plain/path.swift"),
        ("with space/file name.txt", "with space/file name.txt"),
        ("multi\nline.txt", "multi\\nline.txt"),
        ("tab\there.txt", "tab\\there.txt"),
        ("return\rhere.txt", "return\\rhere.txt"),
        ("\u{1b}[31mred.txt", "\\e[31mred.txt"),
        ("back\\slash.txt", "back\\\\slash.txt"),
        ("bell\u{07}.txt", "bell\\x07.txt"),
        ("del\u{7f}.txt", "del\\x7f.txt"),
        ("next\u{85}line.txt", "next\\u{0085}line.txt"),
        ("line\u{2028}sep.txt", "line\\u{2028}sep.txt"),
        ("para\u{2029}sep.txt", "para\\u{2029}sep.txt"),
    ]
    for (raw, expected) in cases {
        let display = DelegationGitFacts.displayPath(raw)
        try gitExpect(display == expected, "display projection for \(raw.debugDescription) was \(display.debugDescription), expected \(expected.debugDescription)")
        try gitExpect(
            !display.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 },
            "display projection left a control character in \(display.debugDescription)"
        )
    }

    // Raw paths stay raw for exact comparison; only the display view is escaped.
    let before = snapshot(paths: [])
    let after = snapshot(paths: ["evil\n- Injected: line", "\u{1b}[2Jcleared.txt"], at: 5_600)
    let comparison = try gitRequire(DelegationGitFacts.compare(delegation: before, returned: after), "no comparison")
    try gitExpect(comparison.changedPaths == ["\u{1b}[2Jcleared.txt", "evil\n- Injected: line"], "raw changed paths were altered: \(comparison.changedPaths)")
    try gitExpect(comparison.displayPaths == ["\\e[2Jcleared.txt", "evil\\n- Injected: line"], "display paths were not escaped: \(comparison.displayPaths)")

    // Markdown export uses the display projection: one path is one line.
    var object: [String: Any] = [
        "id": "git-escape", "idempotencyKey": "k", "kind": "delegate",
        "sourcePaneID": "%owner", "sourceName": "Owner", "sourceKind": "codex",
        "sourceWorkspaceID": "@git", "targetPaneID": "%implementer", "targetName": "Implementer",
        "targetKind": "claude", "targetWorkspaceID": "@git", "text": "Implement it.", "submitted": true,
        "state": "completed", "updatedAt": 5_600, "resultText": "Done.",
        "transitions": [["state": "created", "occurredAt": 5_000], ["state": "delivered", "occurredAt": 5_001], ["state": "completed", "occurredAt": 5_600]],
    ]
    let encoder = JSONEncoder()
    object["gitFactsAtDelegation"] = try JSONSerialization.jsonObject(with: encoder.encode(before))
    object["gitFactsAtReturn"] = try JSONSerialization.jsonObject(with: encoder.encode(after))
    let handoff = try JSONDecoder().decode(RelayHandoff.self, from: try JSONSerialization.data(withJSONObject: object))
    let markdown = CollaborationHistoryMarkdown.document(handoffs: [handoff], scopeName: "Git")
    try gitExpect(markdown.contains("  - `evil\\n- Injected: line`"), "export did not show the escaped newline path")
    try gitExpect(markdown.contains("  - `\\e[2Jcleared.txt`"), "export did not show the escaped ESC path")
    try gitExpect(!markdown.contains("\u{1b}"), "export emitted a raw ESC byte")
    try gitExpect(!markdown.split(separator: "\n").contains(where: { $0.hasPrefix("- Injected") }), "a path injected its own Markdown line")
}

func checkDelegationGitFactsSurviveFastCompletionDuringSubmit() throws {
    let directory = try gitDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalFile = directory.appendingPathComponent("handoffs.jsonl")
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: journalFile)
    func pane(_ id: String, _ kind: PaneKind, _ name: String) -> WorkbenchPane {
        WorkbenchPane(
            id: id, kind: kind, customName: name, terminalTitle: "", cwd: directory.path, currentCommand: "x",
            isActive: false, workspaceID: "@fast", relayEnabled: true,
            protocolVersion: AgentProtocol.version, workspaceName: "Fast", inputAvailable: true
        )
    }
    let owner = pane("%owner", .codex, "Owner")
    let implementer = pane("%implementer", .claude, "Implementer")
    let ownerToken = try credentials.token(for: owner.id)
    let implementerToken = try credentials.token(for: implementer.id)

    let atDelegation = snapshot(folder: directory.path, paths: ["start.swift"])
    let atReturn = snapshot(folder: directory.path, paths: ["start.swift", "end.swift"], at: 5_200)
    let facts = GitRaceBox<[DelegationGitSnapshot]>()
    facts.set([atDelegation, atReturn])
    let inputBegan = DispatchSemaphore(value: 0)
    let releaseSubmit = DispatchSemaphore(value: 0)
    let submitMode = GitRaceBox<String>()
    submitMode.set("block")
    struct SubmitFailure: Error {}
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [owner, implementer] },
        paste: { _, _ in },
        submit: { _, _ in
            if submitMode.value == "throw" { throw SubmitFailure() }
            inputBegan.signal()
            _ = releaseSubmit.wait(timeout: .now() + 5)
        },
        gitFacts: { _ in
            var remaining = facts.value ?? []
            let next = remaining.isEmpty ? nil : remaining.removeFirst()
            facts.set(remaining)
            return next
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    // 1. The target reports done while submit is still unwinding.
    let response = GitRaceBox<RelayResponse>()
    DispatchQueue.global(qos: .utility).async {
        response.set(broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Fast work.", idempotencyKey: "git-fast-1"))
    }
    try gitExpect(inputBegan.wait(timeout: .now() + 3) == .success, "submit never began")
    let created = try gitRequire(broker.handoffs().first(where: { $0.text == "Fast work." }), "the delegation was not recorded before submit")
    let done = broker.handleDelegationResult(token: implementerToken, handoffID: "current", text: "Fast done.", succeeded: true)
    try gitExpect(done.status == 200, "the fast target could not report while submit was unwinding: \(done.text)")
    releaseSubmit.signal()
    try gitExpect(gitEventually { response.value != nil }, "handleDelegate did not return after submit was released")
    let outcome = try gitRequire(response.value, "no delegate response")
    try gitExpect(outcome.body.handoffID == created.id && outcome.body.state == .completed, "the delegate response did not reflect the already-completed outcome: \(outcome.status) \(String(describing: outcome.body.state))")

    let inMemory = try gitRequire(broker.handoffs().first(where: { $0.id == created.id }), "the fast delegation disappeared")
    try gitExpect(inMemory.state == .completed && inMemory.resultText == "Fast done.", "the fast completion outcome was altered")
    try gitExpect(inMemory.transitions.map(\.state) == [.created, .completed], "a duplicate or late transition was appended: \(inMemory.transitions.map(\.state))")
    try gitExpect(inMemory.gitFactsAtDelegation == atDelegation && inMemory.gitFactsAtReturn == atReturn, "in-memory record lost a snapshot")
    let reloaded = try RelayHandoffJournal(file: journalFile)
    let durable = try gitRequire(reloaded.handoffs().first(where: { $0.id == created.id }), "the journal lost the fast delegation")
    try gitExpect(durable.gitFactsAtDelegation == atDelegation, "the reloaded journal is missing the delegation-time snapshot")
    try gitExpect(durable.gitFactsAtReturn == atReturn, "the reloaded journal is missing the return-time snapshot")
    try gitExpect(durable.state == .completed && durable.transitions.map(\.state) == [.created, .completed], "the journal recorded a different outcome or history: \(durable.transitions.map(\.state))")

    // 2. A submit failure after capture still journals the delegation-time snapshot with the failed outcome.
    facts.set([atDelegation])
    submitMode.set("throw")
    let failed = broker.handleDelegate(token: ownerToken, target: implementer.id, text: "Cannot deliver.", idempotencyKey: "git-fast-2")
    try gitExpect(failed.status != 200 && failed.body.state == .failed, "a failed submit did not report failure: \(failed.status)")
    let failedID = try gitRequire(failed.body.handoffID, "failed delegation returned no id")
    let failedDurable = try gitRequire(try RelayHandoffJournal(file: journalFile).handoffs().first(where: { $0.id == failedID }), "the journal lost the failed delegation")
    try gitExpect(failedDurable.state == .failed && failedDurable.gitFactsAtDelegation == atDelegation, "a failed delivery lost its delegation-time snapshot in the journal")
    try gitExpect(failedDurable.transitions.map(\.state) == [.created, .failed], "a failed delivery gained extra transitions: \(failedDurable.transitions.map(\.state))")
}

func checkDelegationGitPathDisplayEscapesUnicodeFormatControls() throws {
    let cases: [(String, String)] = [
        ("csi\u{9b}31m.txt", "csi\\u{009b}31m.txt"),
        ("pad\u{80}.txt", "pad\\u{0080}.txt"),
        ("apc\u{9f}.txt", "apc\\u{009f}.txt"),
        ("safe.txt\u{202e}txt.evil", "safe.txt\\u{202e}txt.evil"),
        ("iso\u{2066}late.txt", "iso\\u{2066}late.txt"),
        ("zero\u{200b}width.txt", "zero\\u{200b}width.txt"),
        ("bom\u{feff}.txt", "bom\\u{feff}.txt"),
        ("soft\u{ad}hyphen.txt", "soft\\u{00ad}hyphen.txt"),
        ("arabic\u{61c}mark.txt", "arabic\\u{061c}mark.txt"),
        ("tag\u{e0041}.txt", "tag\\u{e0041}.txt"),
        ("interlinear\u{fff9}.txt", "interlinear\\u{fff9}.txt"),
    ]
    for (raw, expected) in cases {
        let display = DelegationGitFacts.displayPath(raw)
        try gitExpect(display == expected, "display projection for \(raw.debugDescription) was \(display.debugDescription), expected \(expected.debugDescription)")
    }
    let everything = cases.map(\.0).joined(separator: "/") + "\u{1b}\u{2028}\u{2029}\u{85}\n\t"
    let projected = DelegationGitFacts.displayPath(everything)
    try gitExpect(
        !projected.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        },
        "a control, format, line-separator or paragraph-separator scalar survived the display projection"
    )

    // Distinct raw paths stay distinguishable, including text that merely looks escaped.
    let raws = ["ab", "a\u{202e}b", "a\u{2066}b", "a\u{200b}b", "a\\u{202e}b", "a\u{9b}b"]
    let displays = raws.map(DelegationGitFacts.displayPath)
    try gitExpect(Set(displays).count == raws.count, "distinct raw paths collapsed in display: \(displays)")
    try gitExpect(displays[4] == "a\\\\u{202e}b", "a literal escape sequence in a filename was not itself escaped: \(displays[4])")
    try gitExpect(DelegationGitFacts.displayPath("plain/ünïcödé ✓.txt") == "plain/ünïcödé ✓.txt", "ordinary printable non-ASCII was altered")
}
