import Foundation

public struct VendorConformanceProbe: Equatable, Sendable {
    public let vendor: PaneKind
    public let source: TmuxPane
    public let target: TmuxPane

    public init(vendor: PaneKind, source: TmuxPane, target: TmuxPane) {
        self.vendor = vendor
        self.source = source
        self.target = target
    }

    public var testsInactiveTarget: Bool { !target.isActive }
    public var testsCrossWorkspace: Bool { source.workspaceID != target.workspaceID }
}

public enum VendorConformancePlanItem: Equatable, Sendable {
    case probe(VendorConformanceProbe)
    case skipped(vendor: PaneKind, reason: String)
}

public enum VendorConformancePlanner {
    public static func plan(
        panes: [TmuxPane],
        vendors: [PaneKind] = PaneKind.allCases.filter(\.isAgent)
    ) -> [VendorConformancePlanItem] {
        vendors.filter(\.isAgent).map { vendor in
            plan(vendor: vendor, panes: panes)
        }
    }

    private static func plan(vendor: PaneKind, panes: [TmuxPane]) -> VendorConformancePlanItem {
        let vendorPanes = panes.filter { $0.kind == vendor }
        guard !vendorPanes.isEmpty else {
            return .skipped(vendor: vendor, reason: "No open \(vendor.label) pane.")
        }

        let targets = vendorPanes.filter(isReadyTarget)
        guard !targets.isEmpty else {
            let reasons = readinessReasons(for: vendorPanes).joined(separator: "; ")
            return .skipped(vendor: vendor, reason: "No safe \(vendor.label) target: \(reasons).")
        }

        let sources = panes.filter {
            $0.kind.isAgent
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
        guard sources.count >= 2 else {
            return .skipped(
                vendor: vendor,
                reason: "No other current, relay-enabled agent pane is open."
            )
        }

        let candidates = targets.flatMap { target in
            sources.compactMap { source in
                source.id == target.id
                    ? nil
                    : VendorConformanceProbe(vendor: vendor, source: source, target: target)
            }
        }
        let selected = candidates.enumerated().max { left, right in
            score(left.element) == score(right.element)
                ? left.offset > right.offset
                : score(left.element) < score(right.element)
        }?.element
        guard let selected else {
            return .skipped(vendor: vendor, reason: "No safe distinct-pane probe route is available.")
        }
        return .probe(selected)
    }

    private static func isReadyTarget(_ pane: TmuxPane) -> Bool {
        pane.isStarted
            && !pane.isDead
            && pane.relayEnabled
            && pane.hasCurrentProtocol
            && pane.bracketedPasteActive
    }

    private static func readinessReasons(for panes: [TmuxPane]) -> [String] {
        var reasons: [String] = []
        if panes.contains(where: \.isDead) {
            reasons.append("pane has exited")
        }
        if panes.contains(where: { !$0.isStarted }) {
            reasons.append("pane is not started")
        }
        if panes.contains(where: { !$0.hasCurrentProtocol }) {
            reasons.append("protocol is stale")
        }
        if panes.contains(where: { !$0.relayEnabled }) {
            reasons.append("relay is unavailable")
        }
        if panes.contains(where: { !$0.bracketedPasteActive }) {
            reasons.append("bracketed paste is inactive")
        }
        return reasons.isEmpty ? ["pane readiness is unknown"] : reasons
    }

    private static func score(_ probe: VendorConformanceProbe) -> Int {
        (probe.testsInactiveTarget ? 2 : 0) + (probe.testsCrossWorkspace ? 1 : 0)
    }
}

public enum VendorConformanceOutcome: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case blocked
    case notExercised

    fileprivate var label: String {
        switch self {
        case .passed: "PASS"
        case .failed: "FAIL"
        case .blocked: "BLOCKED"
        case .notExercised: "SKIP"
        }
    }
}

public struct VendorConformanceResult: Codable, Equatable, Sendable {
    public let vendor: PaneKind
    public let check: String
    public let outcome: VendorConformanceOutcome
    public let detail: String

