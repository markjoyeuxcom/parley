import Foundation
import ParleyCore

private func archiveExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ConfigurationArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func archiveSource(_ folder: String, _ file: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return try String(contentsOf: url, encoding: .utf8)
}

/// A complete, valid archive: two workspaces, a group, a pin, a split, roles,
/// a lead, a saved layout, a custom profile, an edited recipe and preferences.
private func sampleArchive(folder: String) -> ConfigurationArchive {
    var profile = PermissionProfileDefinition.builtIns.first { $0.id == "default" }!
    profile = profile.clone(id: "custom-review-abc12345", name: "Review tight")
    var recipes = HandoffRecipe.defaults
    recipes[0] = HandoffRecipe(id: recipes[0].id, name: recipes[0].name, kind: recipes[0].kind, instructions: "Review this plan for {{targets}} with care.")
    var surface = TerminalSurfacePreference.ghosttyDefault
    surface.scrollbackLimitMegabytes = 120
    let layout = SavedWorkspaceLayout(
        name: "Pair",
        defaultFolder: folder,
        root: .split(direction: .horizontal, ratio: 0.5,
                     first: .leaf(SavedLayoutLeaf(kind: .claude, name: "Lead", folder: folder, role: "lead-dev", isWorkspaceLead: true, permissionSelection: nil)),
                     second: .leaf(SavedLayoutLeaf(kind: .shell, name: "Shell", folder: folder, role: nil, isWorkspaceLead: false, permissionSelection: nil))),
        automationPolicy: .askAndDelegate
    )
    return ConfigurationArchive(
        appVersion: "0.1.69",
        runtime: .development,
        exportedAt: Date(timeIntervalSince1970: 1_760_400_000),
        groups: [ArchivedWorkspaceGroup(name: "Clients", isCollapsed: false)],
        workspaces: [
            ArchivedWorkspace(
                name: "Parley",
                attachedFolders: [folder],
                newPaneFolder: folder,
                automationPolicy: .askAndDelegate,
                pinned: true,
                groupName: "Clients",
                panes: [
                    ArchivedPane(kind: .claude, name: "Lead", role: nil, isWorkspaceLead: true, launchFolder: folder,
                                 profileID: "flexible", profileLifetime: .remembered, approvals: .vendorReviewer, wasContainer: false),
                    ArchivedPane(kind: .codex, name: nil, role: "reviewer", isWorkspaceLead: false, launchFolder: folder,
                                 profileID: "custom-review-abc12345", profileLifetime: .session, approvals: .person, wasContainer: true),
                    ArchivedPane(kind: .shell, name: "Build", role: nil, isWorkspaceLead: false, launchFolder: folder,
                                 profileID: nil, profileLifetime: nil, approvals: nil, wasContainer: false),
                ],
                layout: .split(direction: .horizontal, first: .leaf(0), second: .split(direction: .vertical, first: .leaf(1), second: .leaf(2))),
                splitFractions: ["0": 0.6]
            ),
            ArchivedWorkspace(
                name: "Scratch",
                attachedFolders: [],
                newPaneFolder: nil,
                automationPolicy: .off,
                pinned: false,
                groupName: nil,
                panes: [],
                layout: nil,
                splitFractions: [:]
            ),
        ],
        savedLayouts: [layout],
        customPermissionProfiles: [profile],
        defaultProfileIDs: ["claude": "flexible"],
        recipes: recipes,
        favouriteFolders: [folder],
        worktreeRepositories: [folder],
        preferences: ArchivedPreferences(
            terminalType: "xterm-256color",
            font: try? TerminalFontPreference(family: "Menlo", size: 13),
            appearanceImport: nil,
            surfaceOptions: surface,
            voiceLanguage: "en-US",
            readAloud: true,
            notificationWorkspaces: ["Parley"],
            collaborationDockVisible: false,
            swiftPMCompatibility: true,
            releaseChannel: "beta",
            lastAgentVendor: "codex",
            historyRetention: 250
        ),
        omittedStores: ["savedLayouts"]
    )
}

