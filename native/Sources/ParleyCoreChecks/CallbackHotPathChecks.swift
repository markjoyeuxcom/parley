import Darwin
import Foundation
import ParleyCore

private func pathExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "CallbackHotPath", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func pathRejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "CallbackHotPath", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func pathInode(_ path: String) -> UInt64 {
    var metadata = stat()
    return Darwin.lstat(path, &metadata) == 0 ? UInt64(metadata.st_ino) : 0
}

private func persistedTitle(stateFile: URL, paneID: String) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any]
    let panes = object?["panes"] as? [[String: Any]] ?? []
    return panes.first { $0["id"] as? String == paneID }?["terminalTitle"] as? String
}

private func pathPane(_ id: String, _ kind: PaneKind, generation: Int = 1) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: kind.rawValue,
        isActive: false, workspaceID: "workspace", relayEnabled: true, workspaceName: "Perf", automationPolicy: .askAndDelegate,
        launchGeneration: generation)
}

private func pathHandoffs(directory: URL, count: Int) throws -> [RelayHandoff] {
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let journal = try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl"), maximumHandoffs: count + 10)
    let source = pathPane("cache-source", .claude)
    let target = pathPane("cache-target", .codex)
    let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in }, handoffJournal: journal)
    let token = try credentials.token(for: source.id)
    for index in 0..<count {
        let response = broker.handle(token: token, target: target.id, text: "message \(index)", idempotencyKey: "cache-relay-\(index)")
        try pathExpect(response.status == 200, "fixture relay \(index) failed")
    }
    return broker.handoffs()
}

