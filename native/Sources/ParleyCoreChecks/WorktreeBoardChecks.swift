import Foundation
import ParleyCore

private func boardExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "WorktreeBoard", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func boardRecord(parleyCreated: Bool = true, team: String? = nil, requester: String? = nil, base: String? = "abcdef0123456789") -> ManagedWorktreeRecord {
    ManagedWorktreeRecord(id: "record", commonDirectory: "/repo/.git", path: "/repo/.worktrees/feat-x", branch: "feat/x",
        baseRef: base == nil ? nil : "main", baseCommit: base, createdAt: Date(timeIntervalSince1970: 0),
        parleyCreated: parleyCreated, creationToken: parleyCreated ? "token" : nil, teamSessionID: team, requestedByPaneID: requester, warning: nil)
}

private func boardFacts(registered: Bool? = true, changed: Int? = 0, ahead: Int? = 0, behind: Int? = 0, contained: Bool? = true, branch: String? = "feat/x") -> ManagedWorktreeFacts {
    ManagedWorktreeFacts(recordID: "record", currentBranch: branch, head: "1111111111111111", changedPathCount: changed,
        upstreamAheadCount: nil, hasUpstream: false, registered: registered, primaryHead: "2222222222222222",
        aheadOfPrimary: ahead, behindPrimary: behind, containedInPrimary: contained)
}

private func boardPane(_ id: String, started: Bool, dead: Bool = false) -> WorkbenchPane {
    var pane = WorkbenchPane(id: id, kind: .codex, customName: id, terminalTitle: "", cwd: "/repo/.worktrees/feat-x",
        currentCommand: "codex", isActive: false, workspaceID: "workspace", relayEnabled: true, inputAvailable: true, launchGeneration: 1)
    pane.isStarted = started
    pane.isDead = dead
    return pane
}

/// The board is derived from recorded facts on every read. Nothing here is
/// a stored workflow state, so each rule is checked against the inputs that
/// should and should not produce it.
func worktreeBoardDerivationChecks() throws {
    let record = boardRecord()
    let derive = { (facts: ManagedWorktreeFacts?, panes: [WorkbenchPane], team: TeamSessionState?) in
        WorktreeBoardRow.derive(record: record, facts: facts, panesInside: panes, requester: nil,
            teamObjective: team == nil ? nil : "Ship the parser", teamState: team)
    }
    // Reading order: no read yet, then Git's own answers, then activity, then integration.
    try boardExpect(derive(nil, [], nil).state == .unread, "a tree with no background read was not 'not read yet'")
    try boardExpect(derive(boardFacts(registered: false), [], nil).state == .missing, "an unregistered tree was not missing")
    try boardExpect(derive(boardFacts(registered: nil), [], nil).state == .unknown, "an unreadable tree was not unknown")
    try boardExpect(derive(boardFacts(), [boardPane("a", started: true)], nil).state == .inUse, "a running pane inside did not make the tree in use")
    try boardExpect(derive(boardFacts(), [boardPane("a", started: false)], nil).state == .integrated, "a stopped placeholder counted as use")
    try boardExpect(derive(boardFacts(), [boardPane("a", started: true, dead: true)], nil).state == .integrated, "a dead process counted as use")
    try boardExpect(derive(boardFacts(), [], nil).state == .integrated, "a clean tree contained in the primary was not integrated")
    try boardExpect(derive(boardFacts(changed: 2), [], nil).state == .idle, "a dirty tree contained in the primary claimed integrated")
    try boardExpect(derive(boardFacts(ahead: 3, contained: false), [], nil).state == .idle, "a tree with commits ahead claimed integrated")
    try boardExpect(derive(boardFacts(contained: nil), [], nil).state == .idle, "unknown containment claimed integrated")
    // A running pane or an active team wins over integration facts; an ended team does not.
    try boardExpect(derive(boardFacts(), [], .active).state == .inUse, "an active team did not make the tree in use")
    try boardExpect(derive(boardFacts(), [], .stopped).state == .integrated, "a stopped team kept the tree in use")
    try boardExpect(derive(boardFacts(), [boardPane("a", started: true), boardPane("b", started: false)], nil).runningPaneCount == 1
        && derive(boardFacts(), [boardPane("a", started: true), boardPane("b", started: false)], nil).stoppedPaneCount == 1,
        "pane counts were wrong")
    // Integrate needs a tree Git still lists with something to merge; an
    // integrated tree (contained, nothing ahead) has no merge to propose,
    // while unreadable counts leave the offer to Git.
    try boardExpect(derive(boardFacts(ahead: 2, contained: false), [], nil).canIntegrate, "a tree with commits ahead could not be integrated")
    try boardExpect(derive(boardFacts(ahead: nil, behind: nil, contained: nil), [], nil).canIntegrate, "unreadable divergence hid Integrate")
    try boardExpect(!derive(boardFacts(), [], nil).canIntegrate && !derive(boardFacts(changed: 3, ahead: 0, contained: true), [], nil).canIntegrate,
        "Integrate was offered on a tree already contained in the primary with nothing ahead")
    try boardExpect(!derive(boardFacts(registered: false), [], nil).canIntegrate && !derive(nil, [], nil).canIntegrate
        && !derive(boardFacts(registered: nil), [], nil).canIntegrate, "Integrate was offered without a listed tree")
    // Labels say exactly what was read.
    let row = derive(boardFacts(changed: 1, ahead: 2, behind: 5, contained: false), [], nil)
    try boardExpect(row.divergenceLabel == "ahead 2 · behind 5", "divergence label: \(row.divergenceLabel)")
    try boardExpect(row.changesLabel == "1 changed", "changes label: \(row.changesLabel)")
    try boardExpect(row.baseLabel == "base abcdef012345 (main)", "base label: \(row.baseLabel)")
    try boardExpect(row.factsLine.contains("HEAD 111111111111") && row.factsLine.hasSuffix("created by Parley"), "facts line: \(row.factsLine)")
    try boardExpect(derive(boardFacts(ahead: nil, behind: nil), [], nil).divergenceLabel == "divergence from primary unknown", "an unreadable count was shown as a number")
    try boardExpect(derive(boardFacts(changed: nil), [], nil).changesLabel == "status unknown", "an unreadable status was shown as clean")
    try boardExpect(derive(boardFacts(registered: false), [], nil).factsLine.contains("folder gone") && !derive(boardFacts(registered: false), [], nil).factsLine.contains("HEAD"),
        "a missing tree showed a HEAD")
    try boardExpect(derive(boardFacts(branch: "other"), [], nil).headLabel.hasSuffix(" on other"), "a tree switched to another branch was not flagged")
    try boardExpect(WorktreeBoardRow.derive(record: boardRecord(base: nil), facts: boardFacts(), panesInside: [], requester: nil, teamObjective: nil, teamState: nil).baseLabel == "base not recorded",
        "a missing base was invented")
}