/// The document round-trips through its coder, and the coder refuses what is
/// not an archive by its own reason: too large, not JSON, an unknown schema
/// version by number.
func checkConfigurationArchiveRoundTrips() throws {
    let archive = sampleArchive(folder: "/Users/example/Developer/parley")
    try ConfigurationArchiveValidator.validate(archive)
    let data = try ConfigurationArchiveCoder.encode(archive)
    let text = String(decoding: data, as: UTF8.self)
    try archiveExpect(text.contains("\"schemaVersion\" : 1"), "the schema version is not written")
    for secret in ["relay-tokens", "handoffs.jsonl", "containerID", "launchGeneration", "approvedRoots", "ticket"] {
        try archiveExpect(!text.contains(secret), "the archive text names \(secret)")
    }
    let decoded = try ConfigurationArchiveCoder.decode(data)
    try archiveExpect(decoded == archive, "the archive changed through encode and decode")
    do {
        _ = try ConfigurationArchiveCoder.decode(Data(repeating: 0x20, count: ConfigurationArchive.maximumBytes + 1))
        throw NSError(domain: "ConfigurationArchive", code: 2, userInfo: [NSLocalizedDescriptionKey: "an oversized file was decoded"])
    } catch let error as ConfigurationArchiveError {
        try archiveExpect(error == .tooLarge(ConfigurationArchive.maximumBytes + 1), "oversize reported \(error)")
    }
    do {
        _ = try ConfigurationArchiveCoder.decode(Data("{\"hello\": 1}".utf8))
        throw NSError(domain: "ConfigurationArchive", code: 2, userInfo: [NSLocalizedDescriptionKey: "a non-archive was decoded"])
    } catch let error as ConfigurationArchiveError {
        try archiveExpect(error == .notAnArchive, "a non-archive reported \(error)")
    }
    do {
        _ = try ConfigurationArchiveCoder.decode(Data("{\"schemaVersion\": 9}".utf8))
        throw NSError(domain: "ConfigurationArchive", code: 2, userInfo: [NSLocalizedDescriptionKey: "a future schema was decoded"])
    } catch let error as ConfigurationArchiveError {
        try archiveExpect(error == .unsupportedSchema(9), "a future schema reported \(error)")
    }
    try archiveExpect(archive.referencedFolders == ["/Users/example/Developer/parley"], "referenced folders are \(archive.referencedFolders)")
    try archiveExpect(archive.paneCount == 3, "pane count is \(archive.paneCount)")
}

