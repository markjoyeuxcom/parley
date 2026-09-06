import Foundation
import ParleyCore

private func cacheExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RegistryCache", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// The refresh tick consults the workspace registry and the permission
/// profile store every second. Unchanged files must be served from memory,
/// and a file another writer replaced must still be noticed.
func registryReadCacheChecks() throws {
    let root = URL(fileURLWithPath: "/tmp/parley-regcache-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("registry.json")
    let registry = WorkspaceRegistry(file: file)
    let workspace = WorkbenchWorkspace(id: "w", name: "W", isActive: true)
    _ = try registry.synchronize(workspaces: [workspace])
    _ = try registry.records() // one refill decode after a write, by design
    let afterWrite = registry.fileReads
    for _ in 0..<5 {
        _ = try registry.records()
        _ = try registry.synchronize(workspaces: [workspace])
        try registry.updateLayout(workspaceID: workspace.workspaceID, layout: nil)
    }
    try cacheExpect(registry.fileReads == afterWrite, "an unchanged registry file was re-read \(registry.fileReads - afterWrite) times across idle ticks")
    // A replacement written by another instance is still noticed and served.
    let other = WorkspaceRegistry(file: file)
    _ = try other.synchronize(workspaces: [workspace, WorkbenchWorkspace(id: "x", name: "X", isActive: false)])
    try cacheExpect(try registry.records().count == 2, "an externally replaced registry file was served from a stale cache")
    try cacheExpect(registry.fileReads == afterWrite + 1, "the replaced registry file was not read exactly once")
    _ = try registry.records()
    try cacheExpect(registry.fileReads == afterWrite + 1, "the registry re-read an unchanged replacement")

    let profileFile = root.appendingPathComponent("permission-profiles.json")
    let store = PermissionProfileStore(file: profileFile)
    let custom = PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!.clone(id: "custom-cache", name: "Cache")
    try store.saveCustom(custom)
    _ = try store.profiles() // one refill decode after a write, by design
    let profilesAfterWrite = store.fileReads
    for _ in 0..<5 { _ = try store.profiles() }
    try cacheExpect(store.fileReads == profilesAfterWrite, "an unchanged profile file was re-read \(store.fileReads - profilesAfterWrite) times")
    let otherStore = PermissionProfileStore(file: profileFile)
    try otherStore.saveCustom(custom.clone(id: "custom-second", name: "Second"))
    try cacheExpect(try store.profiles().contains { $0.id == "custom-second" }, "an externally saved profile was served from a stale cache")
    try cacheExpect(store.fileReads == profilesAfterWrite + 1, "the replaced profile file was not read exactly once")
}

/// A FileManager that lets a check interleave another writer's replacement
/// of the same file right after this writer's chmod, before any post-write
/// stat. That is the window in which a stamp taken from the pathname would
/// describe someone else's bytes.
private final class InterleavingFileManager: FileManager, @unchecked Sendable {
    let targetPath: String
    var afterSetAttributes: (() throws -> Void)?
    init(targetPath: String) {
        self.targetPath = targetPath
        super.init()
    }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        // The file chmod follows the atomic write; the directory chmod precedes it.
        if path == targetPath, let hook = afterSetAttributes {
            afterSetAttributes = nil
            try hook()
        }
    }
}

/// Reproduces Codex's review race: our write, another store's replacement,
/// then our stamp. The next read must serve the disk truth, and later
/// unchanged ticks must still cost zero decodes.
func registryInterleavedWriteChecks() throws {
    let root = URL(fileURLWithPath: "/tmp/parley-regrace-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("registry.json")
    let manager = InterleavingFileManager(targetPath: file.path)
    let registry = WorkspaceRegistry(file: file, fileManager: manager)
    let first = WorkbenchWorkspace(id: "w", name: "W", isActive: true)
    let second = WorkbenchWorkspace(id: "x", name: "X", isActive: false)
    _ = try registry.synchronize(workspaces: [first])
    let external = WorkspaceRegistry(file: file)
    manager.afterSetAttributes = { _ = try external.synchronize(workspaces: [first, second]) }
    try registry.updateLayout(workspaceID: first.workspaceID, layout: nil) // no change: no write, hook untouched
    try cacheExpect(manager.afterSetAttributes != nil, "an unchanged layout wrote the registry")
    _ = try registry.synchronize(workspaces: [first], selectedPaneIDs: [first.workspaceID: "pane-1"]) // changed: write, then the external replacement
    try cacheExpect(manager.afterSetAttributes == nil, "the interleaved replacement did not run")
    try cacheExpect(try registry.records().count == 2, "the registry served its own pre-replacement document under the other writer's file identity")
    let reads = registry.fileReads
    for _ in 0..<3 { _ = try registry.records() }
    try cacheExpect(registry.fileReads == reads, "unchanged reads after the replacement were decoded again")

    let profileFile = root.appendingPathComponent("permission-profiles.json")
    let profileManager = InterleavingFileManager(targetPath: profileFile.path)
    let store = PermissionProfileStore(file: profileFile, fileManager: profileManager)
    let original = PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!.clone(id: "custom-original", name: "Original")
    let externalProfile = original.clone(id: "custom-external", name: "External")
    let externalStore = PermissionProfileStore(file: profileFile)
    profileManager.afterSetAttributes = { try externalStore.saveCustom(externalProfile) }
    try store.saveCustom(original)
    try cacheExpect(profileManager.afterSetAttributes == nil, "the interleaved profile replacement did not run")
    let ids = Set(try store.profiles().map(\.id))
    try cacheExpect(ids.contains("custom-original") && ids.contains("custom-external"), "the profile store omitted another writer's entry: \(ids.filter { $0.hasPrefix("custom") })")
    let profileReads = store.fileReads
    for _ in 0..<3 { _ = try store.profiles() }
    try cacheExpect(store.fileReads == profileReads, "unchanged profile reads after the replacement were decoded again")
}
