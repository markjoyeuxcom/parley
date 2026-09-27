import Foundation
import ParleyCore

private func snapshotExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "StatusSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Review of 22 September 2026 (02e8932f): Status Center's snapshot was a
/// computed property that sorted every handoff and timeline event, read
/// about twenty times per render and once more per row. One projection per
/// scope and input generation must serve every read.
func checkStatusSnapshotIsComputedOncePerGeneration() throws {
    let panes = [WorkbenchPane(id: "pane-a", kind: .claude, customName: "A", terminalTitle: "", cwd: "/private/a", currentCommand: "claude",
                               isActive: false, workspaceID: "@one", relayEnabled: true, protocolVersion: AgentProtocol.version,
                               workspaceName: "One", inputAvailable: true)]
    func project(_ workspaceID: String?, _ includeDismissed: Bool) -> StatusCenterSnapshot {
        StatusCenterProjection.snapshot(panes: panes, handoffs: [], workspaceID: workspaceID, coreAvailable: true,
                                        includeDismissed: includeDismissed)
    }
    var cache = StatusSnapshotCache()
    let everything = StatusSnapshotCache.Scope(workspaceID: nil, includeDismissed: false)
    let history = StatusSnapshotCache.Scope(workspaceID: nil, includeDismissed: true)
    var first: StatusCenterSnapshot?
    for _ in 0..<20 {
        let read = cache.snapshot(generation: 1, scope: everything) { project(nil, false) }
        if first == nil { first = read }
    }
    try snapshotExpect(cache.computeCount == 1, "twenty reads in one generation projected \(cache.computeCount) times")
    try snapshotExpect(first == project(nil, false), "the cached snapshot differs from the projection")

    // A second scope in the same render (history with dismissed records) is kept alongside.
    for _ in 0..<5 {
        _ = cache.snapshot(generation: 1, scope: history) { project(nil, true) }
        _ = cache.snapshot(generation: 1, scope: everything) { project(nil, false) }
    }
    try snapshotExpect(cache.computeCount == 2, "two scopes read alternately projected \(cache.computeCount) times")

    // Any input change is a new generation: every scope is projected again.
    _ = cache.snapshot(generation: 2, scope: everything) { project(nil, false) }
    _ = cache.snapshot(generation: 2, scope: history) { project(nil, true) }
    try snapshotExpect(cache.computeCount == 4, "a new generation reused an old snapshot (\(cache.computeCount) projections)")
    let scoped = StatusSnapshotCache.Scope(workspaceID: "@one", includeDismissed: false)
    let read = cache.snapshot(generation: 2, scope: scoped) { project("@one", false) }
    try snapshotExpect(read == project("@one", false) && cache.computeCount == 5, "a workspace scope was not projected for itself")
}

/// The cache is only as good as its generation: every value AppModel passes
/// into the projection must bump `statusInputGeneration` when it changes, or
/// Status Center shows stale work. This reads AppModel's source so an input
/// added to `statusSnapshot` without a bump fails here.
func checkStatusSnapshotInputsBumpTheGeneration() throws {
    let appModel = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ParleyNative").appendingPathComponent("AppModel.swift")
    let source = try String(contentsOf: appModel, encoding: .utf8)
    guard let start = source.range(of: "func statusSnapshot(workspaceID: String?"),
          let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
        throw NSError(domain: "StatusSnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "AppModel.statusSnapshot was not found"])
    }
    let body = String(source[start.upperBound..<end.lowerBound])
    try snapshotExpect(body.contains("statusSnapshotCache.snapshot(") && body.contains("generation: statusInputGeneration"),
                       "AppModel.statusSnapshot does not read through the generation-keyed cache")
    // Every model value the projection call receives, as `label: value`.
    // The call's arguments are plain names, so they end at its first parenthesis.
    let projection = (body.components(separatedBy: "StatusCenterProjection.snapshot(").dropFirst().first ?? "").prefix { $0 != ")" }
    let arguments = projection.components(separatedBy: ",").compactMap { part -> String? in
        let pieces = part.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2 else { return nil }
        return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: " \n)"))
    }
    // Values that are this call's own parameters, not model state.
    let parameters: Set<String> = ["workspaceID", "includeDismissed"]
    // A computed input (`var name: Type { … }` with no stored value) stands
    // for the stored properties its body reads, read from its body so a later
    // edit to it is followed too.
    func storedInputs(of name: String) throws -> [String] {
        let computed = try NSRegularExpression(pattern: "var \(NSRegularExpression.escapedPattern(for: name)): [^={\n]+\\{([^\n]*)\\}")
        guard let match = computed.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let bodyRange = Range(match.range(at: 1), in: source) else { return [name] }
        let identifiers = try NSRegularExpression(pattern: "\\b[a-z][A-Za-z0-9]*\\b")
        let text = String(source[bodyRange])
        return identifiers.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { source.contains("private(set) var \($0):") || source.contains("private(set) var \($0) =") }
    }
    let inputs = try arguments.filter { !parameters.contains($0) }.flatMap(storedInputs)
    try snapshotExpect(inputs.count >= 6 && inputs.contains("statusHandoffs") && inputs.contains("handoffs"),
                       "could not read the projection's inputs from AppModel.statusSnapshot: \(arguments) → \(inputs)")
    for input in inputs {
        let declaration = try NSRegularExpression(pattern: "var \(NSRegularExpression.escapedPattern(for: input))\\b[^\\n]*\\{\\s*\\n?\\s*didSet \\{[^}]*statusInputGeneration &\\+= 1")
        try snapshotExpect(declaration.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil,
                           "AppModel.\(input) feeds Status Center's snapshot but its didSet does not bump statusInputGeneration")
    }

    // The history fetch's revision gate: a new broker (core recovery) counts
    // its revision from zero again, so wherever the relay tick forgets its
    // revision the status fetch must forget its own.
    let relayResets = source.components(separatedBy: "lastAppliedRelayRevision = nil").count - 1
    let statusResets = source.components(separatedBy: "lastAppliedStatusRevision = nil").count - 1
    try snapshotExpect(relayResets > 0 && statusResets == relayResets,
                       "the relay tick forgets its broker revision in \(relayResets) places and the status history fetch in \(statusResets)")
}

@MainActor let statusSnapshotChecks: [(String, () throws -> Void)] = [
    ("status center snapshot is computed once per input generation", checkStatusSnapshotIsComputedOncePerGeneration),
    ("every status center snapshot input bumps its generation", checkStatusSnapshotInputsBumpTheGeneration),
]
