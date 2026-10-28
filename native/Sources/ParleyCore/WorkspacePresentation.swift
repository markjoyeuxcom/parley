import Foundation

/// How a workspace arranges its panes on screen: every pane at once in the
/// split tree (Grid), or one pane at a time behind a strip of tabs (Tabs).
///
/// Presentation only. It never starts, stops, moves or resizes a process by
/// itself, it never changes the split tree, and it never reaches an agent:
/// a pane behind a tab is the same retained terminal as a pane in another
/// workspace, still running and still receiving handoffs. Stored per
/// workspace in the workspace registry next to that workspace's split tree.
public enum WorkspacePresentation: String, Codable, Equatable, Sendable, CaseIterable {
    case grid
    case tabs

    /// A value this build does not know (written by a later Parley) reads as
    /// Grid rather than making the whole registry or archive unreadable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WorkspacePresentation(rawValue: raw) ?? .grid
    }

    public var label: String {
        switch self {
        case .grid: "Grid"
        case .tabs: "Tabs"
        }
    }

    public var toggled: WorkspacePresentation {
        switch self {
        case .grid: .tabs
        case .tabs: .grid
        }
    }

    /// The title of the action that switches to the other presentation.
    public var toggleTitle: String {
        switch self {
        case .grid: "Show Panes as Tabs"
        case .tabs: "Show Panes as Grid"
        }
    }
}

public enum WorkspaceTabsProjection {
    /// The pane a Tabs workspace shows: the selected pane when it is one of
    /// the workspace's panes, otherwise the first in layout order, so a
    /// workspace with panes never shows an empty tab.
    public static func shownPaneID(activePaneID: String?, orderedPaneIDs: [String]) -> String? {
        if let activePaneID, orderedPaneIDs.contains(activePaneID) { return activePaneID }
        return orderedPaneIDs.first
    }
}