/// The validator refuses each shape a hand-edited or hostile file could take,
/// with a reason that names the offending part, and accepts the sample.
func checkConfigurationArchiveValidatorRefusesBadShapes() throws {
    let folder = "/Users/example/Developer/parley"
    func refused(_ label: String, _ mutate: (inout ConfigurationArchive) -> Void, _ fragment: String) throws {
        var archive = sampleArchive(folder: folder)
        mutate(&archive)
        do {
            try ConfigurationArchiveValidator.validate(archive)
            throw NSError(domain: "ConfigurationArchive", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(label) was accepted"])
        } catch let error as ConfigurationArchiveError {
            try archiveExpect(error.localizedDescription.contains(fragment), "\(label) reported \(error.localizedDescription), not \(fragment)")
        }
    }
    try refused("no workspaces", { $0.workspaces = [] }, "no workspace")
    try refused("duplicate names", { $0.workspaces[1].name = "parley" }, "two workspaces are named")
    try refused("a relative folder", { $0.workspaces[0].attachedFolders = ["relative"] }, "not an absolute path")
    try refused("an unknown group", { $0.workspaces[0].groupName = "Nowhere" }, "names a group the archive does not define")
    try refused("a role on a shell", { $0.workspaces[0].panes[2].role = "ops" }, "shell pane")
    try refused("two leads", { $0.workspaces[0].panes[1].isWorkspaceLead = true }, "two panes as lead")
    try refused("a duplicate role", { $0.workspaces[0].panes[0].role = "reviewer" }, "two panes the role")
    try refused("a layout missing a pane", { $0.workspaces[0].layout = .leaf(0) }, "does not name each of its panes exactly once")
    try refused("a bad split fraction", { $0.workspaces[0].splitFractions = ["0": 2] }, "invalid split position")
    try refused("a built-in profile", { $0.workspaces[0].panes[1].profileID = nil; $0.customPermissionProfiles = [PermissionProfileDefinition.builtIns[0]] }, "built-ins are never restored")
    try refused("a default for a shell", { $0.defaultProfileIDs = ["shell": "default"] }, "not an agent vendor")
    try refused("a recipe without targets", { $0.recipes[0] = HandoffRecipe(id: $0.recipes[0].id, name: $0.recipes[0].name, kind: $0.recipes[0].kind, instructions: "no placeholder") }, "recipe")
    try refused("an unknown retention", { $0.preferences.historyRetention = 300 }, "history retention 300")
    try refused("a bad terminal type", { $0.preferences.terminalType = "vt100" }, "terminal type")
    try refused("a bad voice language", { $0.preferences.voiceLanguage = "fr-FR" }, "voice language")
    try refused("an unknown omitted store", { $0.omittedStores = ["journals"] }, "unknown omitted store")
    try refused("a future schema", { $0.schemaVersion = 2 }, "schema version 2")
    try refused("an out-of-range surface option", { $0.preferences.surfaceOptions?.scrollbackLimitMegabytes = 5000 }, "Ghostty options")
    // Codex's review of 13 October 2026: references and nested exclusions.
    try refused("a pane naming an unknown profile", { $0.workspaces[0].panes[0].profileID = "custom-nowhere" }, "neither built in nor in the archive")
    try refused("a default naming an unknown profile", { $0.defaultProfileIDs = ["claude": "custom-nowhere"] }, "neither built in nor in the archive")
    try refused("a saved layout with approved roots", {
        let leaf = SavedLayoutLeaf(kind: .claude, name: "Lead", folder: folder, role: nil, isWorkspaceLead: false,
                                   permissionSelection: PermissionProfileSelection(profileID: "default", approvedRoots: ["/Users/example"], lifetime: .session))
        $0.savedLayouts = [SavedWorkspaceLayout(name: "Rooted", defaultFolder: folder, root: .leaf(leaf), automationPolicy: .off)]
    }, "approved roots")
    try refused("an imported appearance with source paths", {
        $0.preferences.appearanceImport = GhosttyAppearanceImport(sourceFiles: ["/Users/example/.config/ghostty/config"], themeDescription: "Nord",
                                                                  fontFamily: nil, fontSize: nil, light: GhosttyAppearanceColors(), dark: GhosttyAppearanceColors(), ignoredSettingCount: 0)
    }, "source file paths")
    try refused("an imported appearance naming a theme by path", {
        $0.preferences.appearanceImport = GhosttyAppearanceImport(sourceFiles: [], themeDescription: "/Users/example/themes/private",
                                                                  fontFamily: nil, fontSize: nil, light: GhosttyAppearanceColors(), dark: GhosttyAppearanceColors(), ignoredSettingCount: 0)
    }, "theme by path")
    var themed = sampleArchive(folder: folder)
    themed.preferences.surfaceOptions?.lightTheme = "Not A Theme"
    do {
        try ConfigurationArchiveValidator.validate(themed, themeExists: { $0 != "Not A Theme" })
        throw NSError(domain: "ConfigurationArchive", code: 3, userInfo: [NSLocalizedDescriptionKey: "an unknown theme was accepted"])
    } catch let error as ConfigurationArchiveError {
        try archiveExpect(error.localizedDescription.contains("not in this Parley's catalogue"), "an unknown theme reported \(error.localizedDescription)")
    }
    try ConfigurationArchiveValidator.validate(themed)
}

/// The export projections drop what a person granted or where a file lived,
/// and the writer refuses an archive the reader would refuse.
func checkConfigurationArchiveProjectionsAndWriter() throws {
    let folder = "/Users/example/Developer/parley"
    let rooted = SavedWorkspaceLayout(
        name: "Rooted", defaultFolder: folder,
        root: .split(direction: .vertical, ratio: 0.4,
                     first: .leaf(SavedLayoutLeaf(kind: .codex, name: "Codex", folder: folder, role: "reviewer", isWorkspaceLead: false,
                                                 permissionSelection: PermissionProfileSelection(profileID: "flexible", approvedRoots: ["/Users/example"], lifetime: .remembered, approvals: .vendorReviewer))),
                     second: .leaf(SavedLayoutLeaf(kind: .shell, name: "Shell", folder: folder, role: nil, isWorkspaceLead: false, permissionSelection: nil))),
        automationPolicy: .askAnswer
    )
    let stripped = rooted.strippingApprovedRoots()
    let leaves = stripped.root.leaves
    try archiveExpect(leaves.count == 2 && leaves[0].permissionSelection?.approvedRoots == [] && leaves[0].permissionSelection?.profileID == "flexible"
                          && leaves[0].permissionSelection?.approvals == .vendorReviewer && leaves[0].role == "reviewer" && leaves[1].permissionSelection == nil,
                      "stripping approved roots changed more than the roots")
    try archiveExpect(stripped.name == rooted.name && stripped.automationPolicy == rooted.automationPolicy, "stripping changed the layout's identity")
    let imported = GhosttyAppearanceImport(sourceFiles: ["/Users/example/.config/ghostty/config"], themeDescription: "/Users/example/themes/private",
                                           fontFamily: "Menlo", fontSize: 13, light: GhosttyAppearanceColors(), dark: GhosttyAppearanceColors(), ignoredSettingCount: 4)
    let projected = imported.forArchive
    try archiveExpect(projected.sourceFiles.isEmpty && projected.themeDescription == nil && projected.fontFamily == "Menlo" && projected.ignoredSettingCount == 4,
                      "the appearance projection kept provenance or lost values")
    try archiveExpect(GhosttyAppearanceImport(sourceFiles: [], themeDescription: "Nord", fontFamily: nil, fontSize: nil, light: GhosttyAppearanceColors(), dark: GhosttyAppearanceColors(), ignoredSettingCount: 0).forArchive.themeDescription == "Nord",
                      "a theme named by name was dropped")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-config-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var oversized = sampleArchive(folder: folder)
    oversized.workspaces[0].panes = Array(repeating: oversized.workspaces[0].panes[2], count: ConfigurationArchive.maximumPanesPerWorkspace + 1)
    oversized.workspaces[0].layout = nil
    do {
        try ConfigurationArchiveCoder.write(oversized, to: root.appendingPathComponent("too-many.json"))
        throw NSError(domain: "ConfigurationArchive", code: 5, userInfo: [NSLocalizedDescriptionKey: "an archive the reader refuses was written"])
    } catch let error as ConfigurationArchiveError {
        try archiveExpect(error.localizedDescription.contains("panes"), "the writer refused with \(error.localizedDescription)")
    }
    try archiveExpect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("too-many.json").path), "a refused export left a file")
    let destination = root.appendingPathComponent("good.json")
    try ConfigurationArchiveCoder.write(sampleArchive(folder: folder), to: destination)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    try archiveExpect((attributes[.posixPermissions] as? Int) == 0o600, "the export is not owner-only")
    try archiveExpect(try ConfigurationArchiveCoder.decode(Data(contentsOf: destination)) == sampleArchive(folder: folder), "the written export does not read back")
}