func titlePersistenceCoalescingChecks() throws {
    // Titles change many times a second while an agent works. The controller
    // applies each one in memory at once, ignores repeats, and writes the state
    // file at most once per interval; lifecycle persists flush it immediately.
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-title-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    let runtime = root.appendingPathComponent("runtime")
    let stateFile = runtime.appendingPathComponent("workbench-state.json")
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
        titlePersistenceInterval: 0.2)
    _ = try controller.createWorkspace(folder: root.appendingPathComponent("project").path)
    let pane = try controller.createPane(kind: .claude, cwd: root.appendingPathComponent("project").path)
    let other = try controller.createPane(kind: .codex, cwd: root.appendingPathComponent("project").path)
    let baseline = controller.persistWriteCount

    // Unchanged titles are ignored before any runtime mutation; changed ones
    // apply in memory immediately without a write.
    let firstChange = try controller.terminalDidChangeTitle(paneID: pane.id, title: "one")
    try pathExpect(firstChange == true, "a new title was not reported as changed")
    let repeatChange = try controller.terminalDidChangeTitle(paneID: pane.id, title: "one")
    try pathExpect(repeatChange == false, "an identical title was reported as changed")
    let stampBefore = try controller.paneActivityTimestamps()[pane.id]
    usleep(20_000)
    _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "one")
    let stampAfter = try controller.paneActivityTimestamps()[pane.id]
    try pathExpect((stampAfter ?? .distantPast) > (stampBefore ?? .distantPast), "a repeated title no longer counts as activity in memory")
    for index in 0..<200 { _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "burst \(index)") }
    let inMemoryTitle = try controller.listPanes().first { $0.id == pane.id }?.terminalTitle
    try pathExpect(inMemoryTitle == "burst 199", "the latest title was not applied in memory")
    try pathExpect(controller.persistWriteCount == baseline, "a title burst wrote the state file \(controller.persistWriteCount - baseline) times before the interval")
    try pathExpect((try persistedTitle(stateFile: stateFile, paneID: pane.id)) != "burst 199", "the state file was rewritten synchronously")
    try pathExpect(controller.hasPendingPersistence, "the burst left no pending write")

    // An explicit flush writes exactly once with the latest title.
    controller.flushPendingPersistence()
    try pathExpect(controller.persistWriteCount == baseline + 1 && !controller.hasPendingPersistence, "flush did not write exactly once")
    try pathExpect((try persistedTitle(stateFile: stateFile, paneID: pane.id)) == "burst 199", "flush did not persist the latest title")

    // The interval timer flushes on its own.
    _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "timer")
    try pathExpect(controller.persistWriteCount == baseline + 1, "a single title change wrote synchronously")
    usleep(500_000)
    try pathExpect(controller.persistWriteCount == baseline + 2 && (try persistedTitle(stateFile: stateFile, paneID: pane.id)) == "timer", "the interval timer did not flush the pending title")

    // Any other persist carries the pending title with it and clears the pending flag.
    _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "before-cwd")
    try controller.terminalDidChangeWorkingDirectory(paneID: other.id, path: root.appendingPathComponent("project").path + "/")
    try pathExpect(!controller.hasPendingPersistence && (try persistedTitle(stateFile: stateFile, paneID: pane.id)) == "before-cwd", "a lifecycle persist did not carry the pending title")
    let afterCwd = controller.persistWriteCount
    usleep(400_000)
    try pathExpect(controller.persistWriteCount == afterCwd, "the timer wrote again after another persist had already flushed the title")

    // Stop and close flush immediately; the persisted document is the one a new launch reads.
    _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "before-stop")
    try controller.stopPaneProcess(pane.id)
    try pathExpect(!controller.hasPendingPersistence && (try persistedTitle(stateFile: stateFile, paneID: pane.id)) == "before-stop", "stopping a pane did not flush the pending title")
    let reloaded = try WorkbenchController(applicationDirectory: runtime, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    let reloadedTitle = try reloaded.listPanes().first { $0.id == pane.id }?.terminalTitle
    try pathExpect(reloadedTitle == "before-stop", "a fresh controller did not read the flushed title")

    // A failed deferred write is kept pending and reported, then succeeds later.
    _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "unwritable")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: runtime.path)
    controller.flushPendingPersistence()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    try pathExpect(controller.hasPendingPersistence && controller.lastDeferredPersistenceError != nil, "a failed deferred write was dropped silently")
    controller.flushPendingPersistence()
    try pathExpect(!controller.hasPendingPersistence && controller.lastDeferredPersistenceError == nil && (try persistedTitle(stateFile: stateFile, paneID: pane.id)) == "unwritable",
        "the retried flush did not recover")

    // Shutdown persists and ends deferred writing: a late timer never rewrites the shut-down document.
    _ = try controller.terminalDidChangeTitle(paneID: pane.id, title: "before-shutdown")
    try controller.shutdown()
    let afterShutdown = controller.persistWriteCount
    try pathExpect(!controller.hasPendingPersistence && (try persistedTitle(stateFile: stateFile, paneID: pane.id)) == "before-shutdown", "shutdown did not flush the pending title")
    _ = try? controller.terminalDidChangeTitle(paneID: pane.id, title: "after-shutdown")
    usleep(400_000)
    try pathExpect(controller.persistWriteCount == afterShutdown, "a deferred write ran after shutdown")
}

