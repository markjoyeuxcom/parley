import AppKit
import Foundation
import ParleyCore
import ParleyUI

// Polish agreed by Claude, Codex and Agy on 3 October 2026: places where the
// app refused or hid something without saying why, or said it differently in
// two places.

private func frictionExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "EverydayFriction", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func nativeSource(_ folder: String, _ file: String) throws -> SwiftSourceReader {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
}

private func pane(
    _ id: String, _ kind: PaneKind, workspace: String = "w1", started: Bool = true, dead: Bool = false,
    protocolVersion: String? = AgentProtocol.version, relay: Bool = true, input: Bool = true,
    role: String? = nil, lead: Bool = false
) -> WorkbenchPane {
    WorkbenchPane(
        id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/tmp", currentCommand: "x",
        isActive: false, workspaceID: workspace, relayEnabled: relay, protocolVersion: protocolVersion,
        inputAvailable: input, isDead: dead, isStarted: started, isWorkspaceLead: lead, role: role
    )
}

/// Help opened on Voice, its first topic, ahead of Start here, and Start
/// here's first workflow named no menu or key.
func checkHelpOpensOnStartHere() throws {
    try frictionExpect(ParleyHelpGuide.topics.first?.id == "start",
                       "Help's first topic is \(ParleyHelpGuide.topics.first?.id ?? "none"), not Start here")
    let start = try ParleyHelpGuide.topics.first.map(\.searchableText) ?? ""
    for step in ["Workspace > Open Folder…", "Option-Command-N", "Command-Return", "Status Center opens on it"] {
        try frictionExpect(start.contains(step), "Start here's first workflow no longer names \(step)")
    }
    let setup = try nativeSource("ParleyNative", "SetupView.swift").text
    try frictionExpect(setup.contains("requestHelp(topicID: \"start\")"), "the readiness check no longer leads to Start here")
}

/// The Ask and Review menus disabled themselves when nothing could be asked,
/// so their one line of guidance could not be read, and it said another
/// vendor was needed although a second pane of the same vendor is a route.
func checkAskMenuSaysWhyNothingCanBeAsked() throws {
    let claude = pane("claude", .claude)
    try frictionExpect(AskAvailability.unavailableReason(source: nil, panes: []) == "Select an agent pane to ask from.",
                       "no selection did not ask for an agent pane")
    try frictionExpect(AskAvailability.unavailableReason(source: pane("sh", .shell), panes: [])?.contains("agent pane") == true,
                       "a shell selection did not ask for an agent pane")
    try frictionExpect(AskAvailability.unavailableReason(source: pane("c", .claude, started: false), panes: [])?.contains("not running") == true,
                       "a stopped source was not named")
    try frictionExpect(AskAvailability.unavailableReason(source: pane("c", .claude, protocolVersion: "1"), panes: [])?.contains("Restart for Protocol") == true,
                       "a stale source did not say Restart for Protocol")
    try frictionExpect(AskAvailability.unavailableReason(source: claude, panes: [claude])?.contains("same one") == true,
                       "a lone agent was not told any vendor, the same one included, can be asked")
    try frictionExpect(AskAvailability.unavailableReason(source: claude, panes: [claude, pane("codex", .codex, started: false)])?.contains("No other agent pane is ready") == true,
                       "a stopped target was not explained")
    let second = pane("claude-2", .claude)
    try frictionExpect(AskAvailability.unavailableReason(source: claude, panes: [claude, second]) == nil,
                       "a second Claude pane was not accepted as a target")
    try frictionExpect(AskAvailability.targets(source: claude, panes: [claude, second, pane("sh", .shell)]).map(\.id) == ["claude-2"],
                       "Ask targets are not exactly the other ready agent panes")

    let content = try nativeSource("ParleyNative", "ContentView.swift").text
    try frictionExpect(!content.contains("another vendor"), "a toolbar menu still says another vendor")
    try frictionExpect(!content.contains("isEnabled: !model.askTargets.isEmpty"), "the Ask or Review menu still disables itself, hiding why")
    let app = try nativeSource("ParleyNative", "AppModel.swift").text
    try frictionExpect(app.contains("AskAvailability.targets(source: activePane, panes: panes)"),
                       "AppModel's Ask targets no longer come from the shared eligibility")
}