/// The snapshot puts back exactly the bytes and values it captured, removes
/// a file that did not exist, and leaves untouched keys alone.
func checkConfigurationStoreSnapshotRestoresExactly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-config-snapshot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "com.markjoyeux.parley.checks.configuration-snapshot"
    guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "ConfigurationArchive", code: 6, userInfo: [NSLocalizedDescriptionKey: "no suite"]) }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let present = root.appendingPathComponent("handoff-recipes.json")
    let absent = root.appendingPathComponent("workspace-layouts.json")
    let original = Data("{\"version\":2}".utf8)
    try original.write(to: present)
    defaults.set("beta", forKey: "parley.releaseChannel")
    defaults.set(["A"], forKey: "parley.notificationWorkspaces")
    let snapshot = ConfigurationStoreSnapshot.capture(files: [present, absent], preferenceKeys: ["parley.releaseChannel", "parley.notificationWorkspaces", "parley.swiftPMCompatibilityEnabled"], defaults: defaults)
    try Data("changed".utf8).write(to: present)
    try Data("new".utf8).write(to: absent)
    defaults.set("stable", forKey: "parley.releaseChannel")
    defaults.removeObject(forKey: "parley.notificationWorkspaces")
    defaults.set(true, forKey: "parley.swiftPMCompatibilityEnabled")
    defaults.set("kept", forKey: "parley.untouched")
    try snapshot.restore(defaults: defaults)
    try archiveExpect(try Data(contentsOf: present) == original, "the changed file was not put back")
    try archiveExpect(!FileManager.default.fileExists(atPath: absent.path), "a file that did not exist was left behind")
    try archiveExpect(defaults.string(forKey: "parley.releaseChannel") == "beta", "the changed value was not put back")
    try archiveExpect(defaults.stringArray(forKey: "parley.notificationWorkspaces") == ["A"], "the removed value was not put back")
    try archiveExpect(defaults.object(forKey: "parley.swiftPMCompatibilityEnabled") == nil, "a value that did not exist was left behind")
    try archiveExpect(defaults.string(forKey: "parley.untouched") == "kept", "an uncaptured key was touched")
}

