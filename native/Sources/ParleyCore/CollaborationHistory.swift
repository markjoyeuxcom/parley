import Foundation

public enum CollaborationHistoryKindFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all
    case ask
    case delegate
    case relay
    case paste

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All kinds"
        case .ask: "Ask"
        case .delegate: "Delegate"
        case .relay: "Relay"
        case .paste: "Paste"
        }
    }
}

public enum CollaborationHistoryOutcomeFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all
    case active
    case completed
    case needsAttention
    case failedOrInterrupted
    case cancelled

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All outcomes"
        case .active: "Active"
        case .completed: "Completed"
        case .needsAttention: "Needs attention"
        case .failedOrInterrupted: "Failed or interrupted"
        case .cancelled: "Cancelled"
        }
    }
}

public struct CollaborationHistoryFilter: Equatable, Sendable {
    public let query: String
    public let kind: CollaborationHistoryKindFilter
    public let outcome: CollaborationHistoryOutcomeFilter

    public init(
        query: String,
        kind: CollaborationHistoryKindFilter,
        outcome: CollaborationHistoryOutcomeFilter
    ) {
        self.query = query
        self.kind = kind
        self.outcome = outcome
    }
}

/// A bounded in-memory view over the Status Center's authoritative handoff
/// snapshot. Search is literal, case-insensitive and AND-based; it has no query
/// operators and cannot reach state outside the records already loaded.
public enum CollaborationHistoryProjection {
    private static let activeStates: Set<RelayHandoffState> = [
        .created, .delivered, .waiting, .answered,
    ]

    public static func filter(
        _ handoffs: [RelayHandoff],
        using filter: CollaborationHistoryFilter
    ) -> [RelayHandoff] {
        let tokens = filter.query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        return handoffs
            .filter { matchesKind($0, filter.kind) }
            .filter { matchesOutcome($0, filter.outcome) }
            .filter { handoff in
                guard !tokens.isEmpty else { return true }
                let searchable = searchableText(handoff)
                return tokens.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
            }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt { return left.id < right.id }
                return left.updatedAt > right.updatedAt
            }
    }

    /// A full-workspace export is based on durable workspace identity rather
    /// than the currently visible filters or dismissal preference. A
    /// cross-workspace handoff belongs in both involved workspaces.
    public static func records(
        _ handoffs: [RelayHandoff],
        involvingWorkspaceID workspaceID: String
    ) -> [RelayHandoff] {
        handoffs
            .filter {
                $0.sourceWorkspaceID == workspaceID || $0.targetWorkspaceID == workspaceID
            }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt { return left.id < right.id }
                return left.updatedAt > right.updatedAt
            }
    }

    private static func matchesKind(
        _ handoff: RelayHandoff,
        _ filter: CollaborationHistoryKindFilter
    ) -> Bool {
        switch filter {
        case .all: true
        case .ask: handoff.kind == .ask
        case .delegate: handoff.kind == .delegate
        case .relay: handoff.kind == .relay
        case .paste: handoff.kind == .paste
        }
    }

    private static func matchesOutcome(
        _ handoff: RelayHandoff,
        _ filter: CollaborationHistoryOutcomeFilter
    ) -> Bool {
        switch filter {
        case .all: true
        case .active: activeStates.contains(handoff.state)
        case .completed: handoff.state == .completed
        case .needsAttention: handoff.attention != nil
        case .failedOrInterrupted: handoff.state == .failed || handoff.state == .interrupted
        case .cancelled: handoff.state == .cancelled
        }
    }

    private static func searchableText(_ handoff: RelayHandoff) -> String {
        var fields = [
            handoff.id,
            handoff.kind.rawValue,
            handoff.state.rawValue,
            handoff.sourcePaneID,
            handoff.sourceName,
            handoff.sourceKind?.rawValue ?? "",
            handoff.sourceWorkspaceID,
            handoff.sourceWorkspaceName ?? "",
            handoff.targetPaneID,
            handoff.targetName,
            handoff.targetKind?.rawValue ?? "",
            handoff.targetWorkspaceID,
            handoff.targetWorkspaceName ?? "",
            handoff.text,
            handoff.resultText ?? "",
            handoff.attention?.rawValue ?? "",
            handoff.retryDisposition?.rawValue ?? "",
            handoff.inReplyToHandoffID ?? "",
            handoff.relationship?.rawValue ?? "",
            handoff.humanVerdict?.rawValue ?? "",
            handoff.humanReviewNote ?? "",
            handoff.reviewedAt.map(String.init(describing:)) ?? "",
        ]
        fields.append(contentsOf: handoff.transitions.compactMap(\.detail))
        return fields.joined(separator: "\n")
    }
}

public struct RepeatAskRoute: Equatable, Sendable {
    public let sourcePaneID: String
    public let targetPaneID: String

    public init(sourcePaneID: String, targetPaneID: String) {
        self.sourcePaneID = sourcePaneID
        self.targetPaneID = targetPaneID
    }
}

