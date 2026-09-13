import Foundation
import ParleyCore

private func folderExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "FolderList", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A folder that no longer exists is never offered for new panes, removal
/// matches the folder however it was spelled, and order is preserved. The
/// test walkthrough folder from v0.1.26 sat in the recent list for weeks after
/// it was deleted, with no way to clear it.
func folderListMaintenanceChecks() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-folders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let alive = root.appendingPathComponent("alive")
    let gone = root.appendingPathComponent("gone")
    let file = root.appendingPathComponent("a-file.txt")
    try FileManager.default.createDirectory(at: alive, withIntermediateDirectories: true)
    try Data("not a folder".utf8).write(to: file)
    let link = root.appendingPathComponent("link-to-alive")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: alive)

    let recent = [gone.path, alive.path, file.path, link.path]
    let kept = FolderListMaintenance.existing(recent, exists: { FolderListMaintenance.directoryExists($0) })
    try folderExpect(kept == [alive.path, link.path], "pruning kept the wrong entries or reordered them: \(kept)")
    let missing = FolderListMaintenance.missing(recent, exists: { FolderListMaintenance.directoryExists($0) })
    try folderExpect(missing == [gone.path, file.path], "a deleted folder or a plain file was not reported missing: \(missing)")

    // Removal is by folder identity, not by string: the trailing slash and the
    // symlink spelling both name the live folder.
    let list = [alive.path, gone.path, alive.path + "/", link.path]
    let withoutAlive = FolderListMaintenance.removing(alive.path, from: list)
    try folderExpect(!withoutAlive.contains(alive.path) && !withoutAlive.contains(alive.path + "/"),
        "removing a folder left another spelling of it behind: \(withoutAlive)")
    try folderExpect(withoutAlive.contains(gone.path), "removing one folder removed another: \(withoutAlive)")
    try folderExpect(FolderListMaintenance.removing(gone.path, from: list) == [alive.path, alive.path + "/", link.path],
        "removing a missing folder by its recorded path did not remove exactly it")
}

@MainActor
let folderListChecks: [(String, () throws -> Void)] = [
    ("recent and favourite folder lists drop what no longer exists and remove by folder identity", folderListMaintenanceChecks),
]
