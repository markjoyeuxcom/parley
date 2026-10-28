import Foundation
import ParleyCore

// A workspace that may use one vendor only holds several panes of it. Nothing
// refuses that, but every such pane is named after the vendor until renamed,
// and the broker matches the bare vendor against all of them. These checks
// pin the identity that replaces the vendor: the reviewed name and role, the
// labels that stay distinct, the refusal that teaches the working address,
// the pair template and the protocol and Help wording.

private struct SingleVendorFailure: Error, CustomStringConvertible {
    let description: String
}

private func svExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SingleVendorFailure(description: message) }
}

private func svPane(_ id: String, kind: PaneKind = .claude, name: String? = nil, role: String? = nil,
                    cwd: String = "/tmp/project", workspaceID: String = "@0", workspaceName: String? = "Work") -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: name, terminalTitle: "", cwd: cwd, currentCommand: kind.rawValue,
                  isActive: false, workspaceID: workspaceID, relayEnabled: true, workspaceName: workspaceName,
                  inputAvailable: true, role: role)
}

private func svTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("parley-single-vendor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    return root
}

private func svController(_ root: URL) throws -> WorkbenchController {
    try WorkbenchController(applicationDirectory: root.appendingPathComponent("runtime"),
                            environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
}

@MainActor
let singleVendorIdentityChecks: [(String, () throws -> Void)] = [
    ("PaneNaming proposes a numbered name only once the vendor label is taken", {
        try svExpect(PaneNaming.defaultName(for: .claude, among: []) == nil, "an empty workspace was given a numbered name")
        try svExpect(PaneNaming.defaultName(for: .claude, among: [svPane("%1", kind: .codex)]) == nil,
                     "another vendor's pane took the Claude label")
        try svExpect(PaneNaming.defaultName(for: .claude, among: [svPane("%1")]) == "Claude 2",
                     "the second Claude pane was not proposed Claude 2")
        try svExpect(PaneNaming.defaultName(for: .claude, among: [svPane("%1"), svPane("%2", name: "Claude 2")]) == "Claude 3",
                     "the third Claude pane was not proposed the next free ordinal")
        try svExpect(PaneNaming.defaultName(for: .claude, among: [svPane("%1"), svPane("%2", name: "claude 2")]) == "Claude 3",
                     "the ordinal check was case-sensitive")
        try svExpect(PaneNaming.defaultName(for: .claude, among: [svPane("%1", name: "Reviewer")]) == nil,
                     "a renamed Claude pane kept the label taken")
        try svExpect(PaneNaming.nameValidationError("") == nil && PaneNaming.nameValidationError("  ") == nil,
                     "an empty name, which means the vendor label, was refused")
        try svExpect(PaneNaming.nameValidationError("Work/Claude") != nil, "a slash, the workspace separator in a target, was accepted in a name")
        try svExpect(PaneNaming.nameValidationError("@reviewer") != nil, "a name beginning with @ was accepted; that is the role form")
        try svExpect(PaneNaming.nameValidationError(String(repeating: "n", count: 81)) != nil, "an 81-character name was accepted")
        try svExpect(PaneNaming.nameValidationError("Security reviewer") == nil, "an ordinary name was refused")
    }),

    ("PaneNaming labels colliding pane names by role, then folder, then id", {
        let unique = PaneNaming.distinctLabels(for: [svPane("%1"), svPane("%2", kind: .codex)])
        try svExpect(unique["%1"] == "Claude" && unique["%2"] == "Codex", "unique names were decorated: \(unique)")

        let byRole = PaneNaming.distinctLabels(for: [svPane("%1", role: "implementer"), svPane("%2", role: "reviewer")])
        try svExpect(byRole["%1"] == "Claude @implementer" && byRole["%2"] == "Claude @reviewer",
                     "two Claude panes with roles were not told apart by role: \(byRole)")

        let byFolder = PaneNaming.distinctLabels(for: [svPane("%1", cwd: "/work/api"), svPane("%2", cwd: "/work/web")])
        try svExpect(byFolder["%1"] == "Claude · api" && byFolder["%2"] == "Claude · web",
                     "two Claude panes without roles were not told apart by folder: \(byFolder)")

        // A role on one pane alone already separates the pair; nothing
        // further is appended to either.
        let oneRole = PaneNaming.distinctLabels(for: [svPane("%1", role: "reviewer", cwd: "/work/api"), svPane("%2", cwd: "/work/api")])
        try svExpect(oneRole["%1"] == "Claude @reviewer" && oneRole["%2"] == "Claude",
                     "a role on one pane only did not separate the pair, or decorated it further: \(oneRole)")

        let byID = PaneNaming.distinctLabels(for: [svPane("pane-aaaaaaaa-1"), svPane("pane-bbbbbbbb-2")])
        try svExpect(byID["pane-aaaaaaaa-1"] == "Claude · project · aaaaaaaa" && byID["pane-bbbbbbbb-2"] == "Claude · project · bbbbbbbb",
                     "identical names, roles and folders were not told apart by id: \(byID)")
        try svExpect(PaneNaming.shortID("pane-6c0d358e-97f2-4437-bb28-e828070cf36c") == "6c0d358e", "the short id did not drop the prefix")

        let mixedCase = PaneNaming.distinctLabels(for: [svPane("%1", name: "claude"), svPane("%2", name: "Claude", role: "reviewer")])
        try svExpect(mixedCase["%1"] == "claude" && mixedCase["%2"] == "Claude @reviewer",
                     "names differing only by case were treated as distinct: \(mixedCase)")
    }),

    ("createPane records the reviewed name and role under the Rename and Set Role rules", {
        let root = try svTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try svController(root)
        let project = root.appendingPathComponent("project").path
        _ = try controller.createWorkspace(folder: project)
        // Opening a folder seeds one shell; the identity panes come after it.
        let seeded = try controller.listPanes().count

        let plain = try controller.createPane(kind: .claude, cwd: project)
        try svExpect(plain.customName == nil && plain.role == nil && plain.displayName == "Claude", "a pane without identity gained one")

        let named = try controller.createPane(kind: .claude, cwd: project, name: "  Claude 2  ", role: "reviewer")
        try svExpect(named.customName == "Claude 2" && named.role == "reviewer", "the reviewed name and role were not recorded trimmed")
        let persisted = try controller.listPanes().first { $0.id == named.id }
        try svExpect(persisted?.customName == "Claude 2" && persisted?.role == "reviewer", "the identity was not persisted with the pane")

        let blank = try controller.createPane(kind: .claude, cwd: project, name: "   ", role: "")
        try svExpect(blank.customName == nil && blank.role == nil, "blank identity fields were stored instead of meaning none")

        do {
            _ = try controller.createPane(kind: .claude, cwd: project, role: "reviewer")
            throw SingleVendorFailure(description: "a second @reviewer was created in the same workspace")
        } catch let error as ParleyWorkbenchError {
            try svExpect("\(error)".contains("already assigned"), "the duplicate role refusal did not say so: \(error)")
        }
        do {
            _ = try controller.createPane(kind: .claude, cwd: project, role: "Claude")
            throw SingleVendorFailure(description: "a reserved vendor name was accepted as a role")
        } catch is ParleyWorkbenchError {}
        do {
            _ = try controller.createPane(kind: .claude, cwd: project, name: "Work/Claude")
            throw SingleVendorFailure(description: "a name with a slash was accepted")
        } catch is ParleyWorkbenchError {}
        do {
            _ = try controller.createPane(kind: .shell, cwd: project, role: "builder")
            throw SingleVendorFailure(description: "a shell pane was given a routing role")
        } catch is ParleyWorkbenchError {}
        do {
            try controller.renamePane(named.id, name: "@api")
            throw SingleVendorFailure(description: "Rename accepted a name beginning with @")
        } catch is ParleyWorkbenchError {}
        try controller.renamePane(named.id, name: " API ")
        let renamed = try controller.listPanes().first { $0.id == named.id }?.customName
        try svExpect(renamed == "API", "Rename did not apply the trimmed name: \(renamed ?? "nil")")
        let remaining = try controller.listPanes().count
        try svExpect(remaining == seeded + 3, "a refused creation left a pane behind: \(remaining - seeded) created, 3 expected")
    }),

    ("the broker refuses a shared vendor name and teaches the role, name and id that resolve", {
        let root = try svTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("relay-tokens.json"))
        let sourceToken = try credentials.token(for: "%1")
        let panes = [
            svPane("%1", role: "implementer"),
            svPane("%2", role: "reviewer"),
            svPane("%3", cwd: "/tmp/docs"),
        ]
        let broker = RelayBroker(
            credentials: credentials,
            panes: { panes },
            paste: { _, _ in },
            submit: { _, _ in throw SingleVendorFailure(description: "an ambiguous target was delivered to") },
            consultationTimeout: 1,
            livenessPollInterval: 0.01
        )
        let refusal = broker.handleAsk(token: sourceToken, target: "claude", text: "Which of you owns the API?", idempotencyKey: "shared-vendor-1")
        try svExpect(refusal.status == 400, "a shared vendor name was not refused: \(refusal.status) \(refusal.text)")
        for phrase in ["@reviewer", "%2", "%3", "Work/Claude", "share the vendor claude", "@role, pane name or pane id"] {
            try svExpect(refusal.text.contains(phrase), "the refusal omitted \(phrase): \(refusal.text)")
        }
        try svExpect(!refusal.text.contains("%1"), "the refusal offered the sender itself: \(refusal.text)")
        try svExpect(broker.consultations().isEmpty, "a refused Ask left a consultation behind")

        // Two renamed panes that share a name are listed with what differs.
        let message = RelayBroker.ambiguousTargetMessage("Pair", candidates: [
            svPane("%2", kind: .codex, name: "Pair", role: "reviewer"), svPane("%3", name: "Pair"),
        ])
        try svExpect(message.contains("@reviewer = Work/Pair = %2") && message.contains("Work/Pair = %3")
                     && !message.contains("share the vendor"), "a name shared across vendors was described as a vendor collision: \(message)")
    }),

    ("the pair template is a saved layout that restores two stopped panes with roles and a lead", {
        for vendor in PaneKind.allCases where vendor.isAgent {
            let layout = SavedWorkspaceLayout.pairTemplate(vendor: vendor, folder: "/tmp/project")
            try SavedWorkspaceLayoutStore.validate(layout)
            let leaves = layout.root.leaves
            try svExpect(layout.name == "\(vendor.label) Pair" && leaves.count == 2, "the \(vendor.label) template is not a pair")
            try svExpect(leaves.allSatisfy { $0.kind == vendor && $0.folder == "/tmp/project" && $0.permissionSelection == nil },
                         "the \(vendor.label) template carried another vendor, folder or a permission choice")
            try svExpect(leaves.map(\.role) == SavedWorkspaceLayout.pairTemplateRoles, "the template roles are not implementer then reviewer")
            try svExpect(leaves.map(\.isWorkspaceLead) == [true, false], "the implementer is not the sole lead")
        }

        let root = try svTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try svController(root)
        let project = root.appendingPathComponent("project").path
        _ = try controller.createWorkspace(folder: project)
        let restored = try controller.restoreWorkspaceLayout(SavedWorkspaceLayout.pairTemplate(vendor: .claude, folder: project))
        let panes = try controller.listPanes().filter { $0.workspaceID == restored.workspaceID }
        try svExpect(panes.count == 2 && panes.allSatisfy { $0.kind == .claude && !$0.isStarted },
                     "the pair did not restore as two stopped Claude panes: \(panes.map { ($0.kind, $0.isStarted) })")
        try svExpect(Set(panes.map(\.displayName)) == ["Implementer", "Reviewer"], "the pair's names were lost: \(panes.map(\.displayName))")
        try svExpect(Set(panes.compactMap(\.role)) == ["implementer", "reviewer"], "the pair's roles were lost: \(panes.map(\.role))")
        try svExpect(panes.filter(\.isWorkspaceLead).map(\.role) == ["implementer"], "the implementer is not the restored lead")
        try svExpect(PaneNaming.distinctLabels(for: panes).values.sorted() == ["Implementer", "Reviewer"],
                     "the pair's names needed decoration to be distinct")
        // Agents address the pair by role; the bare vendor is ambiguous between them.
        try svExpect(RelayBroker.ambiguousTargetMessage("claude", candidates: panes).contains("@implementer")
                     && RelayBroker.ambiguousTargetMessage("claude", candidates: panes).contains("@reviewer"),
                     "the refusal for the pair did not name both roles")
    }),

    ("the protocol and Help tell a shared-vendor workspace how to address its panes", {
        for phrase in [
            "Name one agent pane by pane name, `@role` or pane id.",
            "when several panes share a vendor",
            "the vendor alone is refused as ambiguous",
            "`parley panes` lists",
            "Your own name",
            "and role are in `parley whoami`",
            "pane you are by role or name",
        ] {
            try svExpect(AgentProtocol.text.contains(phrase), "the protocol omits: \(phrase)")
        }
        let workspaces = try svHelpTopic("workspaces")
        try svExpect(workspaces.searchableText.contains("Set a name and a role when you create an agent pane"), "Help omits identity at creation")
        try svExpect(workspaces.searchableText.contains("Claude 2"), "Help omits the numbered default name")
        try svExpect(workspaces.searchableText.contains("New Workspace from Template") && workspaces.searchableText.contains("@implementer"),
                     "Help omits the pair template")
        let handoffs = try svHelpTopic("handoffs")
        try svExpect(handoffs.searchableText.contains("refuses the vendor as ambiguous"), "Help omits the shared-vendor refusal")
        try svExpect(handoffs.searchableText.contains("Ask menus and the command palette add the role, folder or id"), "Help omits the distinct labels")
    }),
]

private func svHelpTopic(_ id: String) throws -> ParleyHelpTopic {
    guard let topic = ParleyHelpGuide.topics.first(where: { $0.id == id }) else {
        throw SingleVendorFailure(description: "Missing Help topic: \(id)")
    }
    return topic
}
