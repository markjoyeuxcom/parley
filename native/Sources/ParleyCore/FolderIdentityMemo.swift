import Foundation

/// Canonical folder spellings and folder existence, remembered briefly so a
/// view can compare folders on every render without a realpath and a stat
/// each time. The sidebar used to resolve every favourite against every
/// workspace attachment, and check each favourite and recent folder on disk,
/// whenever it drew. An answer is read again once it is older than
/// `lifetime` seconds of uptime, so a folder that appears, disappears or is
/// re-linked is noticed within that time.
public final class FolderIdentityMemo {
    private struct Entry<Value> {
        let value: Value
        let readAt: TimeInterval
    }

    private let lifetime: TimeInterval
    private let clock: () -> TimeInterval
    private let resolve: (String) -> String
    private let existsCheck: (String) -> Bool
    private var keys: [String: Entry<String>] = [:]
    private var existence: [String: Entry<Bool>] = [:]
    /// Bounds the memo; far above any sidebar's folder count.
    private static let maximumEntries = 1_024

    public init(lifetime: TimeInterval = 5, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                resolve: @escaping (String) -> String = WorkspaceFolderIdentity.matchingKey,
                exists: @escaping (String) -> Bool = { FolderListMaintenance.directoryExists($0) }) {
        self.lifetime = lifetime
        self.clock = clock
        self.resolve = resolve
        self.existsCheck = exists
    }

    /// `WorkspaceFolderIdentity.matches`, remembered.
    public func matches(_ left: String, _ right: String) -> Bool { key(left) == key(right) }

    /// `FolderListMaintenance.directoryExists`, remembered.
    public func exists(_ path: String) -> Bool {
        remembered(path, in: &existence, read: existsCheck)
    }

    /// Whether `folders` holds `folder` under any spelling, as
    /// `AppModel.isFavouriteFolder` decides it, remembered.
    public func contains(_ folder: String, in folders: [String]) -> Bool {
        folders.contains { matches($0, folder) }
    }

    /// Forgets every answer. Parley calls it on each explicit refresh, so a
    /// folder its own action removed or created is read again at once.
    public func invalidate() {
        keys.removeAll(keepingCapacity: true)
        existence.removeAll(keepingCapacity: true)
    }

    /// `WorkspaceFolderRouting.matches`, remembered.
    public func workspaces(matching folder: String, in workspaces: [WorkbenchWorkspace]) -> [WorkbenchWorkspace] {
        workspaces.filter { $0.attachedFolders.contains { matches($0, folder) } }
    }

    private func key(_ path: String) -> String { remembered(path, in: &keys, read: resolve) }

    private func remembered<Value>(_ path: String, in memo: inout [String: Entry<Value>], read: (String) -> Value) -> Value {
        let now = clock()
        if let entry = memo[path], now - entry.readAt < lifetime { return entry.value }
        if memo.count >= Self.maximumEntries { memo.removeAll(keepingCapacity: true) }
        let value = read(path)
        memo[path] = Entry(value: value, readAt: now)
        return value
    }
}
