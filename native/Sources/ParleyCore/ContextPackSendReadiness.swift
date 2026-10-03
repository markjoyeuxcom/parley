import Foundation

/// Why a context pack's Ask One Pane or Compare Panes button is disabled, so
/// the sheet can say so instead of leaving a dead button (Codex's review of
/// 3 October 2026). The conditions are the ones `AppModel` already enforces;
/// this only names the first one that fails.
public enum ContextPackSendReadiness {
    public struct Inputs: Equatable, Sendable {
        public var captureRunning: Bool
        public var sourceReady: Bool
        public var hasParts: Bool
        public var hasNote: Bool
        public var withinLimits: Bool
        public var targetCount: Int
        public var isAgentDraft: Bool
        public var comparisonRunning: Bool
        public var coreAvailable: Bool

        public init(
            captureRunning: Bool, sourceReady: Bool, hasParts: Bool, hasNote: Bool, withinLimits: Bool,
            targetCount: Int, isAgentDraft: Bool, comparisonRunning: Bool, coreAvailable: Bool
        ) {
            self.captureRunning = captureRunning
            self.sourceReady = sourceReady
            self.hasParts = hasParts
            self.hasNote = hasNote
            self.withinLimits = withinLimits
            self.targetCount = targetCount
            self.isAgentDraft = isAgentDraft
            self.comparisonRunning = comparisonRunning
            self.coreAvailable = coreAvailable
        }
    }

    /// Nil when the pack can be sent to one pane.
    public static func askBlockedReason(_ inputs: Inputs) -> String? {
        if let reason = packBlockedReason(inputs) { return reason }
        if inputs.targetCount == 0 { return "No other agent pane is ready to receive it." }
        return nil
    }

    /// Nil when the pack can be compared across panes.
    public static func compareBlockedReason(_ inputs: Inputs) -> String? {
        if inputs.isAgentDraft { return "Compare sends only your own pack; an agent's draft goes to one pane." }
        if let reason = packBlockedReason(inputs) { return reason }
        if inputs.targetCount < 2 { return "Compare needs two ready agent panes besides the source." }
        if inputs.comparisonRunning { return "A comparison is already running." }
        if !inputs.coreAvailable { return "Parley's coordination core is not connected." }
        return nil
    }

    private static func packBlockedReason(_ inputs: Inputs) -> String? {
        if inputs.captureRunning { return "Wait for the capture to finish." }
        if !inputs.sourceReady { return "The pack's source pane is not running or needs Restart for Protocol." }
        if !inputs.hasParts { return "Add at least one source." }
        if !inputs.hasNote { return "Write the request to send with the pack." }
        if !inputs.withinLimits { return "A source is empty or too large, or the pack is over its limit." }
        return nil
    }
}
