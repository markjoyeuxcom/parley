import Foundation

// The sidebar at many workspaces (Mark's decision, 30 September 2026). The
// current workspace's panes come first, then the workspaces that need the
// person, the pinned ones, the recent ones, and every workspace last. This
// file holds the rules; the view only draws them.

/// What the sidebar shows for one workspace.
public struct WorkspaceActivity: Equatable, Sendable {
    /// Handoffs in progress with a pane of this workspace on either side.
    public var waiting = 0
    /// Failed or interrupted handoffs with a pane of this workspace on either side.
    public var failures = 0
    /// A failed handoff on either side that is waiting on the person.
    public var requiresHumanAttention = false
    /// Unread results returned to a pane of this workspace.
    public var unreadResults = 0
    /// Items that need the person, counted as the menu-bar indicator counts
    /// them (`ExternalAttentionProjection`), so the two never disagree.
    public var needsPerson = 0

    public init() {}
}

/// Every workspace's activity from one pass over the handoffs. The badges
/// used to scan every handoff once per workspace for each count, several
/// times per row and again on every render, which grows with both.
public struct WorkspaceActivityIndex: Sendable {
    public static let empty = WorkspaceActivityIndex(byWorkspace: [:], canonical: [:], validUntil: nil)

    private let byWorkspace: [String: WorkspaceActivity]
    /// A workspace's `id` and `workspaceID` both name it.
    private let canonical: [String: String]
    /// A counted failure or request stops counting a day after it happened,
    /// with no new input; the index must be computed again from then.
    public let validUntil: Date?

    fileprivate init(byWorkspace: [String: WorkspaceActivity], canonical: [String: String], validUntil: Date?) {
        self.byWorkspace = byWorkspace
        self.canonical = canonical
        self.validUntil = validUntil
    }

    public func activity(for reference: String) -> WorkspaceActivity {
        byWorkspace[canonical[reference] ?? reference] ?? WorkspaceActivity()
    }
}

public enum WorkspaceActivityProjection {
    private static let inProgress: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]

    /// `handoffs` is the tick's list, which the waiting and failure badges
    /// have always counted; `unreadHandoffs` the unread results;
    /// `attentionHandoffs` every known handoff, as the menu bar reads them.
    public static func index(workspaces: [WorkbenchWorkspace], panes: [WorkbenchPane], handoffs: [RelayHandoff],
                             unreadHandoffs: [RelayHandoff], attentionHandoffs: [RelayHandoff], now: Date = Date()) -> WorkspaceActivityIndex {
        var canonical: [String: String] = [:]
        for workspace in workspaces {
            canonical[workspace.id] = workspace.workspaceID
            canonical[workspace.workspaceID] = workspace.workspaceID
        }
        func key(_ reference: String) -> String { canonical[reference] ?? reference }
        var byWorkspace: [String: WorkspaceActivity] = [:]
        for handoff in handoffs {
            // A handoff within one workspace counts once for it.
            for workspace in Set([key(handoff.sourceWorkspaceID), key(handoff.targetWorkspaceID)]) {
                if inProgress.contains(handoff.state) { byWorkspace[workspace, default: WorkspaceActivity()].waiting += 1 }
                if handoff.state == .failed || handoff.state == .interrupted {
                    byWorkspace[workspace, default: WorkspaceActivity()].failures += 1
                }
                if handoff.state == .failed, handoff.attention != nil {
                    byWorkspace[workspace, default: WorkspaceActivity()].requiresHumanAttention = true
                }
            }
        }
        for handoff in unreadHandoffs {
            byWorkspace[key(handoff.sourceWorkspaceID), default: WorkspaceActivity()].unreadResults += 1
        }
        let snapshot = ExternalAttentionProjection.snapshot(workspaces: workspaces, panes: panes, handoffs: attentionHandoffs, generatedAt: now)
        for workspace in snapshot.workspaces where workspace.attentionCount > 0 {
            byWorkspace[key(workspace.id), default: WorkspaceActivity()].needsPerson = workspace.attentionCount
        }
        return WorkspaceActivityIndex(byWorkspace: byWorkspace, canonical: canonical, validUntil: snapshot.nextChangeAt)
    }
}