/// A context pack's Ask One Pane and Compare Panes buttons were disabled
/// without saying which condition was missing.
func checkContextPackSaysWhyItCannotBeSent() throws {
    let ready = ContextPackSendReadiness.Inputs(
        captureRunning: false, sourceReady: true, hasParts: true, hasNote: true, withinLimits: true,
        targetCount: 2, isAgentDraft: false, comparisonRunning: false, coreAvailable: true
    )
    try frictionExpect(ContextPackSendReadiness.askBlockedReason(ready) == nil, "a ready pack cannot be asked")
    try frictionExpect(ContextPackSendReadiness.compareBlockedReason(ready) == nil, "a ready pack cannot be compared")
    var noNote = ready; noNote.hasNote = false
    try frictionExpect(ContextPackSendReadiness.askBlockedReason(noNote) == "Write the request to send with the pack.", "a missing request was not named")
    var capturing = noNote; capturing.captureRunning = true
    try frictionExpect(ContextPackSendReadiness.askBlockedReason(capturing) == "Wait for the capture to finish.", "a running capture is not named first")
    var oneTarget = ready; oneTarget.targetCount = 1
    try frictionExpect(ContextPackSendReadiness.askBlockedReason(oneTarget) == nil, "one target cannot be asked")
    try frictionExpect(ContextPackSendReadiness.compareBlockedReason(oneTarget)?.contains("two ready agent panes") == true, "Compare's two-pane need was not named")
    var agent = ready; agent.isAgentDraft = true
    try frictionExpect(ContextPackSendReadiness.compareBlockedReason(agent)?.contains("only your own pack") == true, "an agent draft's Compare was not explained")
    var none = ready; none.targetCount = 0
    try frictionExpect(ContextPackSendReadiness.askBlockedReason(none) == "No other agent pane is ready to receive it.", "no target was not named")

    let view = try nativeSource("ParleyNative", "ContextPackView.swift").text
    try frictionExpect(view.contains(".disabled(model.contextPackAskBlockedReason != nil)"), "Ask One Pane is not disabled by its stated reason")
    try frictionExpect(view.contains(".help(model.contextPackCompareBlockedReason"), "Compare Panes does not show its reason")
}

/// The palette's rows select on hover, and a hover arrived whenever the list
/// scrolled or changed under a resting pointer, undoing arrow-key steps and
/// replacing the top match Return opens.
func checkPaletteHoverKeepsKeyboardSelection() throws {
    var guardian = KeyboardSelectionHoverGuard()
    try frictionExpect(guardian.acceptsHover(pointer: NSPoint(x: 1, y: 1)), "a hover before any keyboard step was refused")
    guardian.keyboardSelected(pointer: NSPoint(x: 5, y: 5))
    try frictionExpect(!guardian.acceptsHover(pointer: NSPoint(x: 5, y: 5)), "a resting pointer took the keyboard's selection")
    try frictionExpect(!guardian.acceptsHover(pointer: NSPoint(x: 5, y: 5)), "a second scroll under a resting pointer took the selection")
    try frictionExpect(guardian.acceptsHover(pointer: NSPoint(x: 6, y: 5)), "a moved pointer was refused")
    try frictionExpect(guardian.acceptsHover(pointer: NSPoint(x: 5, y: 5)), "a pointer that moved back was refused after it had moved")

    let palette = try nativeSource("ParleyNative", "CommandPaletteView.swift").text
    try frictionExpect(palette.contains("hoverGuard.acceptsHover(pointer: NSEvent.mouseLocation)"), "the palette's hover does not ask the guard")
    try frictionExpect(palette.components(separatedBy: "hoverGuard.keyboardSelected(pointer: NSEvent.mouseLocation)").count == 3,
                       "arrow keys and a changed list do not both record the pointer")
    try frictionExpect(!palette.contains("if hovering { selectedID = command.id }"), "the unguarded hover is back")
}

/// The same pane state read RESTART FOR PROTOCOL on the pane, Protocol stale
/// in the sidebar and Protocol Stale in recovery guidance; the dock showed
/// the version alone.
func checkStaleProtocolHasOneName() throws {
    for (folder, file) in [("ParleyNative", "ContentView.swift"), ("ParleyCore", "RecoveryGuidance.swift"), ("ParleyCore", "RuntimeReadiness.swift")] {
        let text = try nativeSource(folder, file).text
        try frictionExpect(!text.localizedCaseInsensitiveContains("protocol stale"), "\(file) still says Protocol Stale")
    }
    let current = pane("a", .claude)
    try frictionExpect(WorkbenchChromeProjection.protocolLabel(panes: [current]) == (AgentProtocol.version, false),
                       "the dock marks a current pane as stale")
    let stale = WorkbenchChromeProjection.protocolLabel(panes: [current, pane("b", .codex, protocolVersion: "1"), pane("c", .agy, protocolVersion: "1")])
    try frictionExpect(stale == ("\(AgentProtocol.version) · 2 need restart", true), "the dock's stale count reads \(stale.value)")
    let one = WorkbenchChromeProjection.protocolLabel(panes: [pane("b", .codex, protocolVersion: "1")])
    try frictionExpect(one.value.hasSuffix("1 needs restart"), "one stale pane reads \(one.value)")
}

