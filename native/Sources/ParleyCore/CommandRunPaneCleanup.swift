import Foundation

/// Decides, from facts only, when the native app may remove the Shell pane of
/// a finished command run. A pane is removed only when its worker was staged
/// to end the pane's process after a clean result (so no interactive shell
/// was ever handed to the person), the run's clean result is saved, the
/// worker's lease is released, and the pane Parley created still has that
/// exact generation. Ghostty forces wait-after-command on every surface
/// created with a command, so the surface itself keeps showing "Process
/// exited" and never reports its process as ended; in exit-when-clean mode
/// the released lease is the fact that the worker exited without exec'ing a
/// shell, and nothing runs behind the surface. Every other outcome keeps the
/// pane, and a pane the person restarted is theirs. The decision is
/// remembered so a run is closed at most once and a close that keeps
/// failing is given up.
public struct CommandRunPaneCleanup: Sendable {
    public struct PaneFacts: Equatable, Sendable {
        public let id: String
        public let launchGeneration: Int
        public let isStarted: Bool
        public let isDead: Bool
        public init(id: String, launchGeneration: Int, isStarted: Bool, isDead: Bool) {
            self.id = id
            self.launchGeneration = launchGeneration
            self.isStarted = isStarted
            self.isDead = isDead
        }
        public var processEnded: Bool { isDead || !isStarted }
    }

    public struct Launch: Equatable, Sendable {
        public let paneID: String
        public let paneGeneration: Int
        public let exitsWhenClean: Bool
        public let previousActivePaneID: String?
        public init(paneID: String, paneGeneration: Int, exitsWhenClean: Bool, previousActivePaneID: String?) {
            self.paneID = paneID
            self.paneGeneration = paneGeneration
            self.exitsWhenClean = exitsWhenClean
            self.previousActivePaneID = previousActivePaneID
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Remove this pane, whose process has ended, and give focus back.
        case close(runID: String, paneID: String, restoreTo: String?)
        /// Final: the pane stays, for this reason.
        case keep(runID: String, reason: String)
        /// Not yet decidable: the worker still holds its lease.
        case wait(runID: String)
    }

    public static let maximumCloseAttempts = 3
    private static let maximumRememberedPanes = 256
    private var launches: [String: Launch] = [:]
    private var settled: Set<String> = []
    private var closeAttempts: [String: Int] = [:]
    /// Every run pane this session created, mapped to the pane that was
    /// active when it was created, kept after the pane is gone so a later
    /// close can find the nearest surviving predecessor of a chain.
    private var predecessors: [String: String?] = [:]
    private var predecessorOrder: [String] = []

    public init() {}

    public mutating func recordLaunch(runID: String, paneID: String, paneGeneration: Int, exitsWhenClean: Bool, previousActivePaneID: String?) {
        launches[runID] = Launch(paneID: paneID, paneGeneration: paneGeneration, exitsWhenClean: exitsWhenClean, previousActivePaneID: previousActivePaneID)
        if predecessors.updateValue(previousActivePaneID, forKey: paneID) == nil { predecessorOrder.append(paneID) }
        while predecessorOrder.count > Self.maximumRememberedPanes {
            predecessors.removeValue(forKey: predecessorOrder.removeFirst())
        }
    }

    /// The pane focus should return to: the recorded predecessor, or, when
    /// that pane was itself a run pane that no longer exists, the nearest
    /// surviving pane up its own chain. Nil when nothing survives.
    public func restoreTarget(from previous: String?, panes: [PaneFacts]) -> String? {
        let existing = Set(panes.map(\.id))
        var candidate = previous
        var visited: Set<String> = []
        while let pane = candidate, !existing.contains(pane) {
            guard !visited.contains(pane), let next = predecessors[pane] else { return nil }
            visited.insert(pane)
            candidate = next
        }
        return candidate
    }

    public func launch(for runID: String) -> Launch? { launches[runID] }
    public func isSettled(_ runID: String) -> Bool { settled.contains(runID) }
    public func attempts(for runID: String) -> Int { closeAttempts[runID] ?? 0 }

    /// One pass over the current facts. `keep` results are final and are not
    /// reported again; `close` is reported until `didClose` or the attempt
    /// limit settles it. Closes come newest first, so a chain of run panes
    /// (A active, run B created from A, run C created from B) unwinds C then
    /// B and lands back on A; each close's restore target is resolved
    /// against the panes that survive.
    public mutating func decisions(runs: [ReviewedCommandRun], panes: [PaneFacts]) -> [Decision] {
        var result: [Decision] = []
        let paneByID = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for run in runs.sorted(by: { $0.createdAt > $1.createdAt }) where run.state.isTerminal && !settled.contains(run.id) {
            guard let launch = launches[run.id] else {
                result.append(settle(run.id, "the run was not launched by this app session")); continue
            }
            guard launch.exitsWhenClean else {
                result.append(settle(run.id, "the run's pane was handed to an interactive shell")); continue
            }
            guard run.state == .completed, let captured = run.result, ReviewedCommandRunPaneClosePolicy.isClean(captured) else {
                result.append(settle(run.id, "the run did not finish cleanly")); continue
            }
            guard run.resultSaved else {
                result.append(settle(run.id, "the run's result could not be saved")); continue
            }
            if run.workerStillRunning { result.append(.wait(runID: run.id)); continue }
            guard let pane = paneByID[run.shellPaneID] else {
                result.append(settle(run.id, "the pane is already gone")); continue
            }
            guard pane.launchGeneration == launch.paneGeneration else {
                result.append(settle(run.id, "the pane was restarted by the person")); continue
            }
            // No process remains: the worker exited instead of exec'ing a shell.
            result.append(.close(runID: run.id, paneID: pane.id, restoreTo: restoreTarget(from: launch.previousActivePaneID, panes: panes)))
        }
        return result
    }

    public mutating func didClose(runID: String) {
        settled.insert(runID)
        launches.removeValue(forKey: runID)
        closeAttempts.removeValue(forKey: runID)
    }

    /// Returns true when the tracker has given up on this run.
    @discardableResult
    public mutating func didFailToClose(runID: String) -> Bool {
        let attempts = (closeAttempts[runID] ?? 0) + 1
        closeAttempts[runID] = attempts
        guard attempts >= Self.maximumCloseAttempts else { return false }
        settled.insert(runID)
        launches.removeValue(forKey: runID)
        return true
    }

    private mutating func settle(_ runID: String, _ reason: String) -> Decision {
        settled.insert(runID)
        launches.removeValue(forKey: runID)
        return .keep(runID: runID, reason: reason)
    }
}