/// Ownership comes from the record: a team binding wins, then the requesting
/// pane with its presence, then the person who created it from the browser,
/// then a tracked person-owned tree.
func worktreeBoardOwnerChecks() throws {
    let facts = boardFacts()
    let team = WorktreeBoardRow.derive(record: boardRecord(team: "session", requester: "lead"), facts: facts, panesInside: [],
        requester: boardPane("lead", started: true), teamObjective: "Ship the parser and get it reviewed by a different vendor", teamState: .active)
    guard case .team = team.owner else { throw NSError(domain: "WorktreeBoard", code: 1, userInfo: [NSLocalizedDescriptionKey: "a team-bound tree was not owned by the team"]) }
    try boardExpect(team.ownerLabel.hasPrefix("Team: ") && team.ownerLabel.hasSuffix("(active)") && team.ownerLabel.contains("…"), "team label: \(team.ownerLabel)")
    let runningRequester = WorktreeBoardRow.derive(record: boardRecord(requester: "lead"), facts: facts, panesInside: [],
        requester: boardPane("lead", started: true), teamObjective: nil, teamState: nil)
    try boardExpect(runningRequester.ownerLabel == "lead (running)", "running requester: \(runningRequester.ownerLabel)")
    let stoppedRequester = WorktreeBoardRow.derive(record: boardRecord(requester: "lead"), facts: facts, panesInside: [],
        requester: boardPane("lead", started: false), teamObjective: nil, teamState: nil)
    try boardExpect(stoppedRequester.ownerLabel == "lead (stopped)", "stopped requester: \(stoppedRequester.ownerLabel)")
    let closedRequester = WorktreeBoardRow.derive(record: boardRecord(requester: "pane-gone"), facts: facts, panesInside: [],
        requester: nil, teamObjective: nil, teamState: nil)
    try boardExpect(closedRequester.ownerLabel == "pane-gone (closed)", "closed requester: \(closedRequester.ownerLabel)")
    try boardExpect(WorktreeBoardRow.derive(record: boardRecord(), facts: facts, panesInside: [], requester: nil, teamObjective: nil, teamState: nil).ownerLabel == "You",
        "a browser-created tree was not owned by the person")
    try boardExpect(WorktreeBoardRow.derive(record: boardRecord(parleyCreated: false), facts: facts, panesInside: [], requester: nil, teamObjective: nil, teamState: nil).ownerLabel == "Person-owned",
        "a tracked tree was not person-owned")
    // A team id without a live session falls back to the requester rather than inventing a team.
    let orphanTeam = WorktreeBoardRow.derive(record: boardRecord(team: "session", requester: "lead"), facts: facts, panesInside: [],
        requester: nil, teamObjective: nil, teamState: nil)
    try boardExpect(orphanTeam.ownerLabel == "lead (closed)", "an unknown session invented a team owner: \(orphanTeam.ownerLabel)")
}

@MainActor
let worktreeBoardChecks: [(String, () throws -> Void)] = [
    ("worktree board state is derived from recorded facts, never stored", worktreeBoardDerivationChecks),
    ("worktree board ownership follows the record: team, requester, you, person-owned", worktreeBoardOwnerChecks),
]