    public init(vendor: PaneKind, check: String, outcome: VendorConformanceOutcome, detail: String) {
        self.vendor = vendor
        self.check = check
        self.outcome = outcome
        self.detail = detail
    }
}

public struct VendorConformanceReport: Codable, Equatable, Sendable {
    public let results: [VendorConformanceResult]

    public init(results: [VendorConformanceResult]) {
        self.results = results
    }

    public var hasFailures: Bool { results.contains { $0.outcome == .failed } }
    public var hasBlockedChecks: Bool { results.contains { $0.outcome == .blocked } }
    public var isComplete: Bool { !hasFailures && !hasBlockedChecks }

    public func rendered() -> String {
        let rows = results.map {
            "\($0.outcome.label) \($0.vendor.label) — \($0.check): \($0.detail)"
        }
        let counts = Dictionary(grouping: results, by: \.outcome).mapValues(\.count)
        let summary = [
            "\(counts[.passed, default: 0]) passed",
            "\(counts[.failed, default: 0]) failed",
            "\(counts[.blocked, default: 0]) blocked",
            "\(counts[.notExercised, default: 0]) not exercised",
        ].joined(separator: ", ")
        return (rows + ["", summary]).joined(separator: "\n")
    }
}

public enum VendorConformanceAttentionKind: String, Codable, Equatable, Sendable {
    case trust
    case permission
}

public struct VendorConformanceAttentionReason: Codable, Equatable, Sendable {
    public let kind: VendorConformanceAttentionKind
    public let detail: String

    public init(kind: VendorConformanceAttentionKind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// Conservative recognition of a vendor TUI that is visibly waiting for the
/// person to decide trust or permission. Prompt wording alone is insufficient:
/// a decision affordance must also be visible, which avoids treating agent
/// prose, documentation and ordinary "permission denied" errors as controls.
public enum VendorPromptAttention {
    public static func detect(
        kind: PaneKind,
        visibleText: String
    ) -> VendorConformanceAttentionReason? {
        let visible = visibleText
            .split(whereSeparator: \.isNewline)
            .suffix(60)
            .joined(separator: "\n")
            .lowercased()

        let decisionPhrases = [
            "allow once",
            "yes, proceed",
            "no, and tell",
            "esc to cancel",
            "no, cancel",
            "1. yes",
            "2. no",
            "2. deny",
        ]
        let hasDecision = decisionPhrases.contains(where: visible.contains)

        let trustPhrases = [
            "confirm folder trust",
            "do you trust the files in this folder",
            "do you trust this folder",
            "trust this folder before",
            "trust the authors of the files in this folder",
        ]
        let trustMatches = trustPhrases.count { visible.contains($0) }
        if trustMatches >= 2 || (trustMatches == 1 && hasDecision) {
            return VendorConformanceAttentionReason(
                kind: .trust,
                detail: "\(kind.label) is visibly waiting for a folder-trust decision. Parley did not answer it."
            )
        }

        let permissionPhrases = [
            "would you like to run the following command",
            "do you want to proceed?",
            "would you like to proceed?",
            "allow this tool",
            "allow this command",
            "allow execution of:",
            "approval required",
            "permission required",
            "requires your approval",
        ]
        if hasDecision, permissionPhrases.contains(where: visible.contains) {
            return VendorConformanceAttentionReason(
                kind: .permission,
                detail: "\(kind.label) is visibly waiting for a permission decision. Parley did not answer it."
            )
        }
        return nil
    }
}

public enum VendorConformanceAttention {
    /// A live probe must never type through a prompt whose purpose is to ask
    /// the person for trust or tool authority. The phrases are deliberately
    /// conservative: a false positive skips a quota-spending test; a false
    /// negative can answer a question only the person should answer.
    public static func blockedReason(
        kind: PaneKind,
        visibleText: String
    ) -> VendorConformanceAttentionReason? {
        guard let detected = VendorPromptAttention.detect(kind: kind, visibleText: visibleText) else {
            return nil
        }
        let subject = detected.kind == .trust ? "folder trust" : "human permission"
        return VendorConformanceAttentionReason(
            kind: detected.kind,
            detail: "\(kind.label) is waiting for \(subject); no probe text was sent."
        )
    }
}
