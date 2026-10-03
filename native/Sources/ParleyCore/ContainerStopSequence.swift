import Foundation

/// What `ContainerStopSequence` needs from the workbench; `WorkbenchController`
/// provides it, and the checks provide a recording fake.
public protocol ContainerStopEnvironment: AnyObject, Sendable {
    func holdAgainstMove(_ paneIDs: [String]) throws
    func releaseMoveHold(_ paneIDs: [String])
    func prepareContainerStop(_ reviewed: WorkbenchPane, requiringWorkspace: Bool) throws
    func listPanes() throws -> [WorkbenchPane]
}

extension WorkbenchController: ContainerStopEnvironment {}

/// Close, Stop… and the bulk close actions on panes that run containers. The
/// container of each reviewed pane is stopped and removed before the action
/// ends its process, and nothing may move a reviewed pane meanwhile.
///
/// - Building one holds every reviewed pane against a move at once, before
///   any Docker work; a pane already held refuses the whole action.
/// - `run` tries every container, even after one fails, and refuses the
///   action when any failed or any reviewed pane changed (generation, folder
///   or workspace) or went away. Otherwise it runs the action exactly once.
/// - The hold is released when `run` ends, whatever happened.
///
/// Lifted from AppModel's `performAfterContainerStops` after the team review
/// of MR !135 (1 October 2026), so these rules are checked by what they do.
public final class ContainerStopSequence: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case panesChanged
        public var errorDescription: String? { "The panes changed during container cleanup. Review the action again." }
    }

    private let reviewed: [WorkbenchPane]
    private let environment: ContainerStopEnvironment
    private let held: [String]

    public init(reviewed: [WorkbenchPane], environment: ContainerStopEnvironment) throws {
        self.reviewed = reviewed
        self.environment = environment
        held = reviewed.map(\.id)
        try environment.holdAgainstMove(held)
    }

    @MainActor
    public func run(_ operation: @MainActor () throws -> Void) async throws {
        defer { environment.releaseMoveHold(held) }
        var failures: [String] = []
        for pane in reviewed where pane.containerConfiguration != nil {
            let environment = environment
            do {
                try await Task.detached(priority: .userInitiated) {
                    try environment.prepareContainerStop(pane, requiringWorkspace: true)
                }.value
            } catch {
                failures.append("\(pane.displayName): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw ContainerPaneError.refused(failures.joined(separator: "\n")) }
        let current = try environment.listPanes()
        guard reviewed.allSatisfy({ old in current.contains(where: {
            $0.id == old.id && $0.launchGeneration == old.launchGeneration && $0.cwd == old.cwd && $0.workspaceID == old.workspaceID
        }) }) else { throw Failure.panesChanged }
        try operation()
    }
}
