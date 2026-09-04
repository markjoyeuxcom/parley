import Foundation

/// The three headings of the completion-evidence convention. The convention
/// is fully agent-declared: Parley recognises the headings so a person can
/// read the claims in one place, and never checks any of them.
public enum CompletionEvidenceSection: String, CaseIterable, Codable, Equatable, Sendable {
    case implemented
    case tested
    case unableToTest

    public var heading: String {
        switch self {
        case .implemented: "Implemented"
        case .tested: "Tested"
        case .unableToTest: "Unable to test"
        }
    }

    fileprivate static func recognise(_ headingText: String) -> CompletionEvidenceSection? {
        let folded = headingText.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch folded {
        case "implemented": return .implemented
        case "tested": return .tested
        case "unable to test": return .unableToTest
        default: return nil
        }
    }
}

public struct CompletionEvidenceEntry: Identifiable, Equatable, Sendable {
    public let section: CompletionEvidenceSection
    /// The exact lines under the heading, with only leading and trailing
    /// blank lines removed. Lists, code fences and indentation are kept as
    /// plain text; nothing is rendered or rewritten.
    public let body: String
    public var id: String { section.rawValue }

    public init(section: CompletionEvidenceSection, body: String) {
        self.section = section
        self.body = body
    }
}

public struct CompletionEvidence: Equatable, Sendable {
    public static let label = "AGENT-DECLARED"
    /// The same bound as a staged returned file; larger text is not parsed.
    public static let maximumBytes = ContextPackBuilder.defaultMaximumPartBytes
    public static let disclaimer = "Claims from the returned file exactly as staged. Parley ran nothing and checked nothing."

    /// Recognised sections in document order. A duplicate heading's body is
    /// ignored and counted; an empty recognised heading is kept with an empty
    /// body so the person sees that nothing was declared under it.
    public let entries: [CompletionEvidenceEntry]
    public let ignoredHeadingCount: Int
    public let duplicateHeadingCount: Int

    public init(entries: [CompletionEvidenceEntry], ignoredHeadingCount: Int, duplicateHeadingCount: Int) {
        self.entries = entries
        self.ignoredHeadingCount = ignoredHeadingCount
        self.duplicateHeadingCount = duplicateHeadingCount
    }

    public var sections: [CompletionEvidenceSection] { entries.map(\.section) }

    public var missing: [CompletionEvidenceSection] {
        CompletionEvidenceSection.allCases.filter { !sections.contains($0) }
    }

    public func body(for section: CompletionEvidenceSection) -> String? {
        entries.first(where: { $0.section == section })?.body
    }
}

/// A pure, bounded reading of already-staged UTF-8 text. It recognises
/// ordinary ATX headings (one to six `#`, at most three leading spaces, a
/// space after the marks, optional closing marks) whose text is exactly one
/// of the three section names, case-insensitively and with whitespace runs
/// folded. Headings inside fenced code blocks, setext headings, indented
/// code and headings with extra words or punctuation are not recognised.
/// Unknown headings end the current section and their bodies are dropped.
/// The first occurrence of a recognised heading wins. Text with no recognised
/// heading that has content yields nil so the caller falls back unchanged.
public enum CompletionEvidenceProjection {
    public static let template = """
    ## Implemented
    - What changed, one bullet per change.

    ## Tested
    - `command` — the outcome you observed, one line per command you ran.

    ## Unable to test
    - What was not run — the reason.
    """

    public static func evidence(in text: String) -> CompletionEvidence? {
        guard text.utf8.count <= CompletionEvidence.maximumBytes else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var entries: [CompletionEvidenceEntry] = []
        var seen: Set<CompletionEvidenceSection> = []
        var current: CompletionEvidenceSection?
        var body: [String] = []
        var openFence: (marker: Character, length: Int)?
        var ignored = 0
        var duplicates = 0

        func close() {
            if let section = current {
                entries.append(CompletionEvidenceEntry(section: section, body: trimBlankLines(body)))
            }
            current = nil
            body = []
        }

        for line in lines {
            if let fence = fenceMarker(line) {
                if let open = openFence {
                    if fence.marker == open.marker, fence.length >= open.length { openFence = nil }
                } else {
                    openFence = fence
                }
                if current != nil { body.append(line) }
                continue
            }
            if openFence == nil, let headingText = atxHeadingText(line) {
                close()
                if let section = CompletionEvidenceSection.recognise(headingText) {
                    if seen.insert(section).inserted {
                        current = section
                    } else {
                        duplicates += 1
                    }
                } else {
                    ignored += 1
                }
                continue
            }
            if current != nil { body.append(line) }
        }
        close()

        guard entries.contains(where: { !$0.body.isEmpty }) else { return nil }
        return CompletionEvidence(entries: entries, ignoredHeadingCount: ignored, duplicateHeadingCount: duplicates)
    }

    /// Interprets only the exact file the target returned for this
    /// delegation: the one agent-provided draft whose lineage names the
    /// handoff, read from its staged bytes rather than any later human edit.
    /// Person-authored captures beside it, other reviews and other handoffs
    /// are never parsed.
    public static func evidence(for handoff: RelayHandoff, review: AgentContextReview?) -> CompletionEvidence? {
        guard handoff.kind == .delegate,
              let reviewID = handoff.resultContextReviewID,
              let review,
              review.id == reviewID else { return nil }
        let returned = review.pack.parts.filter {
            $0.source.kind == .agentFileDraft && $0.source.referenceID == handoff.id
        }
        guard returned.count == 1, let part = returned.first else { return nil }
        return evidence(in: part.capturedText)
    }

    private static func leadingIndent(_ line: String) -> (spaces: Int, rest: Substring)? {
        var spaces = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            spaces += 1
            index = line.index(after: index)
        }
        guard spaces <= 3 else { return nil }
        return (spaces, line[index...])
    }

    private static func fenceMarker(_ line: String) -> (marker: Character, length: Int)? {
        guard let (_, rest) = leadingIndent(line), let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix(while: { $0 == first }).count
        guard length >= 3 else { return nil }
        return (first, length)
    }

    private static func atxHeadingText(_ line: String) -> String? {
        guard let (_, rest) = leadingIndent(line) else { return nil }
        let marks = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(marks) else { return nil }
        let afterMarks = rest.dropFirst(marks)
        guard afterMarks.isEmpty || afterMarks.first == " " || afterMarks.first == "\t" else { return nil }
        var text = afterMarks.trimmingCharacters(in: .whitespaces)
        if let closing = text.lastIndex(where: { $0 != "#" }) {
            let tail = text[text.index(after: closing)...]
            if !tail.isEmpty, text[closing] == " " || text[closing] == "\t" {
                text = String(text[...closing]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            text = ""
        }
        return text
    }

    private static func trimBlankLines(_ lines: [String]) -> String {
        var slice = lines[...]
        while let first = slice.first, first.trimmingCharacters(in: .whitespaces).isEmpty { slice = slice.dropFirst() }
        while let last = slice.last, last.trimmingCharacters(in: .whitespaces).isEmpty { slice = slice.dropLast() }
        return slice.joined(separator: "\n")
    }
}
