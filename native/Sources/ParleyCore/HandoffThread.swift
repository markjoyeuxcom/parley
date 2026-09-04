import Foundation

/// One step of a lineage thread rendered on the existing handoffs: the
/// instruction that opened a handoff, and its returned result when one exists.
public struct HandoffThreadEntry: Identifiable, Equatable, Sendable {
    public enum Step: String, Equatable, Sendable {
        case ask, delegation, requestChanges, challenge, verify, result, revisedResult, answer

        var isResult: Bool { self == .result || self == .revisedResult || self == .answer }
    }

    public let id: String
    public let handoffID: String
    public let step: Step
    public let occurredAt: Date
    public let sourceName: String
    public let targetName: String
    public let text: String

    public var label: String {
        switch step {
        case .ask: "Ask"
        case .delegation: "Delegation"
        case .requestChanges: "Request changes"
        case .challenge: "Challenge"
        case .verify: "Verify"
        case .result: "Result"
        case .revisedResult: "Revised result"
        case .answer: "Answer"
        }
    }
}

/// Walks `inReplyToHandoffID` links over an explicit set of handoffs. It adds
/// no state: a thread is the root, its descendants and their recorded
/// transitions, ordered by owned timestamps. Missing parents and malformed
/// cycles are tolerated and bounded by the supplied set.
public enum HandoffThreadProjection {
    /// The root and every descendant reachable through the supplied handoffs,
    /// in creation order. A handoff without lineage is its own single member.
    public static func members(containing handoffID: String, in handoffs: [RelayHandoff]) -> [RelayHandoff] {
        var byID: [String: RelayHandoff] = [:]
        for handoff in handoffs where byID[handoff.id] == nil { byID[handoff.id] = handoff }
        guard var root = byID[handoffID] else { return [] }
        var climbed: Set<String> = [root.id]
        while let parentID = root.inReplyToHandoffID,
              let parent = byID[parentID],
              climbed.insert(parent.id).inserted {
            root = parent
        }
        var childrenByParent: [String: [RelayHandoff]] = [:]
        for handoff in handoffs {
            if let parentID = handoff.inReplyToHandoffID {
                childrenByParent[parentID, default: []].append(handoff)
            }
        }
        var visited: Set<String> = []
        var queue = [root]
        var collected: [RelayHandoff] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current.id).inserted else { continue }
            collected.append(current)
            queue.append(contentsOf: childrenByParent[current.id] ?? [])
        }
        return collected.sorted(by: createdBefore)
    }

    public static func children(of handoffID: String, in handoffs: [RelayHandoff]) -> [RelayHandoff] {
        handoffs.filter { $0.inReplyToHandoffID == handoffID }.sorted(by: createdBefore)
    }

    /// Chronological entries for the whole thread, whichever member is named.
    public static func thread(containing handoffID: String, in handoffs: [RelayHandoff]) -> [HandoffThreadEntry] {
        let members = members(containing: handoffID, in: handoffs)
        let order = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1.id, $0) })
        var entries: [HandoffThreadEntry] = []
        for handoff in members where handoff.kind == .ask || handoff.kind == .delegate {
            let opening: HandoffThreadEntry.Step = switch (handoff.kind, handoff.relationship) {
            case (.delegate, .requestChanges): .requestChanges
            case (.delegate, _): .delegation
            case (_, .challenge): .challenge
            case (_, .verify): .verify
            default: .ask
            }
            entries.append(HandoffThreadEntry(
                id: "\(handoff.id):opened",
                handoffID: handoff.id,
                step: opening,
                occurredAt: createdAt(handoff),
                sourceName: handoff.sourceName,
                targetName: handoff.targetName,
                text: handoff.text
            ))
            if handoff.hasReturnedResult {
                let returned: HandoffThreadEntry.Step = if handoff.kind == .ask {
                    .answer
                } else if handoff.relationship == .requestChanges {
                    .revisedResult
                } else {
                    .result
                }
                entries.append(HandoffThreadEntry(
                    id: "\(handoff.id):returned",
                    handoffID: handoff.id,
                    step: returned,
                    occurredAt: handoff.transitions.last(where: { $0.state == handoff.state })?.occurredAt ?? handoff.updatedAt,
                    sourceName: handoff.targetName,
                    targetName: handoff.sourceName,
                    text: handoff.resultText ?? ""
                ))
            }
        }
        return entries.sorted { left, right in
            if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
            let leftOrder = order[left.handoffID] ?? 0
            let rightOrder = order[right.handoffID] ?? 0
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if left.step.isResult != right.step.isResult { return !left.step.isResult }
            return left.id < right.id
        }
    }

    public static func summary(_ entries: [HandoffThreadEntry]) -> String {
        entries.map(\.label).joined(separator: " → ")
    }

    private static func createdAt(_ handoff: RelayHandoff) -> Date {
        handoff.transitions.first?.occurredAt ?? handoff.updatedAt
    }

    private static func createdBefore(_ left: RelayHandoff, _ right: RelayHandoff) -> Bool {
        let leftAt = createdAt(left)
        let rightAt = createdAt(right)
        if leftAt != rightAt { return leftAt < rightAt }
        return left.id < right.id
    }
}