/// The activity index, computed once per input generation however many rows
/// read it, and again once a counted item has aged out.
public struct WorkspaceActivityCache: Sendable {
    private var cachedGeneration: Int?
    private var cached = WorkspaceActivityIndex.empty
    public private(set) var computeCount = 0

    public init() {}

    public mutating func index(generation: Int, now: Date = Date(), compute: () -> WorkspaceActivityIndex) -> WorkspaceActivityIndex {
        if cachedGeneration == generation, cached.validUntil.map({ now < $0 }) ?? true { return cached }
        cached = compute()
        cachedGeneration = generation
        computeCount += 1
        return cached
    }
}

/// One of the person's named groups in All Workspaces (Mark's decision, 30
/// September 2026). Native presentation metadata in the workbench document:
/// it never reaches an agent, grants nothing and closes nothing.
public struct WorkspaceGroup: Identifiable, Equatable, Codable, Sendable {
    public static let maximumNameLength = 64

    public var id: String
    public var name: String
    /// Whether the sidebar shows the group's workspaces; kept with the group
    /// so a person with many workspaces finds them as they left them.
    public var isCollapsed: Bool

    public init(id: String, name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    private enum CodingKeys: String, CodingKey { case id, name, isCollapsed }

    /// A record without its collapsed state reads as expanded: the document
    /// decodes whole, so one strict field would stop the workbench loading.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        isCollapsed = try values.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }

    /// The trimmed name, or why it cannot be used: empty, longer than 64
    /// characters, not one line of text, the sidebar's own "Ungrouped", or
    /// already another group's name (ignoring case), since two of one name
    /// could not be told apart. Only true control characters are refused;
    /// format characters such as an emoji joiner or a direction mark are text.
    public static func validatedName(_ proposed: String, among groups: [WorkspaceGroup], excluding groupID: String? = nil) -> Result<String, WorkspaceGroupNameError> {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty) }
        guard name.count <= maximumNameLength else { return .failure(.tooLong) }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }) else {
            return .failure(.notOneLine)
        }
        guard name.caseInsensitiveCompare("Ungrouped") != .orderedSame else { return .failure(.reserved) }
        guard !groups.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return .failure(.duplicate(name))
        }
        return .success(name)
    }
}

public enum WorkspaceGroupNameError: Error, Equatable, LocalizedError {
    case empty, tooLong, notOneLine, reserved
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "A group needs a name."
        case .tooLong: "A group name can be at most \(WorkspaceGroup.maximumNameLength) characters."
        case .notOneLine: "A group name must be one line of text."
        case .reserved: "Ungrouped is the sidebar's own name for workspaces in no group."
        case let .duplicate(name): "There is already a group named \(name)."
        }
    }
}

