import Foundation
import ParleyCore

private func restoreExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorkspaceRestore", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func restoreRejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "WorkspaceRestore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Review of 22 September 2026, 18f09032: a layout saved from an Off
/// workspace reopened with delegation allowed, because every restore went
/// through the new-workspace path's default; and a restore that failed
/// part-way left a half-built workspace in memory, after possibly ending the
/// replaced workspace's panes.
func checkLayoutRestoreKeepsPolicyAndRollsBack() throws {
    let root = URL(fileURLWithPath: "/private/tmp/parley-restore-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    let project = root.appendingPathComponent("project"), runtime = root.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        try? FileManager.default.removeItem(at: root)
    }
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    try controller.bootstrap(cwd: project.path)
    final class Terminated: @unchecked Sendable { var ids: [String] = [] }
    let terminated = Terminated()
    controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, interrupt: { _ in }, captureSelectedText: { _ in "" },
        terminate: { terminated.ids.append($0) }, terminateAll: {}))

    let quiet = SavedWorkspaceLayout(name: "Quiet", defaultFolder: project.path,
        root: .split(direction: .horizontal, ratio: 0.5, first: .leaf(SavedLayoutLeaf(kind: .shell, name: "Shell", folder: project.path)),
                     second: .leaf(SavedLayoutLeaf(kind: .codex, name: "Codex", folder: project.path))),
        automationPolicy: .off)
    let restored = try controller.restoreWorkspaceLayout(quiet)
    try restoreExpect(restored.automationPolicy == .off, "a layout saved from an Off workspace reopened as \(restored.automationPolicy)")
    let restoredPanes = try controller.listPanes().filter { $0.workspaceID == restored.workspaceID }
    try restoreExpect(restoredPanes.count == 2 && restoredPanes.allSatisfy { $0.automationPolicy == .off },
                      "the restored panes did not carry the saved policy: \(restoredPanes.map(\.automationPolicy))")

    // A restore whose state cannot be saved changes nothing, and ends no pane
    // of the workspace it would have replaced.
    let workspacesBefore = try controller.listWorkspaces().map(\.workspaceID)
    let panesBefore = try controller.listPanes().map(\.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: runtime.path)
    try restoreRejects("a restore reported success although its state could not be saved") { _ = try controller.restoreWorkspaceLayout(quiet) }
    try restoreRejects("a replacing restore reported success although its state could not be saved") {
        _ = try controller.restoreWorkspaceLayout(quiet, replacing: restored.workspaceID)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    try restoreExpect(try controller.listWorkspaces().map(\.workspaceID) == workspacesBefore, "a failed restore left a half-built workspace")
    try restoreExpect(try controller.listPanes().map(\.id) == panesBefore, "a failed restore changed the panes")
    try restoreExpect(terminated.ids.isEmpty, "a failed replacing restore ended panes of the workspace it would replace: \(terminated.ids)")
    try restoreExpect(try controller.listWorkspaces().first { $0.workspaceID == restored.workspaceID }?.isActive == true,
                      "a failed restore changed which workspace is active")

    // A replacement is a new workspace; it keeps the pin and the group.
    try controller.setWorkspacePinned(restored.workspaceID, pinned: true)
    let group = try controller.createWorkspaceGroup(name: "Kept", moving: restored.workspaceID)
    let replacement = try controller.restoreWorkspaceLayout(quiet, replacing: restored.workspaceID)
    let replaced = try controller.listWorkspaces().first { $0.workspaceID == replacement.workspaceID }
    try restoreExpect(replaced?.pinned == true, "a pinned workspace replaced by a saved layout lost its pin")
    try restoreExpect(replaced?.groupID == group.id, "a workspace replaced by a saved layout left its group")
}

/// Closing a workspace ends its panes only after every one of them may end:
/// a container that is not confirmed stopped refuses the close before any
/// sibling pane is terminated.
func checkCloseWorkspaceValidatesBeforeTerminating() throws {
    let root = URL(fileURLWithPath: "/private/tmp/parley-close-\(UUID().uuidString.lowercased().prefix(8))", isDirectory: true)
    let project = root.appendingPathComponent("project"), app = root.appendingPathComponent("app")
    let insideApp = app.appendingPathComponent("inside")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: insideApp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = try WorkbenchController(applicationDirectory: app, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    try controller.bootstrap(cwd: project.path)
    let credentials = try RelayCredentials(file: app.appendingPathComponent("relay-tokens.json"))
    controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("relay-url"), shimDirectory: app.appendingPathComponent("bin"),
        transportDirectory: app.appendingPathComponent("relay"), credentials: credentials, runtimeMarker: "DEV"))
    final class Terminated: @unchecked Sendable { var ids: [String] = [] }
    let terminated = Terminated()
    controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in }, interrupt: { _ in }, captureSelectedText: { _ in "" },
        terminate: { terminated.ids.append($0) }, terminateAll: {}))

    let doomed = try controller.createFolderlessWorkspace(launchFolder: project.path)
    let shell = try controller.createPane(kind: .shell, cwd: project.path)
    let configuration = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let definition = try PermissionProfileStore(file: app.appendingPathComponent("permission-profiles.json")).profiles().first { $0.id == "default" }!
    let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: insideApp.path, approvedRoots: [])
    let container = try controller.createPane(kind: .codex, cwd: insideApp.path, permissionProfile: profile, containerConfiguration: configuration)
    // Preparation clears the confirmed stop, then fails on the protected
    // folder before any Docker command: the container is no longer known to
    // be stopped, so it cannot be ended as an ordinary pane.
    try restoreRejects("a container was prepared inside Parley's own directory") {
        try controller.prepareContainerStart(container.id, configuration: configuration, permissionProfile: profile)
    }
    try restoreRejects("a workspace closed although one of its containers was not confirmed stopped") { try controller.closeWorkspace(doomed.workspaceID) }
    try restoreExpect(terminated.ids.isEmpty, "closing the workspace ended \(terminated.ids) before refusing")
    try restoreExpect(try controller.listPanes().contains { $0.id == shell.id } && (try controller.listWorkspaces()).contains { $0.workspaceID == doomed.workspaceID },
                      "a refused close removed the workspace or its shell")
}

@MainActor let workspaceRestoreChecks: [(String, () throws -> Void)] = [
    ("layout restore keeps the saved policy and rolls back", checkLayoutRestoreKeepsPolicyAndRollsBack),
    ("close workspace validates before terminating", checkCloseWorkspaceValidatesBeforeTerminating),
]
