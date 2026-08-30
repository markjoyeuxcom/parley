import Foundation

/// Stable spoken descriptions for dense workbench controls. Keeping the
/// composition here lets every native surface announce the same authoritative
/// state without asking VoiceOver to reconstruct it from decorative fragments.
public enum WorkbenchAccessibility {
    public static func subject(_ text: String) -> String {
        firstLine(text)
    }

    public static func command(_ item: CommandPaletteItem) -> String {
        "\(category(item.category)): \(clean(item.title)). \(clean(item.detail))"
    }

    public static func handoff(_ handoff: RelayHandoff) -> String {
        var parts = [
            "\(clean(handoff.sourceName)) to \(clean(handoff.targetName))",
            "\(sentenceCase(handoff.kind.rawValue)), \(handoffState(handoff))",
            firstLine(handoff.text),
        ]
        if handoff.transitions.contains(where: { $0.origin == .human }) {
            parts.append("Human initiated")
        }
        return sentences(parts)
    }

    public static func counts(_ counts: StatusCenterCounts) -> String {
        [
            quantity(counts.runningAgents, "running agent"),
            quantity(counts.stoppedAgents, "stopped agent"),
            quantity(counts.outstandingQuestions, "question"),
            quantity(counts.trackedDelegations, "delegation"),
            quantity(counts.unreadResults, "unread result"),
            quantity(counts.failures, "failure", plural: "failures"),
        ].joined(separator: ", ")
    }

    public static func agent(_ pane: WorkbenchPane) -> String {
        let state: String = switch WorkbenchStateProjection.pane(pane) {
        case .empty: "No pane"
        case .running: pane.inputAvailable ? "Running, input available" : "Running, input unavailable"
        case .stopped: "Not started"
        case let .exited(status): status.map { "Exited with status \($0)" } ?? "Exited"
        case .protocolStale: "Protocol restart required"
        case .relayUnavailable: "Relay restart required"
        }
        let protocolState: String = switch WorkbenchStateProjection.protocolStatus(pane) {
        case .notAttached: "Protocol not attached"
        case let .current(version): "Protocol v\(version), current"
        case let .restartRequired(reportedVersion):
            reportedVersion.map { "Protocol v\($0), restart required" }
                ?? "Protocol unknown, restart required"
        }
        let workspace = clean(pane.workspaceName ?? pane.workspaceID)
        var parts = [
            "\(clean(pane.displayName)), \(pane.kind.label) agent",
            state,
            protocolState,
        ]
        if let role = pane.role { parts.append("Routing role \(role)") }
        parts.append("Workspace \(workspace)")
        return sentences(parts)
    }

    public static func timeline(_ event: StatusTimelineEvent) -> String {
        var parts = [
            clean(event.title),
            "\(sentenceCase(event.category)), \(event.action.lowercased())",
        ]
        if event.origin == .human { parts.append("Human initiated") }
        if let detail = event.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(brief(clean(detail)))
        }
        return sentences(parts)
    }

    private static func handoffState(_ handoff: RelayHandoff) -> String {
        var state = handoff.state.rawValue
        if let attention = handoff.attention {
            state += ", \(attentionLabel(attention))"
        }
        if handoff.hasUnreadResult { state += ", unread result" }
        return state
    }

    private static func attentionLabel(_ attention: RelayAttention) -> String {
        switch attention {
        case .targetNotReady: "target not ready"
        case .permissionRequired: "permission required"
        case .targetUnavailable: "target unavailable"
        }
    }

    private static func category(_ category: CommandPaletteCategory) -> String {
        switch category {
        case .action: "Action"
        case .workspace: "Workspace"
        case .pane: "Pane"
        case .ask: "Ask"
        case .activity: "Activity"
        }
    }

    private static func firstLine(_ text: String) -> String {
        brief(clean(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text))
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.map(clean).filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    private static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst().lowercased()
    }

    private static func brief(_ text: String, limit: Int = 180) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func quantity(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
}
