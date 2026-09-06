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
    ("Help audit describes opt-in idle reaping without claiming vendor inactivity", {
        let text = try helpAuditTopic("settings").searchableText
        try helpAuditContains(text, [
            "Reap idle agents after 30 minutes", "off by default", "recorded pane activity",
            "selected pane", "workspace lead", "Shell panes", "live Ask or Delegate",
            "stopped", "untracked vendor work", "does not automatically resume",
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
            "Command-1…9 — focus pane", "Command-Shift-F — enter Focus Canvas or return to Pane Grid",
            "Command-Shift-D — show or hide the Collaboration Dock", "Command-Option-T — focus the active terminal",
            "Command-Shift-T — open Task Manager", "Command-Shift-N — New Workspace",
        ])
        try helpAuditRequire(!topic.searchableText.contains("Command-Shift-N — open a workspace"), "New Workspace is not Open Folder")
        let workspaces = try helpAuditTopic("workspaces").searchableText
        try helpAuditContains(workspaces, ["Focus Canvas", "Pane Grid", "Collaboration Dock"])
    }),
    ("Help audit distinguishes auxiliary close from minimise or app hide", {
        let text = try helpAuditTopic("settings").searchableText
        try helpAuditContains(text, [
            "Status Center", "Task Manager", "Settings", "Help", "About", "close",
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
        try helpAuditContains(team.searchableText, ["Tools", "template", "provisioning", "Stop", "parley team status"])
        let context = try helpAuditTopic("context-packs")
        let commands = context.sections.flatMap(\.commands).map(\.command)
        try helpAuditRequire(commands.contains("parley context list"), "Missing context list example")
        try helpAuditRequire(commands.contains("parley context show <draft-id>"), "Missing context show example")
        let sections = ParleyHelpGuide.topics.flatMap(\.sections)
        try helpAuditRequire(Set(sections.map(\.id)).count == sections.count, "Moved Help sections have duplicate identities")
    }),
]