/// The quiet-runtime table names every live thing once and nothing when all
/// is still.
func checkConfigurationQuietRuntimeTable() throws {
    let quiet = ConfigurationQuietRuntime.blockers(startedPanes: 0, activeHandoffs: 0, waitingConsultations: 0, liveCommandRuns: 0,
                                                   liveTeamSessions: 0, containerWork: false, voiceActive: false, recipeRunning: false,
                                                   comparisonRunning: false, terminating: false, uninstalling: false)
    try archiveExpect(quiet.isEmpty, "a still runtime reports \(quiet)")
    let busy = ConfigurationQuietRuntime.blockers(startedPanes: 2, activeHandoffs: 1, waitingConsultations: 1, liveCommandRuns: 1,
                                                  liveTeamSessions: 1, containerWork: true, voiceActive: true, recipeRunning: true,
                                                  comparisonRunning: true, terminating: true, uninstalling: true)
    try archiveExpect(busy.count == 11, "a fully busy runtime reports \(busy.count) blockers: \(busy)")
    let launching = ConfigurationQuietRuntime.blockers(startedPanes: 0, activeHandoffs: 0, waitingConsultations: 0, liveCommandRuns: 0,
                                                       liveTeamSessions: 0, containerWork: false, voiceActive: false, recipeRunning: false,
                                                       comparisonRunning: false, terminating: false, uninstalling: false,
                                                       launchReviewOpen: true, launchApplying: true)
    try archiveExpect(launching == ["a launch review is open (Start it or cancel it)", "a pane launch is being applied"], "a pending launch reads \(launching)")
    try archiveExpect(busy[0] == "2 panes are running (stop agents from their menus; close shells)", "the pane line reads \(busy[0])")
    let one = ConfigurationQuietRuntime.blockers(startedPanes: 1, activeHandoffs: 0, waitingConsultations: 0, liveCommandRuns: 0,
                                                 liveTeamSessions: 0, containerWork: false, voiceActive: false, recipeRunning: false,
                                                 comparisonRunning: false, terminating: false, uninstalling: false)
    try archiveExpect(one == ["1 pane is running (stop an agent from its menu; close a shell)"], "one pane reads \(one)")
    try archiveExpect(ConfigurationArchiveError.notQuiet(one).localizedDescription.contains("nothing was changed"),
                      "the refusal does not say nothing changed")
}

