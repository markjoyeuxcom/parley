import Foundation

public enum CommandPaletteCategory: String, Equatable, Sendable {
    case action
    case workspace
    case pane
    case ask
    case activity
}

public struct CommandPaletteItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: CommandPaletteCategory
    public let title: String
    public let detail: String
    public let keywords: [String]

    public init(
        id: String,
        category: CommandPaletteCategory,
        title: String,
        detail: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.keywords = keywords
    }
}

/// A small deterministic search ranker shared by the native palette and its
/// checks. Every query token must match; title matches outrank details and
/// metadata, while equal scores preserve the caller's intentional ordering.
public enum CommandPaletteSearch {
    public static func results(
        query: String,
        items: [CommandPaletteItem],
        limit: Int = 60
    ) -> [CommandPaletteItem] {
        let bound = max(0, limit)
        guard bound > 0 else { return [] }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return Array(items.prefix(bound)) }

        return items.enumerated().compactMap { index, item -> RankedItem? in
            let title = normalized(item.title)
            let titleTokens = tokens(item.title)
            let detail = normalized(item.detail)
            let keywords = normalized(item.keywords.joined(separator: " "))
            var score = 0

            for token in queryTokens {
                if title == token {
                    score += 0
                } else if title.hasPrefix(token) {
                    score += 10
                } else if titleTokens.contains(token) {
                    score += 15
                } else if titleTokens.contains(where: { $0.hasPrefix(token) }) {
                    score += 20
                } else if title.contains(token) {
                    score += 30
                } else if detail.contains(token) {
                    score += 40
                } else if keywords.contains(token) {
                    score += 50
                } else {
                    return nil
                }
            }
            return RankedItem(item: item, score: score, index: index)
        }
        .sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.index < $1.index
        }
        .prefix(bound)
        .map(\.item)
    }

    private struct RankedItem {
        let item: CommandPaletteItem
        let score: Int
        let index: Int
    }

    private static func tokens(_ text: String) -> [String] {
        normalized(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
