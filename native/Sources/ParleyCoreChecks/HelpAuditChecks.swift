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
            "both off by default", "survive relaunch", "memory-only", "without a preview",
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
        // WorktreeBrowserView.swift, TeamSessionsView.swift and the Workspace
        // menu in ParleyNativeApp.swift.
        let workspaces = try helpAuditTopic("workspaces")
        try helpAuditRequire(ParleyHelpGuide.matching("worktree").contains(workspaces), "Worktrees cannot be found")
        let text = workspaces.searchableText
        try helpAuditContains(text, [
            "not Parley workspaces or agents", "Open Worktree…", "git worktree list --porcelain", "without a shell",
            "one worktree per feature", "new branch from a base ref you preview", "existing one", "New Worktree",
            "<repository>/\(ManagedWorktreeService.worktreesDirectoryName)/", "never by an agent",
            "exact commit the tree was created from", "records no base and never removes it",
            "person action in the browser", "another registered worktree", "any pane's folder",
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
