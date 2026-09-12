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
    func hasPair(_ arguments: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == value
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

    // Invariant 3: no skip-all flag reaches any host launch, whichever choice.
    let forbidden = ["--yolo", "--full-auto", "--allow-all", "--allow-all-tools", "--allow-all-paths", "--allow-all-urls"]
    for kind in PaneKind.allCases where kind.isAgent {
        for definition in [flexible, reviewOnly] {
            for approvals in PermissionApprovalHandling.allCases {
                let arguments = try plan(kind, definition, approvals).arguments
                try approvalExpect(!arguments.contains { argument in
                    argument.hasPrefix("--dangerously") || forbidden.contains(argument)
                        || argument.contains("danger-full-access") || argument.contains("bypassPermissions")
                }, "\(kind.label) with \(approvals.rawValue) carried a skip-all flag: \(arguments)")
            }
        }
    }
}

private func approvalRequire<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "ApprovalHandling", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}

@MainActor
let approvalHandlingChecks: [(String, () throws -> Void)] = [
    ("a permission selection decodes without an approvals choice and keeps one it has", approvalHandlingSelectionDecodingChecks),
    ("vendor automatic review is reached only through documented non-bypass options", approvalHandlingLaunchPlanChecks),
]
