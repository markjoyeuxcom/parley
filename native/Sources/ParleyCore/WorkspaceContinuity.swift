import Foundation

/// A process-independent identity for workspace presentation preferences.
/// tmux ids are deliberately excluded because they do not survive a new tmux
/// server; Parley updates the name stamp when a unique folder match reveals a
/// rename.
public struct WorkspaceBookmark: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let folder: String

    public init(name: String, folder: String) {
        self.name = name
        self.folder = Self.standardized(folder)
    }

    public init(workspace: TmuxWorkspace) {
        self.init(name: workspace.name, folder: workspace.defaultFolder)
    }

    fileprivate func exactlyMatches(_ workspace: TmuxWorkspace) -> Bool {
        name.caseInsensitiveCompare(workspace.name) == .orderedSame
            && folder == Self.standardized(workspace.defaultFolder)
    }

    fileprivate func folderMatches(_ workspace: TmuxWorkspace) -> Bool {
        folder == Self.standardized(workspace.defaultFolder)
    }

    fileprivate static func standardized(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.path
    }
}

/// The small durable preference layer over live tmux workspaces. Reconciliation
/// never creates, closes, or selects a process; it only orders live values and
/// resolves a previously selected bookmark.
public struct WorkspaceContinuityState: Codable, Equatable, Sendable {
    public private(set) var favouriteFolders: [String]
    public private(set) var workspaceOrder: [WorkspaceBookmark]
    public private(set) var lastSelected: WorkspaceBookmark?

    public init(
        favouriteFolders: [String] = [],
        workspaceOrder: [WorkspaceBookmark] = [],
        lastSelected: WorkspaceBookmark? = nil
    ) {
        self.favouriteFolders = Self.normalizedFolders(favouriteFolders)
        self.workspaceOrder = workspaceOrder
        self.lastSelected = lastSelected
    }

    /// Applies the saved order to the live set, prunes closed workspaces, and
    /// appends newly discovered workspaces in tmux's own order.
    @discardableResult
    public mutating func reconcile(_ workspaces: [TmuxWorkspace]) -> [TmuxWorkspace] {
        favouriteFolders = Self.normalizedFolders(favouriteFolders)
        var remaining = workspaces
        var ordered: [TmuxWorkspace] = []
        for bookmark in workspaceOrder {
            guard let index = Self.match(bookmark, in: remaining) else { continue }
            ordered.append(remaining.remove(at: index))
        }
        ordered.append(contentsOf: remaining)
        workspaceOrder = ordered.map(WorkspaceBookmark.init(workspace:))
        if let lastSelected,
           let selectedIndex = Self.match(lastSelected, in: workspaces) {
            self.lastSelected = WorkspaceBookmark(workspace: workspaces[selectedIndex])
        } else if lastSelected != nil {
            self.lastSelected = nil
        }
        return ordered
    }

    public func selectedWorkspace(in workspaces: [TmuxWorkspace]) -> TmuxWorkspace? {
        guard let lastSelected,
              let index = Self.match(lastSelected, in: workspaces) else { return nil }
        return workspaces[index]
    }

    public mutating func markSelected(_ workspace: TmuxWorkspace) {
        lastSelected = WorkspaceBookmark(workspace: workspace)
    }

    /// Carries presentation identity through a successful native rename or
    /// default-folder change without moving the tab or forgetting selection.
    public mutating func updateWorkspace(from previous: TmuxWorkspace, to updated: TmuxWorkspace) {
        let previousBookmark = WorkspaceBookmark(workspace: previous)
        let updatedBookmark = WorkspaceBookmark(workspace: updated)
        if let index = workspaceOrder.firstIndex(of: previousBookmark) {
            workspaceOrder[index] = updatedBookmark
        }
        if lastSelected == previousBookmark {
            lastSelected = updatedBookmark
        }
    }

    /// Moves one visual tab by a signed offset. Boundary moves are no-ops.
    @discardableResult
    public mutating func moveWorkspace(
        id: String,
        by offset: Int,
        in workspaces: [TmuxWorkspace]
    ) -> [TmuxWorkspace] {
        guard let source = workspaces.firstIndex(where: { $0.id == id }) else { return workspaces }
        let destination = source + offset
        guard workspaces.indices.contains(destination) else { return workspaces }
        var moved = workspaces
        let workspace = moved.remove(at: source)
        moved.insert(workspace, at: destination)
        workspaceOrder = moved.map(WorkspaceBookmark.init(workspace:))
        return moved
    }

    /// Returns the resulting favourite state (`true` when added).
    @discardableResult
    public mutating func toggleFavourite(folder: String) -> Bool {
        let standardized = WorkspaceBookmark.standardized(folder)
        guard standardized.hasPrefix("/") else { return false }
        if let index = favouriteFolders.firstIndex(of: standardized) {
            favouriteFolders.remove(at: index)
            return false
        }
        favouriteFolders.append(standardized)
        return true
    }

    private static func match(_ bookmark: WorkspaceBookmark, in workspaces: [TmuxWorkspace]) -> Int? {
        if let exact = workspaces.firstIndex(where: bookmark.exactlyMatches) { return exact }
        let folderMatches = workspaces.indices.filter { bookmark.folderMatches(workspaces[$0]) }
        return folderMatches.count == 1 ? folderMatches[0] : nil
    }

    private static func normalizedFolders(_ folders: [String]) -> [String] {
        var seen: Set<String> = []
        return folders.compactMap { folder in
            let standardized = WorkspaceBookmark.standardized(folder)
            guard standardized.hasPrefix("/"), seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }
}