func attentionProjectionCacheChecks() throws {
    let directory = URL(fileURLWithPath: "/tmp/parley-attn-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Plain relays project no attention; mark every other one failed so the
    // projection has items to cache and to order.
    let handoffs = try pathHandoffs(directory: directory, count: 40).enumerated().map { index, handoff -> RelayHandoff in
        var copy = handoff
        if index % 2 == 0 { copy.state = .failed }
        return copy
    }
    let panes = [pathPane("cache-source", .claude), pathPane("cache-target", .codex)]
    let now = Date()
    var cache = PaneAttentionCache()
    let first = cache.items(generation: 1, panes: panes, handoffs: handoffs, now: now)
    try pathExpect(!first.isEmpty && first == PaneAttentionProjection.items(panes: panes, handoffs: handoffs, now: now), "the cached projection differs from the direct one or is empty")
    let second = cache.items(generation: 1, panes: panes, handoffs: handoffs, now: now.addingTimeInterval(5))
    try pathExpect(second == first && cache.computeCount == 1, "an unchanged generation was recomputed")
    _ = cache.items(generation: 2, panes: panes, handoffs: handoffs, now: now)
    try pathExpect(cache.computeCount == 2, "a new generation did not recompute")
    // A future-dated item (clock skew) keeps today's clamp-at-now ordering by
    // never being served from the cache.
    let skewed = handoffs.map { handoff -> RelayHandoff in
        var copy = handoff
        copy.updatedAt = now.addingTimeInterval(3_600)
        return copy
    }
    let skewedItems = cache.items(generation: 3, panes: panes, handoffs: skewed, now: now)
    try pathExpect(skewedItems.contains { $0.occurredAt > now }, "the fixture produced no future-dated item")
    _ = cache.items(generation: 3, panes: panes, handoffs: skewed, now: now)
    try pathExpect(cache.computeCount == 4, "future-dated items were served from the cache")
    try pathExpect(skewedItems == PaneAttentionProjection.items(panes: panes, handoffs: skewed, now: now), "future-dated ordering drifted from the direct projection")
}

func taskManagerSamplingPolicyChecks() throws {
    let identity = [TaskManagerSamplingPolicy.PaneIdentity(paneID: "a", launchGeneration: 1), TaskManagerSamplingPolicy.PaneIdentity(paneID: "b", launchGeneration: 2)]
    try pathExpect(TaskManagerSamplingPolicy.shouldPublish(resultGeneration: 3, latestRequest: 3, sampledIdentity: identity, currentIdentity: identity), "a current sample was not published")
    try pathExpect(!TaskManagerSamplingPolicy.shouldPublish(resultGeneration: 2, latestRequest: 3, sampledIdentity: identity, currentIdentity: identity), "a superseded sample was published")
    let restarted = [identity[0], TaskManagerSamplingPolicy.PaneIdentity(paneID: "b", launchGeneration: 3)]
    try pathExpect(!TaskManagerSamplingPolicy.shouldPublish(resultGeneration: 3, latestRequest: 3, sampledIdentity: identity, currentIdentity: restarted), "a sample taken before a pane restart was published")
    try pathExpect(!TaskManagerSamplingPolicy.shouldPublish(resultGeneration: 3, latestRequest: 3, sampledIdentity: identity, currentIdentity: Array(identity.prefix(1))), "a sample taken before a pane closed was published")
    try pathExpect(TaskManagerSamplingPolicy.shouldResample(afterCompleting: 2, latestRequest: 3), "a request made during sampling was dropped")
    try pathExpect(!TaskManagerSamplingPolicy.shouldResample(afterCompleting: 3, latestRequest: 3), "sampling looped without a newer request")

    // The serial owner never overlaps samples and keeps CPU baselines between them.
    let owner = TaskManagerSamplingOwner()
    let pid = ProcessInfo.processInfo.processIdentifier
    let descriptor = TaskManagerPaneDescriptor(paneID: "self", workspaceID: "w", workspaceName: "W", paneName: "Self", kind: .shell,
        workingDirectory: "/tmp", isSelected: true, isStarted: true, foregroundPID: pid, ttyName: nil, ttyDevice: nil)
    final class SampleBox: @unchecked Sendable {
        let lock = NSLock()
        let group = DispatchGroup()
        var snapshots: [TaskManagerSnapshot] = []
    }
    let box = SampleBox()
    for _ in 0..<3 {
        box.group.enter()
        Task.detached { [box, owner, pid, descriptor] in
            let snapshot = await owner.sample(applicationPID: pid, paneDescriptors: [descriptor])
            box.lock.withLock { box.snapshots.append(snapshot) }
            box.group.leave()
        }
    }
    try pathExpect(box.group.wait(timeout: .now() + 20) == .success, "concurrent samples did not complete")
    let snapshots = box.lock.withLock { box.snapshots }
    try pathExpect(snapshots.count == 3 && Set(snapshots.map(\.sampledAt)).count == 3, "samples overlapped or were dropped")
    try pathExpect(snapshots.allSatisfy { $0.processCount > 0 }, "a sample read no processes")
}

func activityJournalAppendChecks() throws {
    // Records append one durable line each; the bounded file is rewritten only
    // by compaction, and every failure or replay semantic stays as before.
    let directory = URL(fileURLWithPath: "/tmp/parley-actj-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("activity-events.jsonl")
    func event(_ index: Int) -> RelayActivityEvent {
        RelayActivityEvent(id: "event-\(index)", kind: .paneRestarted, occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
            workspaceID: "@0", workspaceName: "api", paneID: "%1", paneName: "Codex", paneKind: .codex, detail: "event \(index)")
    }
    let journal = try RelayActivityJournal(file: file, maximumEvents: 3)
    try journal.record(event(1))
    let inodeAfterFirst = pathInode(file.path)
    let sizeAfterFirst = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    try journal.record(event(2))
    try pathExpect(pathInode(file.path) == inodeAfterFirst, "a record rewrote the journal instead of appending")
    let sizeAfterSecond = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    try pathExpect(sizeAfterSecond > sizeAfterFirst, "the append did not grow the file")
    let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n").count
    try pathExpect(lines == 2, "the file did not hold one line per record: \(lines)")

    // Retention prunes the projection at once; the file compacts when the
    // appended lines pass eight times the bound, dropping pruned records.
    for index in 3...30 { try journal.record(event(index)) }
    try pathExpect(journal.events().map(\.id) == ["event-30", "event-29", "event-28"], "retention did not keep the newest three events")
    let linesAfterBurst = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n").count
    try pathExpect(linesAfterBurst <= 3 * 8, "the file was never compacted: \(linesAfterBurst) lines")
    try pathExpect(pathInode(file.path) != inodeAfterFirst, "compaction did not replace the file atomically")

    // Replay after appends: last write wins, pruning applies, a truncated tail is repaired.
    let replayed = try RelayActivityJournal(file: file, maximumEvents: 3)
    try pathExpect(replayed.events().map(\.id) == ["event-30", "event-29", "event-28"], "replay after appends lost or reordered events")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"incomplete\"".utf8))
    try handle.close()
    let repaired = try RelayActivityJournal(file: file, maximumEvents: 3)
    let repairedTail = try Data(contentsOf: file)
    try pathExpect(repaired.events().count == 3 && repairedTail.last == 10, "a truncated tail after appends was not repaired")

    // Removal and a smaller bound still rewrite immediately, as before.
    let beforeRemove = pathInode(file.path)
    try pathExpect((try repaired.removeEvents(ids: ["event-29"])) == 1 && pathInode(file.path) != beforeRemove, "removal did not rewrite the journal")
    try pathExpect((try repaired.updateMaximumEvents(1)) == 1 && repaired.events().map(\.id) == ["event-30"], "a smaller bound did not prune durably")

    // A failed append leaves the projection unchanged and throws; recovery works.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    try pathRejects("an unwritable journal accepted a record") { try repaired.record(event(31)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try pathExpect(repaired.events().map(\.id) == ["event-30"], "a failed append changed the in-memory projection")
    try repaired.record(event(32))
    let recovered = try RelayActivityJournal(file: file, maximumEvents: 1)
    try pathExpect(repaired.events().map(\.id) == ["event-32"] && recovered.events().map(\.id) == ["event-32"],
        "the journal did not recover after a failed append")
}

