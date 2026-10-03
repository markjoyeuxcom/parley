import Foundation

/// Whether the files a pack captured still read as they did, checked just
/// before the pack is sent. A captured file is a snapshot and stays valid as
/// one, but a file edited in another pane while the pack sat open was sent
/// as it had been, with nothing said (Agy's and Codex's reviews of 3 October
/// 2026). Only text `file` parts are checked: a Git diff would mean running
/// Git again, and an image is checked by its digest when it is stored.
public enum ContextPackFreshness {
    public enum State: Equatable, Sendable {
        case unchanged
        case changed
        case missing
        /// The file is there but no longer reads as a text part (it grew past
        /// the part bound, stopped being UTF-8, or could not be opened).
        case unreadable
    }

    public struct Item: Equatable, Sendable {
        public let partID: String
        public let name: String
        public let path: String
        public let state: State
        /// The person edited the captured text, so a fresh capture would
        /// replace their edits.
        public let edited: Bool
        /// The file as it reads now, when it reads at all.
        public let fresh: ContextPackPart?
    }

    /// The parts this checks: a text file the pack captured by its path.
    public static func checkable(_ parts: [ContextPackPart]) -> [ContextPackPart] {
        parts.filter { $0.source.kind == .file && $0.image == nil && $0.source.detail.hasPrefix("/") }
    }

    public static func check(_ parts: [ContextPackPart], builder: ContextPackBuilder, fileManager: FileManager = .default) -> [Item] {
        checkable(parts).map { part in
            let path = part.source.detail
            let state: State
            var fresh: ContextPackPart?
            if !fileManager.fileExists(atPath: path) {
                state = .missing
            } else if let read = try? builder.file(at: URL(fileURLWithPath: path)) {
                fresh = read
                state = read.capturedText == part.capturedText ? .unchanged : .changed
            } else {
                state = .unreadable
            }
            return Item(partID: part.id, name: part.source.label, path: path, state: state, edited: part.isEdited, fresh: fresh)
        }
    }

    /// What the warning says, or nil when every checked file reads as it did.
    public static func summary(_ items: [Item]) -> String? {
        let stale = items.filter { $0.state != .unchanged }
        guard !stale.isEmpty else { return nil }
        let lines = stale.prefix(8).map { item -> String in
            let what = switch item.state {
            case .changed: "changed on disk since it was added"
            case .missing: "no longer there"
            case .unreadable: "no longer reads as a text part"
            case .unchanged: ""
            }
            return "• \(ContextPackText.singleLine(item.name)): \(what)"
        }
        let more = stale.count > 8 ? ["• and \(stale.count - 8) more"] : []
        return (lines + more).joined(separator: "\n")
    }

    /// The pack's parts with each changed, unedited file captured again.
    /// Edited parts and files that cannot be read stay as they are.
    public static func recaptured(_ parts: [ContextPackPart], items: [Item]) -> [ContextPackPart] {
        let replacements = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, ContextPackPart)? in
            guard item.state == .changed, !item.edited, let fresh = item.fresh else { return nil }
            return (item.partID, fresh)
        })
        return parts.map { replacements[$0.id] ?? $0 }
    }
}
