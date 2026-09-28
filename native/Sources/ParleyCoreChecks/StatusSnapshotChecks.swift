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

/// A small reader for the parts of AppModel's source the wiring check needs.
/// Comments are removed first (string literals are kept intact), and every
/// body is taken by balancing its delimiters, so formatting, a `willSet`
/// beside the `didSet` or a comment naming a property does not change the
/// verdict (Agy's review of MR !111).
struct SwiftSourceReader {
    let text: String

    init(_ source: String) {
        var output = ""
        var index = source.startIndex
        var inString = false
        var multiline = false
        func starts(_ token: String, at position: String.Index) -> Bool { source[position...].hasPrefix(token) }
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if multiline, starts("\"\"\"", at: index) {
                    output += "\"\"\""; index = source.index(index, offsetBy: 3); inString = false; continue
                }
                if character == "\\" {
                    output.append(character); index = source.index(after: index)
                    if index < source.endIndex { output.append(source[index]); index = source.index(after: index) }
                    continue
                }
                if !multiline, character == "\"" { inString = false }
                output.append(character); index = source.index(after: index); continue
            }
            if starts("//", at: index) {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            if starts("/*", at: index) {
                guard let close = source.range(of: "*/", range: index..<source.endIndex) else { break }
                index = close.upperBound; continue
            }
            if starts("\"\"\"", at: index) {
                output += "\"\"\""; index = source.index(index, offsetBy: 3); inString = true; multiline = true; continue
            }
            if character == "\"" { inString = true; multiline = false }
            output.append(character); index = source.index(after: index)
        }
        text = output
    }

    /// The text between the delimiter at `open` and its matching close.
    func balanced(at open: String.Index) -> Substring? {
        let pairs: [Character: Character] = ["{": "}", "(": ")", "[": "]"]
        guard let close = pairs[text[open]] else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == text[open] { depth += 1 } else if text[index] == close {
                depth -= 1
                if depth == 0 { return text[text.index(after: open)..<index] }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The bodies of `final class AppModel` and every `extension AppModel`.
    func memberRegions(of type: String) -> [Substring] {
        let pattern = try! NSRegularExpression(pattern: "(?:final class|extension) \(type)\\b[^{]*\\{")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { balanced(at: text.index(before: $0.upperBound)) }
        }
    }

    /// Top-level comma-separated parts of a delimited list.
    static func topLevelParts(_ list: Substring) -> [Substring] {
        var parts: [Substring] = []
        var depth = 0
        var start = list.startIndex
        for index in list.indices {
            switch list[index] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "," where depth == 0:
                parts.append(list[start..<index]); start = list.index(after: index)
            default: break
            }
        }
        parts.append(list[start...])
        return parts
    }
}

