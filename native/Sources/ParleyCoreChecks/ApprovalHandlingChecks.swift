import Foundation
import ParleyCore

private func approvalExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ApprovalHandling", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A selection recorded before the approvals choice existed decodes as the
/// person answering, and the choice survives the metadata round trip.
func approvalHandlingSelectionDecodingChecks() throws {
    let legacy = Data(#"{"profileID":"flexible","approvedRoots":["/tmp/a"],"lifetime":"remembered"}"#.utf8)
    let decoded = try JSONDecoder().decode(PermissionProfileSelection.self, from: legacy)
    try approvalExpect(decoded.approvals == .person, "a legacy selection did not decode as the person answering")
    try approvalExpect(decoded.profileID == "flexible" && decoded.approvedRoots == ["/tmp/a"] && decoded.lifetime == .remembered,
        "a legacy selection lost a field while gaining approvals")

    let chosen = PermissionProfileSelection(profileID: "flexible", approvedRoots: ["/tmp/a"], lifetime: .session, approvals: .vendorReviewer)
    let restored = try approvalRequire(PermissionProfileSelection(metadataValue: chosen.metadataValue), "the metadata round trip lost the selection")
    try approvalExpect(restored == chosen && restored.approvals == .vendorReviewer, "the reviewer choice did not survive the metadata round trip")
    let encoded = String(decoding: try JSONEncoder().encode(chosen), as: UTF8.self)
    try approvalExpect(encoded.contains(#""approvals":"vendorReviewer""#), "the reviewer choice was not encoded by name: \(encoded)")
}

/// The vendor's own automatic reviewer is reached only through documented,
/// non-bypass options, and only where the vendor has one. Every plan, with
/// either choice, is free of skip-all flags: that is invariant 3.
func approvalHandlingLaunchPlanChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let flexible = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }, "no flexible profile")
    let reviewOnly = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }, "no review-only profile")
    try approvalExpect(reviewOnly.rule(for: .projectWrite) == .deny, "this check needs a profile that denies writes")

    func plan(_ kind: PaneKind, _ definition: PermissionProfileDefinition, _ approvals: PermissionApprovalHandling) throws -> PermissionProfileLaunchPlan {
        let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: folder, approvals: approvals)
        return PermissionProfileAdapter.launchPlan(for: kind, profile: profile)
    }
    // Any adjacent pair: a Codex launch carries several `-c` values, so the
    // first `-c` is not the one that matters.
    func hasPair(_ arguments: [String], _ flag: String, _ value: String) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == flag && $1 == value }
    }

    // Claude: auto mode replaces the edit mode; plan mode stays plan.
    let claude = try plan(.claude, flexible, .vendorReviewer)
    try approvalExpect(hasPair(claude.arguments, "--permission-mode", "auto"), "Claude did not receive auto mode: \(claude.arguments)")
    try approvalExpect(claude.detail.contains("Auto mode"), "Claude's plan does not disclose auto mode")
    let claudePlan = try plan(.claude, reviewOnly, .vendorReviewer)
    try approvalExpect(hasPair(claudePlan.arguments, "--permission-mode", "plan") && !claudePlan.arguments.contains("auto"),
        "a write-denying profile enabled Claude auto mode: \(claudePlan.arguments)")
    try approvalExpect(claudePlan.detail.contains("not enabled"), "Claude's plan-mode detail does not say auto mode is off")
    try approvalExpect(hasPair(try plan(.claude, flexible, .person).arguments, "--permission-mode", "acceptEdits"),
        "the person answering changed Claude's edit mode")

    // Flexible carries no shell restriction for any vendor: Claude gets only
    // the allow rules for Parley's command, never an ask or deny for Bash.
    let flexibleProfile = try PermissionProfileResolver.resolve(definition: flexible, paneFolder: folder)
    try approvalExpect(PermissionProfileAdapter.shellCommandRule(flexibleProfile) == .allow, "Flexible restricts shell execution again")
    let flexibleClaude = try JSONSerialization.jsonObject(with: Data(VendorHookAdapter.claudeSettingsJSON(
        shimExecutable: "/tmp/parley", shellCommandRule: PermissionProfileAdapter.shellCommandRule(flexibleProfile)).utf8)) as! [String: Any]
    let flexiblePermissions = flexibleClaude["permissions"] as? [String: [String]]
    try approvalExpect(flexiblePermissions?["ask"] == nil && flexiblePermissions?["deny"] == nil,
        "Flexible gave Claude a Bash restriction: \(flexiblePermissions ?? [:])")
    try approvalExpect(flexiblePermissions?["allow"]?.contains("Bash(parley:*)") == true,
        "Flexible did not pre-allow Parley's command for Claude: \(flexiblePermissions ?? [:])")

    // Codex: auto review is added; sandbox and on-request stay.
    let codex = try plan(.codex, flexible, .vendorReviewer)
    try approvalExpect(hasPair(codex.arguments, "-c", "approvals_reviewer=auto_review"), "Codex did not receive auto review: \(codex.arguments)")
    try approvalExpect(hasPair(codex.arguments, "--sandbox", "workspace-write") && hasPair(codex.arguments, "--ask-for-approval", "on-request"),
        "Codex auto review changed the sandbox or approval policy: \(codex.arguments)")
    try approvalExpect(!(try plan(.codex, flexible, .person)).arguments.contains("approvals_reviewer=auto_review"),
        "the person answering still enabled Codex auto review")

    // Copilot: assisted approval is added.
    let copilot = try plan(.copilot, flexible, .vendorReviewer)
    try approvalExpect(copilot.arguments.contains("--assisted-approval"), "Copilot did not receive assisted approval: \(copilot.arguments)")
    try approvalExpect(!(try plan(.copilot, flexible, .person)).arguments.contains("--assisted-approval"),
        "the person answering still enabled Copilot assisted approval")

    // Agy: nothing changes, and the plan says why.
    let agyReviewer = try plan(.agy, flexible, .vendorReviewer)
    let agyPerson = try plan(.agy, flexible, .person)
    try approvalExpect(agyReviewer.arguments == agyPerson.arguments, "Agy's launch changed although it has no reviewer: \(agyReviewer.arguments)")
    try approvalExpect(agyReviewer.detail.contains("no automatic reviewer"), "Agy's plan does not say it has no reviewer")

    // The host Codex launch takes HostAgentPermissions, not the plan above, so
    // the choice has to be carried there too or a host Codex pane never sees it.
    func hostCodex(_ definition: PermissionProfileDefinition, _ approvals: PermissionApprovalHandling) throws -> [String] {
        let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: folder, approvals: approvals)
        return HostAgentPermissions(
            applicationDirectory: URL(fileURLWithPath: "/tmp/parley-app"), protocolDirectory: URL(fileURLWithPath: "/tmp/parley-protocol"),
            shimDirectory: URL(fileURLWithPath: "/tmp/parley-shim"), transportDirectory: URL(fileURLWithPath: "/tmp/parley-transport"),
            endpointDirectory: URL(fileURLWithPath: "/tmp/parley-endpoint"), profile: profile
        ).launchArguments
    }
    let hostReviewer = try hostCodex(flexible, .vendorReviewer)
    try approvalExpect(hasPair(hostReviewer, "-c", "approvals_reviewer=auto_review"), "the host Codex launch did not carry auto review: \(hostReviewer)")
    try approvalExpect(hasPair(hostReviewer, "--ask-for-approval", "on-request"), "the host Codex launch lost its approval policy: \(hostReviewer)")
    try approvalExpect(!(try hostCodex(flexible, .person)).contains("approvals_reviewer=auto_review"),
        "the host Codex launch enabled auto review for the person answering")

    // Invariant 3: no skip-all flag reaches any host launch, whichever choice.
    let forbidden = ["--yolo", "--full-auto", "--allow-all", "--allow-all-tools", "--allow-all-paths", "--allow-all-urls"]
    func assertNoSkipAll(_ arguments: [String], _ label: String) throws {
        try approvalExpect(!arguments.contains { argument in
            argument.hasPrefix("--dangerously") || forbidden.contains(argument)
                || argument.contains("danger-full-access") || argument.contains("bypassPermissions")
        }, "\(label) carried a skip-all flag: \(arguments)")
    }
    for kind in PaneKind.allCases where kind.isAgent {
        for definition in [flexible, reviewOnly] {
            for approvals in PermissionApprovalHandling.allCases {
                try assertNoSkipAll(try plan(kind, definition, approvals).arguments, "\(kind.label) with \(approvals.rawValue)")
                if kind == .codex {
                    try assertNoSkipAll(try hostCodex(definition, approvals), "host Codex with \(approvals.rawValue)")
                }
            }
        }
    }
}

