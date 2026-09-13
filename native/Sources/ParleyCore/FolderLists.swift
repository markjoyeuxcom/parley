import Foundation

/// Maintenance for the person's remembered folder lists: the automatic
/// recent-folder history and the explicit favourites. A folder that no
/// longer exists cannot be used for new panes, so it must never be offered,
/// and the person must be able to remove any entry or the whole recent list
/// without waiting for it to age out. Identity is `WorkspaceFolderIdentity`,
/// so a path spelled through a symlink or a trailing slash still matches.
public enum FolderListMaintenance {
    /// The entries that still exist, in their original order. Recent history is
    /// pruned with this; favourites are only reported, because a bookmark on an
    /// unmounted volume is the person's to remove.
    public static func existing(_ folders: [String], exists: (String) -> Bool) -> [String] {
        folders.filter(exists)
    }

    /// The entries that no longer exist, in their original order.
    public static func missing(_ folders: [String], exists: (String) -> Bool) -> [String] {
        folders.filter { !exists($0) }
    }

    /// Removes every entry naming the same folder, however it was spelled.
    public static func removing(_ folder: String, from folders: [String]) -> [String] {
        let target = WorkspaceFolderIdentity.normalized(folder)
        return folders.filter { !WorkspaceFolderIdentity.matches($0, target) }
    }

    /// Whether a directory exists at the path right now. Symlinks are followed,
    /// so a favourite that is a link to a live folder counts as present.
    public static func directoryExists(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
