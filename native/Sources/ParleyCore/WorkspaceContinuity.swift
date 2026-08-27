import Foundation

/// Keeps the person's durable path spelling separate from the canonical key
/// used for folder lookup. This avoids rewriting visible /tmp-style paths while
/// still recognising filesystem aliases as one directory.
public enum WorkspaceFolderIdentity {
    public static func normalized(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.path
    }

    public static func matchingKey(_ folder: String) -> String {
        URL(fileURLWithPath: normalized(folder))
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    public static func matches(_ left: String, _ right: String) -> Bool {
        matchingKey(left) == matchingKey(right)
    }

    public static func displayName(for folder: String) -> String {
        let normalized = normalized(folder)
        let component = URL(fileURLWithPath: normalized).lastPathComponent
        return component.isEmpty ? normalized : component
    }
}

public enum WorkspaceFolderOpenResolution: Equatable, Sendable {
    case create
    case focus(String)
    case choose([String])
}

/// Folder opening is a query over stable workspace homes. A directory may
/// intentionally anchor several task workspaces, so ambiguity is surfaced
/// instead of selecting whichever tmux window happens to be first.
public enum WorkspaceFolderRouting {
    public static func matches(folder: String, in workspaces: [TmuxWorkspace]) -> [TmuxWorkspace] {
        workspaces.filter { WorkspaceFolderIdentity.matches($0.homeFolder, folder) }
    }

    public static func resolve(folder: String, in workspaces: [TmuxWorkspace]) -> WorkspaceFolderOpenResolution {
        let ids = matches(folder: folder, in: workspaces).map(\.id)
        return switch ids.count {
        case 0: .create
        case 1: .focus(ids[0])
        default: .choose(ids)
        }
    }
}

/// A process-independent identity for workspace presentation preferences.
/// Live tmux ids are deliberately excluded because they do not survive a new
/// tmux server; the durable @parley-ws-id is preferred when present, and the
/// name/folder pair remains the legacy fallback.
public struct WorkspaceBookmark: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let folder: String
    /// The workspace's durable @parley-ws-id. A live window id is never
    /// stored here: a new tmux server reuses "@N", which would forge
    /// identity across unrelated workspaces.
    public let workspaceID: String?

    public init(name: String, folder: String, workspaceID: String? = nil) {
        self.name = name
        self.folder = Self.standardized(folder)
        self.workspaceID = workspaceID.flatMap { $0.isEmpty || $0.hasPrefix("@") ? nil : $0 }
    }

    public init(workspace: TmuxWorkspace) {
        self.init(
            name: workspace.name,
            folder: workspace.homeFolder,
            workspaceID: workspace.workspaceID == workspace.id ? nil : workspace.workspaceID
        )
    }

    fileprivate func identityMatches(_ workspace: TmuxWorkspace) -> Bool {
        guard let workspaceID else { return false }
        return workspaceID == workspace.workspaceID
    }

    fileprivate func exactlyMatches(_ workspace: TmuxWorkspace) -> Bool {
        name.caseInsensitiveCompare(workspace.name) == .orderedSame
            && WorkspaceFolderIdentity.matches(folder, workspace.homeFolder)
    }

    fileprivate func folderMatches(_ workspace: TmuxWorkspace) -> Bool {
        WorkspaceFolderIdentity.matches(folder, workspace.homeFolder)
    }

    fileprivate static func standardized(_ folder: String) -> String {
        WorkspaceFolderIdentity.normalized(folder)
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
        // A stored bookmark may predate identity stamping, so identity match
        // is accepted alongside strict equality.
        if let index = workspaceOrder.firstIndex(where: {
            $0 == previousBookmark || $0.identityMatches(previous)
        }) {
            workspaceOrder[index] = updatedBookmark
        }
        if lastSelected == previousBookmark || lastSelected?.identityMatches(previous) == true {
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
        if let index = favouriteFolders.firstIndex(where: { WorkspaceFolderIdentity.matches($0, standardized) }) {
            favouriteFolders.remove(at: index)
            return false
        }
        favouriteFolders.append(standardized)
        return true
    }

    /// Adds a favourite without turning an already-saved folder into a remove
    /// action. The sidebar's folder picker uses this idempotent path so adding
    /// a bookmark never changes the active workspace or surprises a person who
    /// selects the same directory twice.
    @discardableResult
    public mutating func addFavourite(folder: String) -> Bool {
        let standardized = WorkspaceBookmark.standardized(folder)
        guard standardized.hasPrefix("/"),
              !favouriteFolders.contains(where: {
                  WorkspaceFolderIdentity.matches($0, standardized)
              }) else {
            return false
        }
        favouriteFolders.append(standardized)
        return true
    }

    private static func match(_ bookmark: WorkspaceBookmark, in workspaces: [TmuxWorkspace]) -> Int? {
        if let identity = workspaces.firstIndex(where: bookmark.identityMatches) { return identity }
        if let exact = workspaces.firstIndex(where: bookmark.exactlyMatches) { return exact }
        let folderMatches = workspaces.indices.filter { bookmark.folderMatches(workspaces[$0]) }
        return folderMatches.count == 1 ? folderMatches[0] : nil
    }

    private static func normalizedFolders(_ folders: [String]) -> [String] {
        var seen: Set<String> = []
        return folders.compactMap { folder in
            let standardized = WorkspaceBookmark.standardized(folder)
            let key = WorkspaceFolderIdentity.matchingKey(standardized)
            guard standardized.hasPrefix("/"), seen.insert(key).inserted else { return nil }
            return standardized
        }
    }
}