/// An allowed network rule reaches Codex's sandbox table and nowhere else,
/// and the plan says so per vendor. Codex's built-in profiles have no
/// network, so without the key the review's "Allowed by profile" was false.
func networkRuleChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let withNetwork = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "flexible-network" }, "no Flexible + network profile")
    let flexible = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }, "no flexible profile")
    try approvalExpect(withNetwork.rule(for: .networkAccess) == .allow && flexible.rule(for: .networkAccess) == .requireApproval,
        "the two profiles do not differ in the network rule")

    func hostCodex(_ definition: PermissionProfileDefinition) throws -> [String] {
        let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: folder)
        return HostAgentPermissions(
            applicationDirectory: URL(fileURLWithPath: "/tmp/parley-app"), protocolDirectory: URL(fileURLWithPath: "/tmp/parley-protocol"),
            shimDirectory: URL(fileURLWithPath: "/tmp/parley-shim"), transportDirectory: URL(fileURLWithPath: "/tmp/parley-transport"),
            endpointDirectory: URL(fileURLWithPath: "/tmp/parley-endpoint"), profile: profile
        ).configurationArguments
    }
    let table = try approvalRequire(try hostCodex(withNetwork).first { $0.hasPrefix("permissions.parley_host=") }, "no permissions table")
    try approvalExpect(table.contains("network={enabled=true}"), "an allowing profile did not enable network in Codex's table: \(table)")
    let plainTable = try approvalRequire(try hostCodex(flexible).first { $0.hasPrefix("permissions.parley_host=") }, "no permissions table")
    try approvalExpect(!plainTable.contains("network="), "a profile that asks for network enabled it in Codex's table: \(plainTable)")

    for kind in [PaneKind.claude, .agy, .copilot] {
        let profile = try PermissionProfileResolver.resolve(definition: withNetwork, paneFolder: folder)
        let plan = PermissionProfileAdapter.launchPlan(for: kind, profile: profile)
        try approvalExpect(plan.detail.contains("only Codex's sandbox can carry"), "\(kind.label)'s plan does not say network is not carried: \(plan.detail)")
        try approvalExpect(!plan.arguments.contains { $0.contains("network") }, "\(kind.label) received a network argument it cannot honour: \(plan.arguments)")
    }
    let codexPlan = PermissionProfileAdapter.launchPlan(for: .codex, profile: try PermissionProfileResolver.resolve(definition: withNetwork, paneFolder: folder))
    try approvalExpect(codexPlan.detail.contains("enabled in Codex's sandbox"), "Codex's plan does not disclose the enabled network: \(codexPlan.detail)")
}