/// The cache is only as good as its generation: every value AppModel passes
/// into the projection must bump `statusInputGeneration` when it changes, or
/// Status Center shows stale work. This reads AppModel's source so an input
/// added to `statusSnapshot` without a bump fails here, following computed
/// properties to the stored ones they read.
func checkStatusSnapshotInputsBumpTheGeneration() throws {
    let appModel = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ParleyNative").appendingPathComponent("AppModel.swift")
    let reader = SwiftSourceReader(try String(contentsOf: appModel, encoding: .utf8))
    let text = reader.text
    let regions = reader.memberRegions(of: "AppModel")
    try snapshotExpect(!regions.isEmpty, "AppModel's class body was not found")
    func fail(_ message: String) -> NSError { NSError(domain: "StatusSnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }

    guard let function = text.range(of: "func statusSnapshot(workspaceID: String?"),
          let open = text[function.upperBound...].firstIndex(of: "{"),
          let body = reader.balanced(at: open) else { throw fail("AppModel.statusSnapshot was not found") }
    try snapshotExpect(body.contains("statusSnapshotCache.snapshot(") && body.contains("generation: statusInputGeneration"),
                       "AppModel.statusSnapshot does not read through the generation-keyed cache")
    guard let call = body.range(of: "StatusCenterProjection.snapshot("),
          let arguments = reader.balanced(at: body.index(before: call.upperBound)) else {
        throw fail("AppModel.statusSnapshot does not call StatusCenterProjection.snapshot")
    }

    /// A member of AppModel (class body or extension), at member level only.
    func member(_ name: String) -> (region: Substring, start: String.Index)? {
        let declaration = try! NSRegularExpression(pattern: "(?m)^    (?:@\\w+(?:\\([^)\\n]*\\))?\\s+|(?:private|fileprivate|internal|public|open)(?:\\(set\\))?\\s+|static\\s+|lazy\\s+|nonisolated\\s+)*var \(NSRegularExpression.escapedPattern(for: name))\\b")
        for region in regions {
            let string = String(region)
            if let match = declaration.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
               let range = Range(match.range, in: string) {
                let offset = string.distance(from: string.startIndex, to: range.upperBound)
                return (region, region.index(region.startIndex, offsetBy: offset))
            }
        }
        return nil
    }
    /// The accessor or observer block of a declaration (the first `{` on its
    /// line, or one that starts the next line) and whether it has an initial
    /// value. Swift types contain no braces.
    func declaration(after start: String.Index, in region: Substring) -> (block: Substring?, initialValue: Bool) {
        guard let lineEnd = region[start...].firstIndex(of: "\n") else { return (nil, false) }
        let line = region[start..<lineEnd]
        if let open = line.firstIndex(of: "{") {
            return (reader.balanced(at: open), line[..<open].contains("="))
        }
        let next = region[region.index(after: lineEnd)...].drop { $0 == " " || $0 == "\n" }
        return (next.first == "{" ? reader.balanced(at: next.startIndex) : nil, line.contains("="))
    }
    let identifier = try NSRegularExpression(pattern: "(?<![.\\w])[a-z][A-Za-z0-9_]*\\b")
    func identifiers(in expression: Substring) -> [String] {
        let string = String(expression)
        return identifier.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
            Range($0.range, in: string).map { String(string[$0]) }
        }
    }
    // Values that are this call's own parameters, not model state.
    let parameters: Set<String> = ["workspaceID", "includeDismissed"]
    var stored: [String: Substring?] = [:]
    var visited: Set<String> = []
    func resolve(_ name: String) {
        guard !parameters.contains(name), visited.insert(name).inserted, let (region, start) = member(name) else { return }
        let (accessors, initialValue) = declaration(after: start, in: region)
        if let accessors, !initialValue, !accessors.contains("didSet"), !accessors.contains("willSet") {
            // Computed: it stands for whatever it reads.
            for inner in identifiers(in: accessors) { resolve(inner) }
        } else {
            stored[name] = accessors
        }
    }
    let parts = SwiftSourceReader.topLevelParts(arguments)
    for part in parts {
        guard let colon = part.firstIndex(of: ":") else { throw fail("an unlabelled projection argument: \(part)") }
        for name in identifiers(in: part[part.index(after: colon)...]) { resolve(name) }
    }
    try snapshotExpect(stored.count >= 6 && stored["statusHandoffs"] != nil && stored["handoffs"] != nil,
                       "could not read the projection's inputs from AppModel.statusSnapshot: \(stored.keys.sorted())")
    let bump = try NSRegularExpression(pattern: "statusInputGeneration\\s*&\\+=\\s*1")
    for (name, accessors) in stored.sorted(by: { $0.key < $1.key }) {
        guard let accessors, let didSet = accessors.range(of: "didSet"),
              let open = accessors[didSet.upperBound...].firstIndex(of: "{"),
              let observer = reader.balanced(at: open) else {
            throw fail("AppModel.\(name) feeds Status Center's snapshot but has no didSet")
        }
        let string = String(observer)
        try snapshotExpect(bump.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil,
                           "AppModel.\(name) feeds Status Center's snapshot but its didSet does not bump statusInputGeneration")
    }

    // The history fetch's revision gate: a new broker (core recovery) counts
    // its revision from zero again, so wherever the relay tick forgets its
    // revision the status fetch must forget its own. Counted without comments.
    let relayResets = text.components(separatedBy: "lastAppliedRelayRevision = nil").count - 1
    let statusResets = text.components(separatedBy: "lastAppliedStatusRevision = nil").count - 1
    try snapshotExpect(relayResets > 0 && statusResets == relayResets,
                       "the relay tick forgets its broker revision in \(relayResets) places and the status history fetch in \(statusResets)")
}

@MainActor let statusSnapshotChecks: [(String, () throws -> Void)] = [
    ("status center snapshot is computed once per input generation", checkStatusSnapshotIsComputedOncePerGeneration),
    ("every status center snapshot input bumps its generation", checkStatusSnapshotInputsBumpTheGeneration),
]