/// The preview counts the archive, lists the folders this Mac lacks, names the
/// omitted stores and the retention change, and carries the blockers.
func checkConfigurationRestorePreviewFacts() throws {
    let incoming = sampleArchive(folder: "/nonexistent/parley")
    var current = sampleArchive(folder: "/tmp")
    current.workspaces[0].name = "Old"
    let preview = ConfigurationRestorePreview(incoming: incoming, current: current, currentRetention: 500,
                                              blockers: ["1 pane is running (stop an agent from its menu; close a shell)"],
                                              folderExists: { $0 == "/tmp" })
    try archiveExpect(preview.currentWorkspaceNames == ["Old", "Scratch"] && preview.incomingWorkspaceNames == ["Parley", "Scratch"],
                      "the names are \(preview.currentWorkspaceNames) → \(preview.incomingWorkspaceNames)")
    try archiveExpect(preview.paneCount == 3 && preview.groupCount == 1 && preview.savedLayoutCount == 1 && preview.customProfileCount == 1,
                      "the counts are wrong")
    try archiveExpect(preview.customizedRecipeCount == 1, "edited recipes counted \(preview.customizedRecipeCount)")
    try archiveExpect(preview.missingFolders == ["/nonexistent/parley"], "missing folders are \(preview.missingFolders)")
    try archiveExpect(preview.omittedStores == [.savedLayouts], "omitted stores are \(preview.omittedStores)")
    try archiveExpect(preview.retentionChange?.from == 500 && preview.retentionChange?.to == 250, "the retention change is wrong")
    try archiveExpect(!preview.canApply, "a preview with a blocker can apply")
    let same = ConfigurationRestorePreview(incoming: incoming, current: current, currentRetention: 250, blockers: [], folderExists: { _ in true })
    try archiveExpect(same.retentionChange == nil && same.missingFolders.isEmpty && same.canApply, "a clean preview reports a change")
    try archiveExpect(same.settingChanges.isEmpty && same.profileChanges.isEmpty, "identical preferences report changes: \(same.settingChanges) \(same.profileChanges)")
    try archiveExpect(same.containerTemplateCount == 1, "container templates counted \(same.containerTemplateCount)")
    try archiveExpect(same.automationSummary == "1 Off, 1 Ask + Delegation", "automation summary reads \(same.automationSummary)")
    var quiet = current
    quiet.preferences = ArchivedPreferences()
    quiet.customPermissionProfiles = []
    quiet.defaultProfileIDs = [:]
    let changes = ConfigurationRestorePreview(incoming: incoming, current: quiet, currentRetention: 500, blockers: [], folderExists: { _ in true })
    try archiveExpect(changes.settingChanges.first?.hasPrefix("Swift package builds: SwiftPM compatibility turns ON") == true, "SwiftPM is not the first listed change: \(changes.settingChanges)")
    for expected in ["Terminal type: Ghostty → Compatible", "Manual release channel: Stable → Beta", "Terminal font changes", "Ghostty surface options change",
                     "Voice language: en-GB → en-US", "Read-aloud turns on", "Collaboration Dock hidden", "Workspace notifications for: Parley"] {
        try archiveExpect(changes.settingChanges.contains { $0.hasPrefix(expected) }, "missing change line \(expected) in \(changes.settingChanges)")
    }
    try archiveExpect(changes.profileChanges.contains("Custom profile added: Review tight") && changes.profileChanges.contains { $0.hasPrefix("Default profile for Claude") },
                      "profile changes are \(changes.profileChanges)")
    // nil means default: an archive that never chose read-aloud restores it off.
    let defaults = ConfigurationRestorePreview(incoming: quiet, current: incoming, currentRetention: 250, blockers: [], folderExists: { _ in true })
    try archiveExpect(defaults.settingChanges.contains("Read-aloud turns off") && defaults.settingChanges.contains("Collaboration Dock shown"), "nil preferences do not read as defaults: \(defaults.settingChanges)")
}