/// Repeating is available only when the original route can still pass the
/// same distinct-pane readiness boundary as a new Ask. The caller must still
/// show an editable preview and dispatch a fresh handoff identity.
public enum CollaborationHistoryRepeat {
    public static func route(
        for handoff: RelayHandoff,
        panes: [WorkbenchPane]
    ) -> RepeatAskRoute? {
        guard handoff.kind == .ask,
              handoff.submitted,
              ![RelayHandoffState.created, .delivered, .waiting, .answered].contains(handoff.state),
              let source = panes.first(where: { $0.id == handoff.sourcePaneID }),
              let target = panes.first(where: { $0.id == handoff.targetPaneID }),
              source.id != target.id,
              source.kind.isAgent,
              target.kind.isAgent,
              source.isStarted,
              !source.isDead,
              source.relayEnabled,
              source.hasCurrentProtocol,
              source.inputAvailable,
              target.isStarted,
              !target.isDead,
              target.relayEnabled,
              target.hasCurrentProtocol,
              target.inputAvailable else { return nil }
        return RepeatAskRoute(sourcePaneID: source.id, targetPaneID: target.id)
    }
}

public enum CollaborationHistoryMarkdown {
    public static func document(
        handoffs: [RelayHandoff],
        scopeName: String?,
        selectionDescription: String? = nil,
        generatedAt: Date = Date()
    ) -> String {
        let ordered = handoffs.sorted { left, right in
            if left.updatedAt == right.updatedAt { return left.id < right.id }
            return left.updatedAt > right.updatedAt
        }
        var lines = [
            "# Parley Collaboration History",
            "",
            "> Explicit local export. It contains the complete question, instruction, and returned-result bodies for only the records selected in Status Center.",
            "",
            "- Exported: \(timestamp(generatedAt))",
            "- Scope: \(inline(scopeName ?? "All Workspaces"))",
            "- Selection: \(selectionDescription.map(inline) ?? "\(ordered.count) selected record\(ordered.count == 1 ? "" : "s")")",
        ]

        for (index, handoff) in ordered.enumerated() {
            lines.append(contentsOf: [
                "",
                "## \(index + 1). \(inline(handoff.sourceName)) → \(inline(handoff.targetName))",
                "",
                "- Handoff ID: `\(inlineCode(handoff.id))`",
                "- Kind: \(handoff.kind.rawValue)",
                "- State: \(handoff.state.rawValue)",
                "- Updated: \(timestamp(handoff.updatedAt))",
                "- Source workspace: \(inline(handoff.sourceWorkspaceName ?? handoff.sourceWorkspaceID))",
                "- Target workspace: \(inline(handoff.targetWorkspaceName ?? handoff.targetWorkspaceID))",
            ])
            if let attention = handoff.attention {
                lines.append("- Attention: \(attention.rawValue)")
            }
            if let parentID = handoff.inReplyToHandoffID {
                lines.append("- In reply to: `\(inlineCode(parentID))`")
            }
            if let relationship = handoff.relationship {
                lines.append("- Relationship: \(relationship.rawValue)")
            }
            if let verdict = handoff.humanVerdict {
                lines.append("- Human verdict: \(verdict.rawValue)")
            }
            if let reviewedAt = handoff.reviewedAt {
                lines.append("- Reviewed: \(timestamp(reviewedAt))")
            }
            if let note = handoff.humanReviewNote, !note.isEmpty {
                lines.append(contentsOf: ["", "### Human review note", "", fencedBlock(note)])
            }
            lines.append(contentsOf: [
                "",
                handoff.kind == .delegate ? "### Instruction" : "### Question or message",
                "",
                fencedBlock(handoff.text),
            ])
            if let result = handoff.resultText,
               !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(contentsOf: [
                    "",
                    "### Returned result",
                    "",
                    fencedBlock(result),
                ])
            }
            lines.append(contentsOf: ["", "### Delivery receipts", ""])
            for transition in handoff.transitions {
                var receipt = "- \(timestamp(transition.occurredAt)) — \(transition.state.rawValue)"
                if transition.origin == .human { receipt += " — human" }
                if transition.origin == .automation { receipt += " — Auto" }
                if let detail = transition.detail, !detail.isEmpty {
                    receipt += " — \(inline(detail))"
                }
                lines.append(receipt)
            }
            if let readAt = handoff.readAt {
                lines.append("- \(timestamp(readAt)) — viewed")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func inline(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func inlineCode(_ text: String) -> String {
        inline(text).replacingOccurrences(of: "`", with: "ʼ")
    }

    private static func fencedBlock(_ text: String) -> String {
        let run = longestBacktickRun(in: text)
        let fence = String(repeating: "`", count: max(3, run + 1))
        return "\(fence)text\n\(text)\n\(fence)"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

public enum CollaborationHistoryMarkdownWriterError: LocalizedError, Equatable {
    case invalidDestination

    public var errorDescription: String? {
        "Choose a regular local file for the collaboration-history export."
    }
}

public enum CollaborationHistoryMarkdownWriter {
    public static func write(
        _ markdown: String,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        guard destination.isFileURL else {
            throw CollaborationHistoryMarkdownWriterError.invalidDestination
        }
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CollaborationHistoryMarkdownWriterError.invalidDestination
            }
        }
        try Data(markdown.utf8).write(to: destination, options: .atomic)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