private final class JournalFaults: @unchecked Sendable {
    let lock = NSLock()
    /// Per write call: a positive value writes at most that many bytes, -1 fails with ENOSPC; empty passes through.
    var writePlan: [Int] = []
    var fsyncFails = false
    var truncateFails = false
    var truncateCalls = 0

    var io: RelayActivityJournal.IO {
        RelayActivityJournal.IO(
            write: { [self] descriptor, base, count in
                let plan: Int? = lock.withLock { writePlan.isEmpty ? nil : writePlan.removeFirst() }
                guard let plan else { return Darwin.write(descriptor, base, count) }
                if plan < 0 { errno = ENOSPC; return -1 }
                return Darwin.write(descriptor, base, min(plan, count))
            },
            fsync: { [self] descriptor in
                if lock.withLock({ fsyncFails }) { errno = EIO; return -1 }
                return Darwin.fsync(descriptor)
            },
            truncate: { [self] descriptor, size in
                lock.withLock { truncateCalls += 1 }
                if lock.withLock({ truncateFails }) { errno = EIO; return -1 }
                return Darwin.ftruncate(descriptor, size)
            })
    }
}

private func journalEvent(_ index: Int) -> RelayActivityEvent {
    RelayActivityEvent(id: "event-\(index)", kind: .paneRestarted, occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
        workspaceID: "@0", workspaceName: "api", paneID: "%1", paneName: "Codex", paneKind: .codex, detail: "event \(index)")
}

private func fileSize(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
}