/// A delegation completed with `done --file` read COMPLETED at the top while
/// the file waiting for the person sat further down.
func checkReturnedFileStateIsBesideTheHandoffState() throws {
    try frictionExpect(AgentContextReviewState.draft.returnedFileBadge == ("FILE AWAITING REVIEW", true), "a staged return is not marked as waiting")
    try frictionExpect(AgentContextReviewState.completed.returnedFileBadge == ("REVIEWED PACK SENT", false), "a sent review is not marked sent")
    try frictionExpect(AgentContextReviewState.rejected.returnedFileBadge.label == "FILE NOT SENT", "a declined return is not marked")
    // A review fails when its Ask got no answer, which does not prove the
    // pack was never delivered (Codex's review of MR !144).
    for state in [AgentContextReviewState.failed, .interrupted] {
        try frictionExpect(state.returnedFileBadge == ("FILE SEND UNCONFIRMED", true), "\(state) claims more than it knows")
    }
    try frictionExpect(![AgentContextReviewState.draft, .awaitingReview, .approved, .rejected, .discarded, .completed, .failed, .interrupted].map(\.returnedFileBadge.label).contains { $0.contains("FAILED") || $0 == "FILE SENT" },
                       "a badge asserts a delivery the review state does not record")
    let status = try nativeSource("ParleyNative", "StatusCenterView.swift").text
    try frictionExpect(status.contains("state.returnedFileBadge"), "Status Center's header no longer shows the returned file's state")
    try frictionExpect(status.contains("Button(\"Review Returned File…\")"), "the Review action is gone")
}

/// A move whose destination already has the pane's role or a lead was
/// refused only after it was chosen.
func checkMoveMenuNamesRoleAndLeadConflicts() throws {
    let reviewer = pane("p", .codex, role: "reviewer", lead: true)
    let panes = [reviewer, pane("q", .claude, workspace: "w2", role: "reviewer"), pane("r", .agy, workspace: "w3", lead: true), pane("s", .agy, workspace: "w4")]
    try frictionExpect(PaneMobilityPolicy.destinationConflictNote(pane: reviewer, targetWorkspaceID: "w2", panes: panes) == "@reviewer is taken there",
                       "a role collision is not named")
    try frictionExpect(PaneMobilityPolicy.destinationConflictNote(pane: reviewer, targetWorkspaceID: "w3", panes: panes) == "already has a lead",
                       "a lead collision is not named")
    try frictionExpect(PaneMobilityPolicy.destinationConflictNote(pane: reviewer, targetWorkspaceID: "w4", panes: panes) == nil,
                       "a free destination is marked")
    let content = try nativeSource("ParleyNative", "ContentView.swift").text
    try frictionExpect(content.contains("PaneMobilityPolicy.destinationConflictNote("), "the Move menu no longer names conflicts")
}

/// Smaller fixes, pinned by their source: the Pane menu bar could only split
/// beside, Settings and the launch review had fixed sizes, and an empty
/// workspace's buttons had no Return default.
func checkSmallFrictionFixesStay() throws {
    let app = try nativeSource("ParleyNative", "ParleyNativeApp.swift").text
    for item in ["Menu(\"Split Below\")", "Menu(\"In Another Folder\")", "createAgent(direction: .vertical)"] {
        try frictionExpect(app.contains(item), "the Pane menu lost \(item)")
    }
    let settings = try nativeSource("ParleyNative", "ParleySettingsView.swift").text
    try frictionExpect(!settings.contains(".frame(width: 680, height: 590)"), "Settings has a fixed size again")
    let review = try nativeSource("ParleyNative", "PermissionProfilePickerView.swift").text
    try frictionExpect(!review.contains(".frame(width: 610, height:"), "the launch review has a fixed size again")
    let content = try nativeSource("ParleyNative", "ContentView.swift").text
    guard let empty = content.range(of: "Button(\"New Agent…\") { model.createAgent(direction: .horizontal) }") else {
        throw NSError(domain: "EverydayFriction", code: 2, userInfo: [NSLocalizedDescriptionKey: "the empty workspace's New Agent button is gone"])
    }
    try frictionExpect(content[empty.upperBound...].prefix(80).contains(".keyboardShortcut(.defaultAction)"),
                       "the empty workspace's New Agent button is not the Return default")
}

