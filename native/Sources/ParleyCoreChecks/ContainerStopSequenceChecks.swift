import Foundation
import ParleyCore

// Close, Stop… and the bulk close actions stop each reviewed pane's container
// before ending its process (`ContainerStopSequence`). The team review of MR
// !135 (1 October 2026) asked for that orchestration to be tested by what it
// does, not only by reading AppModel's source: hold every reviewed pane before
// anything else, try every container even after one fails, refuse when a pane
// changed meanwhile, run the action exactly once or not at all, and always
// release the hold.

private func sequenceFailure(_ message: String) -> NSError {
    NSError(domain: "ContainerStopSequence", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func sequenceExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw sequenceFailure(message) }
}

/// Records every call in order; container stops and the pane listing can be
/// made to fail or to report a changed pane.
private final class FakeContainerStops: ContainerStopEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }
    var refuseHold = false
    var failingStops: Set<String> = []
    var listed: [WorkbenchPane] = []
    var listError: Error?

    private func record(_ entry: String) { lock.withLock { log.append(entry) } }

    func holdAgainstMove(_ paneIDs: [String]) throws {
        if refuseHold { throw ContainerPaneError.refused("Another action is already stopping or closing this pane.") }
        record("hold \(paneIDs.joined(separator: ","))")
    }

    func releaseMoveHold(_ paneIDs: [String]) { record("release \(paneIDs.joined(separator: ","))") }

    func prepareContainerStop(_ reviewed: WorkbenchPane, requiringWorkspace: Bool) throws {
        record("stop \(reviewed.id) workspace:\(requiringWorkspace)")
        if failingStops.contains(reviewed.id) { throw ContainerPaneError.refused("docker refused") }
    }

    func listPanes() throws -> [WorkbenchPane] {
        record("list")
        if let listError { throw listError }
        return listed
    }
}

private func sequencePane(_ id: String, container: Bool, generation: Int = 1, workspace: String = "w", folder: String? = nil) -> WorkbenchPane {
    WorkbenchPane(
        id: id, kind: container ? .codex : .shell, customName: id, terminalTitle: "", cwd: folder ?? "/private/tmp/\(id)",
        currentCommand: "", isActive: false, workspaceID: workspace, launchGeneration: generation,
        containerConfiguration: container ? ContainerConfiguration(
            dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///var/run/docker.sock", daemonID: "daemon",
            imageID: "sha256:image", imageName: "parley-agents:local", legacyCodexSandbox: false) : nil
    )
}

@MainActor private final class RunCount { var value = 0 }