func activityJournalFaultRecoveryChecks() throws {
    // A failed append must never leave partial bytes that a later acknowledged
    // append would fuse into an invalid record: the committed boundary is
    // restored, an unrestorable tail is repaired before any further append,
    // and a failed repair refuses instead of acknowledging.
    let directory = URL(fileURLWithPath: "/tmp/parley-actf-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("activity-events.jsonl")
    let faults = JournalFaults()
    let journal = try RelayActivityJournal(file: file, maximumEvents: 10, io: faults.io)
    try journal.record(journalEvent(1))
    let committed = fileSize(file.path)

    // Partial write then ENOSPC: boundary restored, nothing acknowledged.
    faults.lock.withLock { faults.writePlan = [10, -1] }
    try pathRejects("a partial append was acknowledged") { try journal.record(journalEvent(2)) }
    try pathExpect(fileSize(file.path) == committed, "partial bytes were left after a failed append (\(fileSize(file.path)) vs \(committed))")
    try pathExpect(!journal.hasUncertainTail && journal.events().map(\.id) == ["event-1"], "a restored boundary was reported uncertain or the projection changed")
    try journal.record(journalEvent(3))
    let replayA = try RelayActivityJournal(file: file, maximumEvents: 10)
    try pathExpect(replayA.events().map(\.id) == ["event-3", "event-1"], "replay after a partial failure and a later append lost or fused records: \(replayA.events().map(\.id))")

    // Partial write and the boundary cannot be restored: the tail is uncertain
    // and is repaired from the acknowledged projection before the next append.
    faults.lock.withLock { faults.writePlan = [10, -1]; faults.truncateFails = true }
    try pathRejects("a partial append with a failed truncate was acknowledged") { try journal.record(journalEvent(4)) }
    try pathExpect(journal.hasUncertainTail, "an unrestorable tail was not marked uncertain")
    faults.lock.withLock { faults.truncateFails = false }
    try journal.record(journalEvent(5))
    try pathExpect(!journal.hasUncertainTail, "the tail was not repaired before the next append")
    let replayB = try RelayActivityJournal(file: file, maximumEvents: 10)
    try pathExpect(replayB.events().map(\.id) == ["event-5", "event-3", "event-1"], "replay after tail repair is wrong: \(replayB.events().map(\.id))")

    // fsync failure is uncertain completion: not acknowledged, boundary restored.
    let beforeSync = fileSize(file.path)
    faults.lock.withLock { faults.fsyncFails = true }
    try pathRejects("an unsynced append was acknowledged") { try journal.record(journalEvent(6)) }
    faults.lock.withLock { faults.fsyncFails = false }
    try pathExpect(fileSize(file.path) == beforeSync && journal.events().map(\.id) == ["event-5", "event-3", "event-1"], "an fsync failure left bytes or changed the projection")
    try journal.record(journalEvent(7))
    try pathExpect((try RelayActivityJournal(file: file, maximumEvents: 10)).events().map(\.id) == ["event-7", "event-5", "event-3", "event-1"], "replay after an fsync failure is wrong")

    // A failed repair refuses further appends explicitly until repair succeeds.
    faults.lock.withLock { faults.writePlan = [10, -1]; faults.truncateFails = true }
    try pathRejects("a partial append with a failed truncate was acknowledged") { try journal.record(journalEvent(8)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    try pathRejects("an append was acknowledged while the tail could not be repaired") { try journal.record(journalEvent(9)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try pathExpect(journal.hasUncertainTail && journal.events().map(\.id) == ["event-7", "event-5", "event-3", "event-1"], "a failed repair acknowledged a record or cleared the uncertain tail")
    faults.lock.withLock { faults.truncateFails = false }
    try journal.record(journalEvent(10))
    try pathExpect(!journal.hasUncertainTail, "repair did not succeed once the directory was writable")
    let replayC = try RelayActivityJournal(file: file, maximumEvents: 10)
    try pathExpect(replayC.events().map(\.id) == ["event-10", "event-7", "event-5", "event-3", "event-1"], "replay after a repaired tail is wrong: \(replayC.events().map(\.id))")
}

func activityJournalRetentionChecks() throws {
    // Records pruned from the projection never come back when retention grows.
    let directory = URL(fileURLWithPath: "/tmp/parley-actr-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("activity-events.jsonl")
    let journal = try RelayActivityJournal(file: file, maximumEvents: 2)
    for index in 1...3 { try journal.record(journalEvent(index)) }
    try pathExpect(journal.events().map(\.id) == ["event-3", "event-2"], "retention did not prune the oldest event")
    try pathExpect((try journal.updateMaximumEvents(100)) == 0, "enlarging retention reported removals")
    let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n").count
    try pathExpect(lines == 2, "enlarging retention left pruned lines on disk: \(lines)")
    let enlarged = try RelayActivityJournal(file: file, maximumEvents: 100)
    try pathExpect(enlarged.events().map(\.id) == ["event-3", "event-2"], "a pruned event resurrected after enlarging retention: \(enlarged.events().map(\.id))")
    for index in 4...5 { try enlarged.record(journalEvent(index)) }
    try pathExpect((try enlarged.updateMaximumEvents(1)) == 3 && enlarged.events().map(\.id) == ["event-5"], "shrinking retention did not prune durably")
    try pathExpect((try enlarged.updateMaximumEvents(1)) == 0, "a no-op retention change reported removals")
    try pathExpect((try RelayActivityJournal(file: file, maximumEvents: 100)).events().map(\.id) == ["event-5"], "shrunk history resurrected on a later enlargement")
}

func activityJournalMaintenanceErrorChecks() throws {
    // A compaction failure after a durable append is acknowledged, surfaced
    // as lastError, and cleared by the next successful compaction.
    let directory = URL(fileURLWithPath: "/tmp/parley-actm-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("activity-events.jsonl")
    let journal = try RelayActivityJournal(file: file, maximumEvents: 2)
    for index in 1...16 { try journal.record(journalEvent(index)) }
    try pathExpect(journal.lastError == nil, "a healthy journal reported an error")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    try journal.record(journalEvent(17))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try pathExpect(journal.events().map(\.id) == ["event-17", "event-16"] && journal.lastError != nil, "a compaction failure was not surfaced or the durable append was dropped")
    try pathExpect((try RelayActivityJournal(file: file, maximumEvents: 2)).events().map(\.id) == ["event-17", "event-16"], "the durable append was lost on replay")
    for index in 18...34 { try journal.record(journalEvent(index)) }
    try pathExpect(journal.lastError == nil, "a successful compaction did not clear the maintenance error")

    // Every successful compaction clears the error: deletion, a retention
    // change and an uncertain-tail repair, not only the periodic one.
    func breakCompaction(_ index: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        // Enough records to pass eight times the bound at max 2 and max 3.
        for step in 0..<40 { try journal.record(journalEvent(index + step)) }
        try pathExpect(journal.lastError != nil, "the fixture did not produce a compaction failure")
    }
    try breakCompaction(100)
    try pathExpect((try journal.removeEvents(ids: ["event-139"])) == 1 && journal.lastError == nil, "a successful deletion left the maintenance error visible")
    try breakCompaction(200)
    try pathExpect((try journal.updateMaximumEvents(3)) == 0 && journal.lastError == nil, "a successful retention change left the maintenance error visible")
    try breakCompaction(300)
    let faults = JournalFaults()
    let faulty = try RelayActivityJournal(file: file, maximumEvents: 3, io: faults.io)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    for step in 0..<25 { try faulty.record(journalEvent(400 + step)) }
    try pathExpect(faulty.lastError != nil, "the fixture did not produce a compaction failure on the fault journal")
    faults.lock.withLock { faults.writePlan = [10, -1]; faults.truncateFails = true }
    try pathRejects("a partial append with a failed truncate was acknowledged") { try faulty.record(journalEvent(500)) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    faults.lock.withLock { faults.truncateFails = false }
    try faulty.record(journalEvent(501))
    try pathExpect(!faulty.hasUncertainTail && faulty.lastError == nil, "an uncertain-tail repair left the maintenance error or the uncertain flag")
}

func taskManagerSamplingCoordinatorChecks() throws {
    // The state machine the model drives: no overlap, no dropped request, no
    // stale publication after a pane change or a newer request.
    let a = [TaskManagerSamplingPolicy.PaneIdentity(paneID: "a", launchGeneration: 1)]
    let b = [TaskManagerSamplingPolicy.PaneIdentity(paneID: "a", launchGeneration: 2)]
    var coordinator = TaskManagerSamplingCoordinator()
    let first = coordinator.request()
    try pathExpect(first == 1, "the first request did not start a sample")
    try pathExpect(coordinator.request() == nil, "a request during sampling started an overlapping sample")
    let outcome = coordinator.complete(generation: 1, sampledIdentity: a, currentIdentity: a)
    try pathExpect(!outcome.publish && outcome.restart == 2, "a superseded sample was published or the pending request was dropped: \(outcome)")
    let settled = coordinator.complete(generation: 2, sampledIdentity: a, currentIdentity: a)
    try pathExpect(settled.publish && settled.restart == nil, "a current sample was not published or looped: \(settled)")
    try pathExpect(coordinator.request() == 3, "an idle coordinator did not start the next request")
    let restarted = coordinator.complete(generation: 3, sampledIdentity: a, currentIdentity: b)
    try pathExpect(!restarted.publish && restarted.restart == 4, "a sample taken before a pane restart was published or not resampled: \(restarted)")
    let final = coordinator.complete(generation: 4, sampledIdentity: b, currentIdentity: b)
    try pathExpect(final.publish && final.restart == nil, "the resample after a pane change was not published: \(final)")

    // A restart the model declines because its consumer is no longer mounted
    // in an active window leaves nothing in flight, so the next request starts
    // fresh instead of waiting on a sample nobody started.
    try pathExpect(coordinator.request() == 5, "an idle coordinator did not start after the resample")
    try pathExpect(coordinator.request() == nil, "a request during sampling started an overlapping sample")
    let declined = coordinator.complete(generation: 5, sampledIdentity: b, currentIdentity: b)
    try pathExpect(declined.restart == 6, "a queued request was not offered as a restart: \(declined)")
    coordinator.declineRestart()
    try pathExpect(coordinator.request() == 7, "declining a restart left the coordinator waiting on a sample nobody started")

    // The serial owner really serializes: an injected process reader records
    // its busy intervals, and concurrent samples never overlap.
    final class Intervals: @unchecked Sendable { let lock = NSLock(); var spans: [(UInt64, UInt64)] = [] }
    let intervals = Intervals()
    let owner = TaskManagerSamplingOwner(readProcesses: {
        let start = DispatchTime.now().uptimeNanoseconds
        usleep(30_000)
        let end = DispatchTime.now().uptimeNanoseconds
        intervals.lock.withLock { intervals.spans.append((start, end)) }
        return []
    })
    let group = DispatchGroup()
    for _ in 0..<3 {
        group.enter()
        Task.detached { [owner, group] in
            _ = await owner.sample(applicationPID: ProcessInfo.processInfo.processIdentifier, paneDescriptors: [])
            group.leave()
        }
    }
    try pathExpect(group.wait(timeout: .now() + 20) == .success, "concurrent samples did not complete")
    let spans = intervals.lock.withLock { intervals.spans.sorted { $0.0 < $1.0 } }
    try pathExpect(spans.count == 3, "a sample was dropped")
    for pair in zip(spans, spans.dropFirst()) {
        try pathExpect(pair.1.0 >= pair.0.1, "two samples overlapped: \(spans)")
    }
}

@MainActor
let callbackHotPathChecks: [(String, () throws -> Void)] = [
    ("activity journal restores the committed boundary and repairs uncertain tails before any further append", activityJournalFaultRecoveryChecks),
    ("activity journal never resurrects pruned history when retention grows", activityJournalRetentionChecks),
    ("activity journal surfaces and clears compaction failures after a durable append", activityJournalMaintenanceErrorChecks),
    ("task manager sampling coordinator never overlaps, drops or publishes stale samples", taskManagerSamplingCoordinatorChecks),
    ("title persistence coalesces bursts, ignores repeats and flushes on lifecycle", titlePersistenceCoalescingChecks),
    ("pane attention projection cache invalidates on generation and never serves future-dated items", attentionProjectionCacheChecks),
    ("task manager sampling is serialized and never publishes stale results", taskManagerSamplingPolicyChecks),
    ("activity journal appends durably and compacts periodically", activityJournalAppendChecks),
]
