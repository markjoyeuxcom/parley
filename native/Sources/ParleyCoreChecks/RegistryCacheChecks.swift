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
    let profilesAfterWrite = store.fileReads
    for _ in 0..<5 { _ = try store.profiles() }
    try cacheExpect(store.fileReads == profilesAfterWrite, "an unchanged profile file was re-read \(store.fileReads - profilesAfterWrite) times")
    let otherStore = PermissionProfileStore(file: profileFile)
    try otherStore.saveCustom(custom.clone(id: "custom-second", name: "Second"))
    try cacheExpect(try store.profiles().contains { $0.id == "custom-second" }, "an externally saved profile was served from a stale cache")
    try cacheExpect(store.fileReads == profilesAfterWrite + 1, "the replaced profile file was not read exactly once")
}