/// Settings is reachable from the palette for every section, General puts the
/// durable choices before the session-only switches and carries the history
/// retention choice, and a refused Ghostty option is reported beside its
/// section (13 October 2026 review).
func checkSettingsNavigationPolish() throws {
    let appModel = try nativeSource("ParleyNative", "AppModel.swift").text
    try frictionExpect(appModel.contains("for section in ApplicationSettingsSection.allCases {"),
                       "the palette no longer lists every Settings section")
    try frictionExpect(appModel.contains("case let .openSettings(section):"), "the palette cannot open a Settings section")
    let settings = try nativeSource("ParleyNative", "ParleySettingsView.swift").text
    let updates = try frictionRange(settings, "Section(\"Software updates\")")
    let swiftPM = try frictionRange(settings, "Section(\"Swift package builds\")")
    let history = try frictionRange(settings, "Section(\"Local history\")")
    let runs = try frictionRange(settings, "Text(\"Agent command runs\")")
    try frictionExpect(updates.lowerBound < swiftPM.lowerBound && swiftPM.lowerBound < history.lowerBound && history.lowerBound < runs.lowerBound,
                       "General no longer lists Software updates, Swift package builds, Local history, then Agent command runs")
    try frictionExpect(settings.contains("Text(\"This session only\")"), "the session-only command-run switches lost their header")
    try frictionExpect(settings.contains("model.setHistoryRetention(maximumRecords: $0)"), "General lost the history retention choice")
    try frictionExpect(settings.contains("model.requestStatusCenterSegment(.history)"), "Manage History… no longer opens Status Center on History")
    let surface = try nativeSource("ParleyNative", "TerminalSurfaceSettingsView.swift").text
    for section in TerminalSurfaceSection.allCases {
        try frictionExpect(surface.contains("surfaceSection(.\(section.rawValue)) {"),
                           "the \(section.title) section is not built by surfaceSection, so it has no scope header or refusal row")
    }
    try frictionExpect(surface.contains("sectionError(section)\n            content()"), "a section's refusal row no longer comes first")
    try frictionExpect(surface.contains("Text(section.scope)"), "section headers lost their scope label")
    try frictionExpect(surface.contains("errorSection = TerminalSurfaceSection.changed(from: stored, to: requested).first"),
                       "a refused Ghostty option is not attributed to its section")
    try frictionExpect(surface.contains(".disabled(imported)"), "the theme pickers stay live while an imported appearance supplies the colours")
    try frictionExpect(surface.contains("Button(\"Remove Imported Appearance\")"), "the theme section lost its way to remove the import")
    // Appearance: one grouped form, no Apply button, no fixed width, the look
    // sections beside the font (13 October 2026 review).
    let appearance = try nativeSource("ParleyNative", "AppearanceSettingsView.swift").text
    try frictionExpect(!appearance.contains(".frame(width: 560)"), "the Appearance tab has a fixed width again")
    try frictionExpect(!appearance.contains("Button(\"Apply\")") && !appearance.contains("Button(\"Cancel\""),
                       "the Appearance tab has an Apply or Cancel button; Settings saves every change at once")
    try frictionExpect(appearance.contains("TerminalSurfaceSettingsSections(model: model, tab: .appearance)"),
                       "the look-related Ghostty options are not in the Appearance tab")
    try frictionExpect(appearance.contains(".formStyle(.grouped)"), "the Appearance tab is not a grouped form like the other tabs")
    try frictionExpect(settings.contains("TerminalSurfaceSettingsSections(model: model, tab: .terminal, restoreTitle: \"Restore Ghostty Defaults\")"),
                       "the Terminal tab does not show the behaviour sections with their restore button")
    try frictionExpect(!settings.contains("TerminalFontSettingsView"), "Settings still embeds the retired TerminalFontSettingsView")
}

private func frictionRange(_ text: String, _ needle: String) throws -> Range<String.Index> {
    guard let range = text.range(of: needle) else {
        throw NSError(domain: "EverydayFriction", code: 3, userInfo: [NSLocalizedDescriptionKey: "Settings lost \(needle)"])
    }
    return range
}

@MainActor let everydayFrictionChecks: [(String, () throws -> Void)] = [
    ("settings navigation polish stays", checkSettingsNavigationPolish),
    ("help opens on start here", checkHelpOpensOnStartHere),
    ("ask menu says why nothing can be asked", checkAskMenuSaysWhyNothingCanBeAsked),
    ("context pack says why it cannot be sent", checkContextPackSaysWhyItCannotBeSent),
    ("palette hover keeps keyboard selection", checkPaletteHoverKeepsKeyboardSelection),
    ("stale protocol has one name", checkStaleProtocolHasOneName),
    ("returned file state is beside the handoff state", checkReturnedFileStateIsBesideTheHandoffState),
    ("move menu names role and lead conflicts", checkMoveMenuNamesRoleAndLeadConflicts),
    ("small friction fixes stay", checkSmallFrictionFixesStay),
]