/// The controller replaces every workspace, group and pane with the plan's
/// stopped templates in one saved change, refuses while a pane runs, and the
/// result survives reopening the state file.
func checkWorkbenchReplacesWorkspacesFromAPlan() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-config-restore-\(UUID().uuidString)")
    let project = root.appendingPathComponent("project")
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    let runtime = root.appendingPathComponent("runtime")
    let controller = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try controller.bootstrap(cwd: project.path)
    let archive = sampleArchive(folder: project.path)
    var plan = WorkbenchRestorePlan(archive: archive)
    plan.workspaces[1].attachedFolders = [other.path]
    let running = try controller.listPanes().filter { $0.isStarted }
    try archiveExpect(!running.isEmpty, "bootstrap started no shell to refuse on")
    do {
        _ = try controller.replaceWorkspaces(with: plan)
        throw NSError(domain: "ConfigurationArchive", code: 4, userInfo: [NSLocalizedDescriptionKey: "a restore replaced a running pane"])
    } catch let error as WorkbenchRestoreError {
        try archiveExpect(error == .panesRunning(running.count), "the refusal was \(error)")
    }
    // A shell has no stopped state: it is running or closed. Agents stop.
    for pane in running {
        if pane.kind.isAgent {
            try controller.stopPaneProcess(pane.id, expectedGeneration: pane.launchGeneration)
        } else {
            try controller.closePane(pane.id)
        }
    }
    try archiveExpect(try controller.listPanes().allSatisfy { !$0.isStarted }, "a pane is still started after stopping and closing")
    let oldPaneIDs = Set(try controller.listPanes().map(\.id))
    let paneIDs = try controller.replaceWorkspaces(with: plan)
    try archiveExpect(paneIDs.map(\.count) == [3, 0], "pane ids per workspace are \(paneIDs.map(\.count))")
    try archiveExpect(Set(paneIDs.flatMap { $0 }).isDisjoint(with: oldPaneIDs), "an old pane id was reused")

    func verify(_ controller: WorkbenchController, _ label: String, afterRelaunch: Bool = false) throws {
        let workspaces = try controller.listWorkspaces()
        let panes = try controller.listPanes()
        let groups = try controller.listWorkspaceGroups()
        try archiveExpect(workspaces.map(\.name) == ["Parley", "Scratch"], "\(label): workspaces are \(workspaces.map(\.name))")
        try archiveExpect(workspaces[0].pinned && !workspaces[1].pinned, "\(label): pins are wrong")
        try archiveExpect(workspaces[0].attachedFolders == [project.path] && workspaces[0].newPaneFolder == project.path, "\(label): folders are wrong")
        try archiveExpect(workspaces[1].attachedFolders == [other.path] && workspaces[1].automationPolicy == .off, "\(label): the second workspace is wrong")
        try archiveExpect(groups.map(\.name) == ["Clients"] && workspaces[0].groupID == groups.first?.id && workspaces[1].groupID == nil, "\(label): groups are wrong")
        // A relaunch restarts shells and leaves agents as stopped placeholders,
        // as every launch does; the restore itself started nothing.
        try archiveExpect(panes.count == 3 && panes.allSatisfy { $0.workspaceID == workspaces[0].workspaceID }, "\(label): panes are not three templates in the first workspace")
        try archiveExpect(panes.filter(\.kind.isAgent).allSatisfy { !$0.isStarted }, "\(label): an agent template is started")
        if afterRelaunch {
            try archiveExpect(panes.filter { !$0.kind.isAgent }.allSatisfy(\.isStarted), "\(label): the shell did not restart on relaunch")
        } else {
            try archiveExpect(panes.allSatisfy { !$0.isStarted && $0.launchGeneration == 0 }, "\(label): the restore started a pane")
        }
        try archiveExpect(panes.map(\.kind) == [.claude, .codex, .shell], "\(label): pane kinds are \(panes.map(\.kind))")
        try archiveExpect(panes[0].customName == "Lead" && panes[0].isWorkspaceLead && panes[0].permissionSelection?.profileID == "flexible"
                              && panes[0].permissionSelection?.approvals == .vendorReviewer && panes[0].permissionSelection?.approvedRoots == [],
                          "\(label): the lead pane lost its template")
        try archiveExpect(panes[1].role == "reviewer" && panes[1].containerConfiguration == nil, "\(label): the reviewer pane lost its role or kept a container")
        try archiveExpect(panes[2].customName == "Build" && panes[2].launchFolder == project.path, "\(label): the shell template is wrong")
        try archiveExpect(workspaces.contains(where: \.isActive), "\(label): no workspace is active")
    }
    try verify(controller, "in memory")
    try controller.shutdown()
    let reopened = try WorkbenchController(applicationDirectory: runtime, environment: environment)
    try reopened.bootstrap(cwd: project.path)
    try verify(reopened, "after reopening", afterRelaunch: true)
    try reopened.shutdown()
}

/// Layout indices map onto fresh ids and back, and an index out of range or a
/// pane outside the list refuses rather than guesses.
func checkArchivedLayoutNodeMapsIndices() throws {
    let native = NativeLayoutNode.split(direction: .horizontal, first: .leaf("pane-a"), second: .split(direction: .vertical, first: .leaf("pane-b"), second: .leaf("pane-c")))
    let archived = ArchivedLayoutNode.archiving(native, paneIDs: ["pane-a", "pane-b", "pane-c"])
    try archiveExpect(archived?.leaves == [0, 1, 2], "indices are \(archived?.leaves ?? [])")
    try archiveExpect(ArchivedLayoutNode.archiving(native, paneIDs: ["pane-a"]) == nil, "a tree naming an unknown pane was archived")
    let restored = archived?.restoring(paneIDs: ["pane-x", "pane-y", "pane-z"])
    try archiveExpect(restored?.leaves == ["pane-x", "pane-y", "pane-z"], "restored leaves are \(restored?.leaves ?? [])")
    try archiveExpect(archived?.restoring(paneIDs: ["pane-x"]) == nil, "an index out of range was restored")
}