/// Which workspaces each sidebar section lists, by `workspaceID`.
public struct WorkspaceSidebarSections: Equatable, Sendable {
    /// A group as All Workspaces shows it: its workspaces in the workspace order.
    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var isCollapsed: Bool
        public var workspaces: [String]
    }
    /// Recent lists at most this many.
    public static let recentLimit = 5
    /// Up to this many workspaces the whole list is short enough to open by
    /// default, and Recent would only repeat it.
    public static let compactLimit = 8

    /// The active workspace, whose panes the sidebar shows first.
    public var current: String?
    /// Other workspaces with something for the person, most first, ties in
    /// the workspace order. The current workspace shows its own.
    public var needsAttention: [String]
    /// Every pinned workspace, current included, in the workspace order.
    public var pinned: [String]
    /// The most recently used others, newest first: never the current, a
    /// pinned or a needs-attention workspace, which already have a place.
    public var recent: [String]
    /// Every workspace in the person's order.
    public var all: [String]
    public var allExpandedByDefault: Bool
    /// The person's groups in their order, empty ones included so they can be
    /// deleted. Empty when there are no groups: All is then a plain list.
    public var groups: [Group] = []
    /// Workspaces in no group, or in one that no longer exists.
    public var ungrouped: [String] = []

    public static func derive(workspaces: [WorkbenchWorkspace], groups workspaceGroups: [WorkspaceGroup] = [],
                              needsPerson: (String) -> Int) -> WorkspaceSidebarSections {
        let current = workspaces.first(where: \.isActive)?.workspaceID
        let order = Dictionary(workspaces.enumerated().map { ($1.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        let attention = workspaces
            .filter { $0.workspaceID != current }
            .map { (id: $0.workspaceID, count: needsPerson($0.workspaceID)) }
            .filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : order[$0.id, default: 0] < order[$1.id, default: 0] }
            .map(\.id)
        let compact = workspaces.count <= compactLimit
        var recent: [String] = []
        if !compact {
            let placed = Set(attention).union([current].compactMap { $0 })
            recent = workspaces
                .filter { !$0.pinned && !placed.contains($0.workspaceID) && $0.lastSelectedAt != nil }
                .sorted { $0.lastSelectedAt! > $1.lastSelectedAt! }
                .prefix(recentLimit)
                .map(\.workspaceID)
        }
        let known = Set(workspaceGroups.map(\.id))
        let members = Dictionary(grouping: workspaces.filter { $0.groupID.map(known.contains) ?? false }, by: { $0.groupID! })
        return WorkspaceSidebarSections(
            current: current,
            needsAttention: attention,
            pinned: workspaces.filter(\.pinned).map(\.workspaceID),
            recent: recent,
            all: workspaces.map(\.workspaceID),
            allExpandedByDefault: compact,
            groups: workspaceGroups.map {
                Group(id: $0.id, name: $0.name, isCollapsed: $0.isCollapsed, workspaces: (members[$0.id] ?? []).map(\.workspaceID))
            },
            ungrouped: workspaces.filter { !($0.groupID.map(known.contains) ?? false) }.map(\.workspaceID)
        )
    }

    /// A drag within Pinned, carried out on the whole workspace order.
    public static func pinnedMove(source: Int, destination: Int, pinned: [String], all: [String]) -> (source: Int, destination: Int)? {
        subsetMove(source: source, destination: destination, subset: pinned, all: all)
    }

    /// A drag within a list that shows part of the workspace order (Pinned or
    /// a group), as SwiftUI's `onMove` reports it (`destination` is the
    /// position the item is dropped before), carried out on the whole order:
    /// the moved workspace goes just before the one it was dropped before, or
    /// just after the subset's last. Returns the `onMove` offsets for the
    /// whole list, or nil for no move.
    public static func subsetMove(source: Int, destination: Int, subset: [String], all: [String]) -> (source: Int, destination: Int)? {
        guard subset.indices.contains(source), (0...subset.count).contains(destination),
              destination != source, destination != source + 1,
              let from = all.firstIndex(of: subset[source]) else { return nil }
        let to: Int
        if destination == subset.count {
            guard let last = subset.last, let lastIndex = all.firstIndex(of: last) else { return nil }
            to = lastIndex + 1
        } else {
            guard let before = all.firstIndex(of: subset[destination]) else { return nil }
            to = before
        }
        return (from, to)
    }
}

public enum WorkspaceRecency {
    /// When a Recent row's workspace was last used: the time today, the
    /// weekday within the last week and the date before that. A relative age
    /// ("2h") went stale on an idle sidebar, which redraws only when the model
    /// changes, and so would "Yesterday", which DateFormatter also works out
    /// from the real clock rather than `now`; a time or a weekday stays true.
    public static func label(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if calendar.isDate(date, inSameDayAs: now) || date > now {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEE" : "d MMM")
        return formatter.string(from: date)
    }
}