/// The plan's parts are what the review lists under What is carried and
/// What is not carried; its joined `detail` is the same text as before the
/// split, and each part says truthfully whether the launch carries it.
func launchPlanPartsChecks() throws {
    let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
    let flexible = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }, "no flexible profile")
    let asking = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "default" }, "no default profile")
    try approvalExpect(asking.rule(for: .projectToolExecution) != .allow || asking.rule(for: .localProcessExecution) != .allow,
        "this check needs a profile that restricts execution")
    let withNetwork = try approvalRequire(PermissionProfileDefinition.builtIns.first { $0.id == "flexible-network" }, "no flexible + network profile")

    for kind in [PaneKind.claude, .codex, .agy, .copilot] {
        for definition in [flexible, asking, withNetwork] {
            for approvals in [PermissionApprovalHandling.person, .vendorReviewer] {
                let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: folder, approvals: approvals)
                let plan = PermissionProfileAdapter.launchPlan(for: kind, profile: profile)
                let joined = plan.mode
                    + (plan.reviewer.map { " " + $0 } ?? "")
                    + " Vendor prompts remain authoritative for capabilities the CLI cannot express."
                    + (plan.execution.map { " " + $0.text } ?? "")
                    + (plan.network.map { " " + $0.text } ?? "")
                try approvalExpect(plan.detail == joined, "\(kind.label)/\(definition.id)/\(approvals): detail is not the join of its parts:\n\(plan.detail)\n\(joined)")
                try approvalExpect((plan.reviewer != nil) == (approvals == .vendorReviewer),
                    "\(kind.label)/\(definition.id): the reviewer part does not follow the approvals choice")
                try approvalExpect(!plan.mode.contains("Auto mode") && !plan.mode.contains("Auto review"),
                    "\(kind.label): the reviewer sentence leaked into the mode part: \(plan.mode)")
            }
        }
        // Execution rules reach Claude as a settings rule and nobody else.
        let restricted = PermissionProfileAdapter.launchPlan(for: kind, profile: try PermissionProfileResolver.resolve(definition: asking, paneFolder: folder))
        let execution = try approvalRequire(restricted.execution, "\(kind.label): a restricting profile produced no execution part")
        try approvalExpect(execution.carried == (kind == .claude), "\(kind.label): execution carried flag is wrong: \(execution)")
        try approvalExpect(PermissionProfileAdapter.launchPlan(for: kind, profile: try PermissionProfileResolver.resolve(definition: flexible, paneFolder: folder)).execution == nil,
            "\(kind.label): Flexible restricts nothing yet produced an execution part")
        // The network rule is carried by Codex's sandbox alone.
        let networked = PermissionProfileAdapter.launchPlan(for: kind, profile: try PermissionProfileResolver.resolve(definition: withNetwork, paneFolder: folder))
        let network = try approvalRequire(networked.network, "\(kind.label): an allowing profile produced no network part")
        try approvalExpect(network.carried == (kind == .codex), "\(kind.label): network carried flag is wrong: \(network)")
    }
    // A plan built the old way still reads as one line.
    let shell = PermissionProfileLaunchPlan(arguments: [], enforcement: .guidanceOnly, detail: "Shell panes use the person's interactive shell permissions.")
    try approvalExpect(shell.mode == shell.detail && shell.reviewer == nil && shell.execution == nil && shell.network == nil,
        "a plan without parts did not default its mode to the detail")
}

private func approvalRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "ApprovalHandling", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

@MainActor
let approvalHandlingChecks: [(String, () throws -> Void)] = [
    ("a permission selection decodes without an approvals choice and keeps one it has", approvalHandlingSelectionDecodingChecks),
    ("vendor automatic review is reached only through documented non-bypass options", approvalHandlingLaunchPlanChecks),
    ("an allowed network rule reaches Codex's sandbox and is disclosed elsewhere", networkRuleChecks),
    ("a launch plan's parts join into its detail and say what the launch carries", launchPlanPartsChecks),
]