/// The model reads the file bounded, validates and checks the runtime before
/// any preview, re-reads the blockers at Replace, and Settings offers both
/// actions with the sheet.
func checkAppModelConfigurationTransferIsGuarded() throws {
    let model = try archiveSource("ParleyNative", "AppModel.swift")
    for required in [
        "BoundedRegularFile.read(source, maximumBytes: ConfigurationArchive.maximumBytes)",
        "try ConfigurationArchiveValidator.validate(archive, themeExists: { themeNames.contains($0) })",
        "throw ConfigurationArchiveError.runtimeMismatch(archive: archive.runtime, current: currentRuntime)",
        "let blockers = configurationRestoreBlockers(fresh: true)\n        guard blockers.isEmpty else {",
        "let snapshot = ConfigurationStoreSnapshot.capture(",
        "try applyConfigurationStores(archive)\n            _ = try controller.replaceWorkspaces(with: WorkbenchRestorePlan(archive: archive))",
        "try snapshot.restore(defaults: preferences)",
        "workspaceContinuity = WorkspaceContinuityState(favouriteFolders: archive.favouriteFolders)\n        var layoutWarning",
        "savedLayouts.map { $0.strippingApprovedRoots() }",
        "terminalAppearanceImport?.forArchive",
        "themeExists: { themeNames.contains($0) }",
        "launchReviewOpen: panePermissionRequest != nil",
        "voice.language = archived.voiceLanguage ?? \"en-GB\"",
        "configurationLoadIssues.removeAll { $0.store != .workspaceRegistry || layoutWarning == nil }",
        "omittedStores: configurationLoadIssues.map(\\.store.rawValue)",
        "setHistoryRetention(maximumRecords: retention)",
    ] {
        try archiveExpect(model.contains(required), "AppModel lost: \(required)")
    }
    let settings = try archiveSource("ParleyNative", "ParleySettingsView.swift")
    for required in ["Section(\"Backup\")", "Button(\"Export Configuration…\")", "Button(\"Restore Configuration…\")", "ConfigurationRestoreView(model: model, proposal: proposal)"] {
        try archiveExpect(settings.contains(required), "Settings lost: \(required)")
    }
    let sheet = try archiveSource("ParleyNative", "ConfigurationRestoreView.swift")
    try archiveExpect(sheet.contains(".disabled(!preview.canApply)"), "Replace is not disabled by the blockers")
    try archiveExpect(sheet.contains("Button(\"Cancel\") { model.cancelConfigurationRestore() }\n                    .keyboardShortcut(.cancelAction)"), "Cancel is not the escape")
    try archiveExpect(!sheet.contains("Button(\"Replace\") { model.applyConfigurationRestore() }\n                    .keyboardShortcut(.defaultAction)"), "Replace is the Return default")
}

@MainActor let configurationArchiveChecks: [(String, () throws -> Void)] = [
    ("configuration archive round trips", checkConfigurationArchiveRoundTrips),
    ("configuration archive validator refuses bad shapes", checkConfigurationArchiveValidatorRefusesBadShapes),
    ("configuration quiet runtime table", checkConfigurationQuietRuntimeTable),
    ("configuration restore preview facts", checkConfigurationRestorePreviewFacts),
    ("workbench replaces workspaces from a plan", checkWorkbenchReplacesWorkspacesFromAPlan),
    ("archived layout node maps indices", checkArchivedLayoutNodeMapsIndices),
    ("configuration archive projections and writer", checkConfigurationArchiveProjectionsAndWriter),
    ("configuration store snapshot restores exactly", checkConfigurationStoreSnapshotRestoresExactly),
    ("app model configuration transfer is guarded", checkAppModelConfigurationTransferIsGuarded),
]
