import Foundation

public enum PaneAttentionReason: String, Codable, Equatable, Sendable {
    case permissionRequest
    case returnedResult
    case interruptedHandoff
}

public enum PaneAttentionSource: String, Codable, Equatable, Sendable {
    case vendorOfficialHook
    case durableHandoff
}

/// One authoritative reason to draw attention to a pane or durable handoff.
/// It deliberately contains no terminal text, prompt, result or inferred
/// vendor state.
public struct PaneAttentionItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let paneID: String
    public let handoffID: String?
    public let reason: PaneAttentionReason
    public let source: PaneAttentionSource
    public let occurredAt: Date

    public init(
        id: String,
        paneID: String,
        handoffID: String?,
        reason: PaneAttentionReason,
        source: PaneAttentionSource,
        occurredAt: Date
    ) {
        self.id = id
        self.paneID = paneID
        self.handoffID = handoffID
        self.reason = reason
        self.source = source
        self.occurredAt = occurredAt
    }

    public func label(at now: Date = Date()) -> String {
        let prefix = switch (reason, source) {
        case (.permissionRequest, .vendorOfficialHook): "PERMISSION REPORTED"
        case (.permissionRequest, .durableHandoff): "PERMISSION"
        case (.returnedResult, _): "RESULT"
        case (.interruptedHandoff, _): "INTERRUPTED"
        }
        return "\(prefix) · \(ageLabel(at: now))"
    }

    public func ageLabel(at now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(occurredAt)))
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    public func accessibilityDescription(at now: Date = Date()) -> String {
        switch (reason, source) {
        case (.permissionRequest, .vendorOfficialHook):
            "Official vendor hook reported a permission request \(ageLabel(at: now))."
        case (.permissionRequest, .durableHandoff):
            "A durable handoff requires permission review, updated \(ageLabel(at: now))."
        case (.returnedResult, _):
            "A durable handoff has an unread returned result, updated \(ageLabel(at: now))."
        case (.interruptedHandoff, _):
            "A durable handoff failed or was interrupted, updated \(ageLabel(at: now))."
        }
    }
}

public enum PaneAttentionProjection {
    public static let maximumItems = 512

    public static func items(
        panes: [WorkbenchPane],
        handoffs: [RelayHandoff],
        now: Date = Date()
    ) -> [PaneAttentionItem] {
        var projected: [PaneAttentionItem] = []

        for pane in panes {
            guard pane.isStarted,
                  !pane.isDead,
                  let signal = VendorRuntimeSignalProjection.signal(for: pane),
                  signal.source == .vendorOfficialHook,
                  signal.state == .awaitingPermission,
                  let reportedAt = signal.reportedAt else {
                continue
            }
            projected.append(PaneAttentionItem(
                id: "hook:\(pane.id):awaiting-permission",
                paneID: pane.id,
                handoffID: nil,
                reason: .permissionRequest,
                source: .vendorOfficialHook,
                occurredAt: reportedAt
            ))
        }

        for handoff in handoffs {
            let reason: PaneAttentionReason
            let paneID: String
            if handoff.hasUnreadResult {
                reason = .returnedResult
                paneID = handoff.sourcePaneID
            } else if handoff.attention == .permissionRequired {
                reason = .permissionRequest
                paneID = handoff.targetPaneID
            } else if handoff.state == .failed || handoff.state == .interrupted {
                reason = .interruptedHandoff
                paneID = handoff.sourcePaneID
            } else {
                continue
            }
            projected.append(PaneAttentionItem(
                id: "handoff:\(handoff.id)",
                paneID: paneID,
                handoffID: handoff.id,
                reason: reason,
                source: .durableHandoff,
                occurredAt: handoff.updatedAt
            ))
        }

        return Array(projected.sorted { left, right in
            let leftDate = min(left.occurredAt, now)
            let rightDate = min(right.occurredAt, now)
            if leftDate == rightDate { return left.id < right.id }
            return leftDate > rightDate
        }.prefix(maximumItems))
    }

    public static func primary(
        forPaneID paneID: String,
        in items: [PaneAttentionItem]
    ) -> PaneAttentionItem? {
        items.first { $0.paneID == paneID }
    }
}
