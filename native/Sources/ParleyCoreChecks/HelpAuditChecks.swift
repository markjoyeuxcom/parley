import Foundation
import ParleyCore

// These checks pin specific user-facing promises, not completeness of the guide.
// The menu/control labels and lifetimes were compared with the native source.
private func helpAuditRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "HelpAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func helpAuditTopic(_ id: String) throws -> ParleyHelpTopic {
    guard let topic = ParleyHelpGuide.topics.first(where: { $0.id == id }) else {
        throw NSError(domain: "HelpAudit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing Help topic: \(id)"])
    }
    return topic
}

private func helpAuditContains(_ text: String, _ phrases: [String]) throws {
    for phrase in phrases {
        try helpAuditRequire(text.localizedCaseInsensitiveContains(phrase), "Help omits: \(phrase)")
    }
}

@MainActor
let helpAuditChecks: [(String, () throws -> Void)] = [
    ("Help audit names the Shell and Agent pane menu and the review's Vendor row", {
        let topic = try helpAuditTopic("workspaces")
        try helpAuditContains(topic.searchableText, ["Shell and Agent", "Vendor row", "New Agent Pane", "Option-Command-N", "preselected",
            "no attached folders and no panes", "may hold no panes", "leaves the workspace in place", "last workspace cannot be closed"])
    }),
    ("Help audit names the launch review's Runs picker and carried lists", {
        let topic = try helpAuditTopic("cli-permissions")
        try helpAuditContains(topic.searchableText, ["Runs", "On this machine", "In a container", "What is carried", "What is not carried", "who keeps it", "attribution is not isolation"])
        let containers = try helpAuditTopic("container-panes")
        try helpAuditRequire(!containers.searchableText.contains("select Run in a container"), "Help still describes the retired container toggle")
        try helpAuditContains(containers.searchableText, ["In a container (experimental) under Runs"])
    }),
    ("Help audit explains container ownership and retained vendor state", {
        let topic = try helpAuditTopic("container-panes")
        try helpAuditContains(topic.searchableText, ["local Unix-socket", "recorded container ID", "never adopts", "Docker output logging is disabled", "Delete Saved Vendor State", "request-run", "legacy Landlock", "deprecated", "Sign in with Device Code", "callback port", "shared Git", "outside the container", "does not review those changes again", "Team approval", "Linux shim utilities", "Cleanup continues", "Bypass vendor permissions", "off by default", "Profile restrictions are not applied", "CONTAINER · BYPASS", "host command runs still require native approval", "/usr/local/bin/agy", "/usr/local/bin/copilot", "--allow-all", "any agent pane"])
    }),
    ("Help audit distinguishes automatic updates from manual release downloads", {
        let topic = try helpAuditTopic("release-lifecycle")
        try helpAuditContains(topic.searchableText, [
            "Check for stable updates automatically", "off by default", "Check Now",
            "Production", "Development", "consent", "quit confirmation", "no background installation",
            "Manual release channel", "Stable selects published non-prereleases", "Beta selects",
            "Check GitHub", "Download and Verify", "does not install",
        ])
        try helpAuditRequire(!topic.searchableText.contains("there is no background update check"),
                             "Help incorrectly denies the opt-in automatic update channel")
    }),
    ("Help audit explains appearance overrides and apply or reset", {
        let text = try helpAuditTopic("settings").searchableText
        try helpAuditContains(text, [
            "font family", "font size", "Override", "Import", "Refresh", "Remove", "Apply",
            "Restore Parley Defaults", "immediately", "appearance values", "commands", "keybindings",
            "shell integration", "explicit font", "running sessions", "unapplied",
        ])
    }),
    ("Help audit separates command-run approvals and launch-time clean close", {
        let text = try helpAuditTopic("command-runs").searchableText
        try helpAuditContains(text, [
            "Per-run approval is the default", "editable", "outside the agent boundary",
            "Approve agent command runs automatically", "Close the Shell pane when a run finishes cleanly",
            "both off by default", "reset to off on quit", "memory-only", "without a preview",
            "queued automatic approvals", "manual approvals", "session grants", "already running",
            "fixed when the run starts", "exit 0", "signal", "cancelled", "truncated", "saved",
            "interactive shell", "restarted", "still on the run", "captured result", "parley wait",
        ])
        try helpAuditRequire(!text.contains("applies to runs that finish after"), "Close choice is fixed at launch, not completion")
        try helpAuditRequire(!text.localizedCaseInsensitiveContains("press any key"), "Clean close must not instruct the person to release Ghostty's post-exit surface")
        try helpAuditContains(AgentProtocol.commandHelp, ["per-run approval", "automatic approval", "session trust", "native-only"])
    }),
    ("Help audit matches native navigation and creation shortcuts", {
        let topic = try helpAuditTopic("shortcuts")
        try helpAuditContains(topic.searchableText, [
            "Command-1…9 — focus pane", "Command-Shift-F — zoom the selected pane, or unzoom",
            "Command-Shift-D — show or hide the Collaboration Dock", "Command-Option-T — focus the active terminal",
            "Command-Shift-N — New Workspace",
        ])
        try helpAuditRequire(!topic.searchableText.contains("Command-Shift-N — open a workspace"), "New Workspace is not Open Folder")
        let workspaces = try helpAuditTopic("workspaces").searchableText
        try helpAuditContains(workspaces, ["Zoom", "Unzoom", "Collaboration Dock"])
        try helpAuditRequire(!workspaces.contains("Focus Canvas") && !workspaces.contains("Pane Grid"), "Help must not keep the retired layout names")
    }),
    ("Help audit distinguishes auxiliary close from minimise or app hide", {
        let text = try helpAuditTopic("settings").searchableText
        try helpAuditContains(text, [
            "Status Center", "Settings", "Help", "About", "close",
            "released", "filters", "toggles", "unapplied", "minimise", "hide Parley",
            "drafts", "refresh pauses", "saved settings", "history", "main window", "panes running",
        ])
    }),
    ("Help audit distinguishes vendor-managed host execution and native authority", {
        let topic = try helpAuditTopic("command-runs")
        try helpAuditContains(topic.searchableText, ["no outer sandbox", "attribution is not an isolation guarantee",
            "private-path rules", "legacy sandbox_mode", "app memory", "peer process", "reset to off on quit"])
    }),
    ("Help audit gives test-run recovery and uninstall steps", {
        let topic = try helpAuditTopic("troubleshooting")
        try helpAuditContains(topic.searchableText, [
            "sandbox_apply: Operation not permitted", "Swift package builds", "off by default",
            "restart", "EPERM", "/usr/bin/login", "request-run", "Review runs and trust",
            "captured result", "same live", "Prepare to Uninstall", "Prepare and Quit",
            "Trash", "does not delete", "keeps the app open",
        ])
        let commands = topic.sections.flatMap(\.commands).map(\.command)
        try helpAuditRequire(commands.contains("\"$PARLEY_SWIFT_COMMAND\" build"), "Missing PATH-safe SwiftPM retry")
        try helpAuditRequire(commands.contains { $0.hasPrefix("parley request-run --cwd ") && $0.hasSuffix(" test") }, "Missing a concrete test-run example")
        try helpAuditRequire(commands.contains("parley wait <run-id>"), "Missing exact run recovery example")
    }),
    ("Help audit exposes team and command-run topics and context inspection", {
        let team = try helpAuditTopic("team-sessions")
        let runs = try helpAuditTopic("command-runs")
        try helpAuditRequire(ParleyHelpGuide.matching("team sessions").contains(team), "Team Sessions cannot be found")
        try helpAuditRequire(ParleyHelpGuide.matching("command runs").contains(runs), "Command runs cannot be found")
        try helpAuditContains(team.searchableText, ["Tools", "provisioning", "Stop", "parley team status"])
        // A person-proposed run (ReviewedCommandRunCoordinator.propose) is documented beside agent requests.
        try helpAuditContains(runs.searchableText, ["Integrate…", "Proposed by you", "always waits for your approval", "creates no session trust", "no agent pane can recover"])
        let context = try helpAuditTopic("context-packs")
        let commands = context.sections.flatMap(\.commands).map(\.command)
        try helpAuditRequire(commands.contains("parley context list"), "Missing context list example")
        try helpAuditRequire(commands.contains("parley context show <draft-id>"), "Missing context show example")
        try helpAuditContains(context.searchableText, [
            "Waiting for Your Approval", "Saved Agent Drafts", "newest eight", "Discard All Editable Drafts",
            "never touches a waiting approval", "Agent-proposed context; not approved or sent", "stay unverified",
            "reading it there is a complete interaction",
        ])
        let sections = ParleyHelpGuide.topics.flatMap(\.sections)
        try helpAuditRequire(Set(sections.map(\.id)).count == sections.count, "Moved Help sections have duplicate identities")
    }),
    ("Help audit states the worktree boundary and matches the cleanup policy", {
        // Compared with ManagedWorktrees.swift (creation, cleanup policy),
        // WorktreeManagerView.swift, TeamSessionsView.swift and the Workspace
        // and Tools menus in ParleyNativeApp.swift.
        let workspaces = try helpAuditTopic("workspaces")
        try helpAuditRequire(ParleyHelpGuide.matching("worktree").contains(workspaces), "Worktrees cannot be found")
        let text = workspaces.searchableText
        try helpAuditContains(text, [
            "not Parley workspaces or agents", "Open Worktree…", "git worktree list --porcelain", "without a shell",
            "one worktree per feature", "new branch from a base ref you preview", "existing one", "New Worktree",
            "<repository>/\(ManagedWorktreeService.worktreesDirectoryName)/", "never by an agent",
            "exact commit the tree was created from", "records no base for it", "same preview and refusals", "registry entry at the recorded path", "still carry its creation marker",
            "person action in the Worktrees window", "another registered worktree", "any pane's folder",
            "modified or untracked files", "ahead of the upstream's local remote-tracking state",
            "not contained in the primary worktree's HEAD", "locked or prunable", "could not be read",
            "more than \(WorktreeCleanupPolicy.maximumReviewedIgnoredPaths) refuses",
            "no pane can start or be created inside the tree", "without --force",
            "removed, not removed, or uncertain", "only clears Parley's record",
            "branch, objects, refs and stashes remain",
            "grants no extra permission root", "vendor's own permission decision",
            "no claim that commits need no vendor approval",
            "same exact canonical worktree", "permission evidence only", "never proves",
            "never requires one worktree per agent", "silently creates one",
            "inside the requesting pane's working folder",
            "never commits, merges, rebases, pushes, stashes, forces or deletes a branch",
            // The board and Integrate… (WorktreeBrowserView.swift, WorktreeBoardRow, AppModel.proposeWorktreeIntegration).
            "worktree board", "ahead of and behind the primary checkout", "never as zero", "nothing about the board is stored",
            "Integrate…", "always waits for your approval", "Parley itself runs no merge", "reads Integrated", "not offered on a tree that already reads Integrated",
            // The manager window (WorktreeManagerView.swift, WorktreeRepositories.swift, the Tools menu in ParleyNativeApp.swift).
            "Tools › Worktrees…", "needs no pane or workspace", "Add Repository…", "Forget", "never removable here", "Not recorded", "Stale",
            "only while the window is on screen",
            "no tracking step", "Prune…", "Git has no per-entry form", "Delete branch…", "one git branch -d", "never uses -D",
            "Remove integrated…", "stops at the first outcome that is not a confirmed removal", "Nothing runs across repositories at once",
        ])
        try helpAuditRequire(text.contains(ManagedWorktreeService.CreatePreview.executionNotice),
                             "Help must carry the exact creation execution notice")
        try helpAuditContains(ManagedWorktreeService.CreatePreview.executionNotice, ["post-checkout hooks", "filters"])
        try helpAuditRequire(!text.localizedCaseInsensitiveContains("automatically remov"), "Help must not promise automatic worktree removal")
        try helpAuditRequire(!text.localizedCaseInsensitiveContains("fully isolated"), "Help must not overclaim worktree isolation")
        let team = try helpAuditTopic("team-sessions")
        try helpAuditRequire(team.searchableText.contains(TeamSessionDisclosure.worktree), "Team Sessions must carry the worktree disclosure")
        let commands = team.sections.flatMap(\.commands).map(\.command)
        try helpAuditRequire(commands.contains { $0.hasPrefix("parley team request ") && $0.contains("--worktree ") && $0.contains("--base ") },
                             "Missing a worktree proposal example")
        try helpAuditContains(AgentProtocol.commandHelp, ["--worktree <branch> [--base <ref>]", "only proposes"])
        try helpAuditContains(AgentProtocol.text, ["<repository>/\(ManagedWorktreeService.worktreesDirectoryName)/", "--worktree"])
    }),
]