/// Runs the sequence to its end on the main actor and returns its error.
@MainActor private func runSequence(_ sequence: ContainerStopSequence, _ operation: @escaping @MainActor () throws -> Void) -> Error? {
    var outcome: Error??
    Task { @MainActor in
        do { try await sequence.run(operation); outcome = .some(nil) } catch { outcome = .some(error) }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while outcome == nil && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return outcome ?? sequenceFailure("the sequence did not finish")
}

@MainActor let containerStopSequenceChecks: [(String, () throws -> Void)] = [
    ("container stop sequence: holds every reviewed pane first, stops each container, then runs the action once and releases", {
        let panes = [sequencePane("a", container: true), sequencePane("b", container: false), sequencePane("c", container: true)]
        let fake = FakeContainerStops()
        fake.listed = panes
        let runs = RunCount()
        let sequence = try ContainerStopSequence(reviewed: panes, environment: fake)
        try sequenceExpect(fake.calls == ["hold a,b,c"], "the panes were not held at once, before anything else: \(fake.calls)")
        let error = runSequence(sequence) {
            runs.value += 1
            fake.releaseMoveHold(["(operation ran here)"])
        }
        try sequenceExpect(error == nil && runs.value == 1, "the action did not run exactly once: \(runs.value), \(String(describing: error))")
        try sequenceExpect(fake.calls == ["hold a,b,c", "stop a workspace:true", "stop c workspace:true", "list", "release (operation ran here)", "release a,b,c"],
                           "the steps ran out of order or a shell pane was stopped: \(fake.calls)")
    }),
    ("container stop sequence: a refused container still lets the others stop, and nothing runs", {
        let panes = [sequencePane("a", container: true), sequencePane("b", container: true), sequencePane("c", container: true)]
        let fake = FakeContainerStops()
        fake.listed = panes
        fake.failingStops = ["a"]
        let runs = RunCount()
        let error = runSequence(try ContainerStopSequence(reviewed: panes, environment: fake)) { runs.value += 1 }
        try sequenceExpect(runs.value == 0 && (error?.localizedDescription.contains("a: docker refused") ?? false),
                           "a refused stop ran the action or was not reported: \(runs.value), \(String(describing: error))")
        try sequenceExpect(fake.calls == ["hold a,b,c", "stop a workspace:true", "stop b workspace:true", "stop c workspace:true", "release a,b,c"],
                           "the other containers were not tried, or the hold was kept: \(fake.calls)")
    }),
    ("container stop sequence: a pane that changed during cleanup refuses the action", {
        let reviewed = [sequencePane("a", container: true), sequencePane("b", container: false)]
        // A new generation, another workspace, another folder, or no pane at
        // all: each refuses with the panes-changed error (not a harness
        // timeout) and releases after the listing (Codex's review of MR !143).
        let changes: [(String, [WorkbenchPane])] = [
            ("generation", [reviewed[0], sequencePane("b", container: false, generation: 2)]),
            ("workspace", [reviewed[0], sequencePane("b", container: false, workspace: "elsewhere")]),
            ("folder", [reviewed[0], sequencePane("b", container: false, folder: "/private/tmp/elsewhere")]),
            ("vanished", [reviewed[0]]),
        ]
        for (change, listed) in changes {
            let fake = FakeContainerStops()
            fake.listed = listed
            let runs = RunCount()
            let error = runSequence(try ContainerStopSequence(reviewed: reviewed, environment: fake)) { runs.value += 1 }
            let refused: Bool = { if case .panesChanged? = error as? ContainerStopSequence.Failure { return true } else { return false } }()
            try sequenceExpect(runs.value == 0 && refused && fake.calls == ["hold a,b", "stop a workspace:true", "list", "release a,b"],
                               "a \(change) change did not refuse the action and release: \(runs.value), \(String(describing: error)), \(fake.calls)")
        }
        // A listing that fails refuses and releases too.
        let failing = FakeContainerStops()
        failing.listError = ContainerPaneError.refused("listing failed")
        let runs = RunCount()
        let error = runSequence(try ContainerStopSequence(reviewed: reviewed, environment: failing)) { runs.value += 1 }
        try sequenceExpect(runs.value == 0 && error?.localizedDescription == "listing failed" && failing.calls.last == "release a,b",
                           "a failed listing ran the action or kept the hold: \(runs.value), \(String(describing: error)), \(failing.calls)")
    }),
    ("container stop sequence: a refused hold does nothing, and a failing action still releases", {
        let panes = [sequencePane("a", container: true)]
        let refused = FakeContainerStops()
        refused.refuseHold = true
        do {
            _ = try ContainerStopSequence(reviewed: panes, environment: refused)
            throw sequenceFailure("a refused hold built a sequence")
        } catch ContainerPaneError.refused {}
        try sequenceExpect(refused.calls.isEmpty, "a refused hold went on to stop or release: \(refused.calls)")
        let fake = FakeContainerStops()
        fake.listed = panes
        let error = runSequence(try ContainerStopSequence(reviewed: panes, environment: fake)) { throw sequenceFailure("operation failed") }
        try sequenceExpect(error?.localizedDescription == "operation failed" && fake.calls.last == "release a",
                           "a failing action was not reported, or the hold was kept: \(fake.calls)")
    }),
    ("container stop sequence: AppModel builds the sequence before its task and runs it once", {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ParleyNative/AppModel.swift")
        let reader = SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
        guard let found = reader.text.range(of: "private func performAfterContainerStops("),
              let open = reader.text[found.upperBound...].firstIndex(of: "{"),
              let helper = reader.balanced(at: open) else { throw sequenceFailure("performAfterContainerStops was not found") }
        guard let build = helper.range(of: "try ContainerStopSequence(reviewed: reviewed, environment: controller)"),
              let task = helper.range(of: "Task {") else { throw sequenceFailure("the helper no longer builds the sequence and a task") }
        try sequenceExpect(build.upperBound <= task.lowerBound, "the panes are held only after the task began")
        try sequenceExpect(helper.components(separatedBy: "sequence.run(operation)").count == 2 && !helper.contains("prepareContainerStop"),
                           "the helper must run its operation through the sequence exactly once, and stop no container itself")
    }),
]
