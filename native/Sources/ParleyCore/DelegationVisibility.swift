import Foundation

/// Compact ages and durations for owned timestamps. Shared by delegation
/// visibility so every surface renders the same words for the same seconds.
public enum OwnedAge {
    public static func label(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        if whole < 10 { return "now" }
        if whole < 60 { return "\(whole)s ago" }
        if whole < 3_600 { return "\(whole / 60)m ago" }
        if whole < 86_400 { return "\(whole / 3_600)h ago" }
        return "\(whole / 86_400)d ago"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return "\(whole / 60)m" }
        if whole < 86_400 {
            let minutes = (whole % 3_600) / 60
            return minutes == 0 ? "\(whole / 3_600)h" : "\(whole / 3_600)h \(minutes)m"
        }
        return "\(whole / 86_400)d"
    }
}

/// Facts about one Delegate handoff derived only from timestamps Parley owns:
/// the recorded delivered transition, the moment the target replaced its one
/// agent-declared progress note, and the target pane's last authenticated
/// vendor hook report. Nothing here infers thinking, readiness, percent
/// complete, remaining time or failure. Silence is reported as the absence of
/// an explicit update, measured from the newest owned timestamp, and only
/// while the delegation is still active.
public struct DelegationVisibility: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case active
        case returned(RelayHandoffState)
    }

    public struct Progress: Equatable, Sendable {
        public let note: String
        public let reportedAt: Date
        public let age: TimeInterval
    }

    public struct TargetSignal: Equatable, Sendable {
        public let paneName: String
        public let vendor: PaneKind
        public let signal: VendorHookSignal
        public let reportedAt: Date
        public let age: TimeInterval

        public var signalLabel: String {
            signal.rawValue.replacingOccurrences(of: "-", with: " ")
        }
    }

    public struct Quiet: Equatable, Sendable {
        /// The newest owned timestamp: delivery, progress note or hook signal.
        public let since: Date
        public let duration: TimeInterval
    }

    public static let quietWindow: TimeInterval = 10 * 60
    public static let quietTitle = "No explicit update for 10 minutes"

    public let handoffID: String
    public let targetName: String
    public let phase: Phase
    public let deliveredAt: Date
    /// Active: seconds since delivery. Returned: seconds between delivery and
    /// the terminal transition.
    public let elapsed: TimeInterval
    public let endedAt: Date?
    public let progress: Progress?
    public let targetSignal: TargetSignal?
    public let quiet: Quiet?

    public var elapsedLabel: String {
        switch phase {
        case .active: "Delivered \(OwnedAge.label(elapsed))"
        case .returned(.completed): "Returned after \(OwnedAge.duration(elapsed))"
        case .returned: "Ended after \(OwnedAge.duration(elapsed))"
        }
    }

    /// Age only, for the inspector block that sits beside the full note.
    public var progressLabel: String {
        progress.map { "Progress note \(OwnedAge.label($0.age))" } ?? "No progress note reported"
    }

    /// The bounded note itself with its age and provenance, for compact rows
    /// that have no separate note section.
    public var progressSummary: String {
        progress.map { "Agent-declared \(OwnedAge.label($0.age)): \($0.note)" } ?? "No agent-declared progress note"
    }

    public var targetSignalLabel: String {
        guard let targetSignal else { return "No authenticated hook signal from \(targetName)" }
        return "\(targetSignal.vendor.label) hook · \(targetSignal.signalLabel) · \(OwnedAge.label(targetSignal.age))"
    }

    public var quietDetail: String? {
        quiet.map {
            "Quiet for \(OwnedAge.duration($0.duration)) since the last owned timestamp. Silence is not evidence of progress or of a problem."
        }
    }

    /// One line for compact rows. The quiet state leads so truncation never
    /// hides it; the agent-declared note comes last so a long note loses its
    /// tail rather than the owned facts. The hook signal is written without
    /// inner separators so the facts stay distinguishable.
    public var summary: String {
        let signal = targetSignal.map {
            "\($0.vendor.label) hook \($0.signalLabel) \(OwnedAge.label($0.age))"
        } ?? "No target hook signal"
        var parts: [String] = []
        if quiet != nil { parts.append(Self.quietTitle) }
        parts += [elapsedLabel, signal, progressSummary]
        return parts.joined(separator: " · ")
    }

    public var accessibilityDescription: String {
        var sentences = ["Delegation to \(targetName): \(elapsedLabel.lowercased())."]
        if let progress {
            sentences.append("Latest agent-declared progress note \(OwnedAge.label(progress.age)): \(progress.note)")
        } else {
            sentences.append("No agent-declared progress note has been reported.")
        }
        if let targetSignal {
            sentences.append("\(targetSignal.vendor.label) hook reported \(targetSignal.signalLabel) \(OwnedAge.label(targetSignal.age)).")
        } else {
            sentences.append("No authenticated hook signal from \(targetName).")
        }
        if let quietDetail {
            sentences.append("\(Self.quietTitle): \(quietDetail)")
        }
        sentences.append("Owned timestamps only; nothing is inferred from silence.")
        return sentences.joined(separator: " ")
    }
}

public enum DelegationVisibilityProjection {
    private static let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]

    /// Returns nil for anything that is not a Delegate or that has no recorded
    /// delivered transition. Creation, a progress note, or a failure before
    /// delivery never stand in for delivery, so a surface without that owned
    /// timestamp shows no delivery state at all.
    public static func facts(
        for handoff: RelayHandoff,
        target: WorkbenchPane?,
        now: Date
    ) -> DelegationVisibility? {
        guard handoff.kind == .delegate,
              let deliveredAt = handoff.transitions.first(where: { $0.state == .delivered })?.occurredAt else {
            return nil
        }

        let progress: DelegationVisibility.Progress? = {
            guard let note = handoff.progressNote, !note.isEmpty,
                  let reportedAt = handoff.progressUpdatedAt else { return nil }
            return DelegationVisibility.Progress(
                note: note,
                reportedAt: reportedAt,
                age: max(0, now.timeIntervalSince(reportedAt))
            )
        }()

        // The same gate the reviewed composer uses: a started, live pane whose
        // supported vendor hook reported through Parley's authenticated shim.
        let targetSignal: DelegationVisibility.TargetSignal? = {
            guard let target, target.id == handoff.targetPaneID,
                  let advisory = HandoffComposerSignalProjection.advisory(for: target) else { return nil }
            return DelegationVisibility.TargetSignal(
                paneName: advisory.paneName,
                vendor: advisory.vendor,
                signal: advisory.signal,
                reportedAt: advisory.reportedAt,
                age: max(0, now.timeIntervalSince(advisory.reportedAt))
            )
        }()

        if activeStates.contains(handoff.state) {
            let newestOwned = [deliveredAt, progress?.reportedAt, targetSignal?.reportedAt]
                .compactMap { $0 }
                .max() ?? deliveredAt
            let silence = now.timeIntervalSince(newestOwned)
            return DelegationVisibility(
                handoffID: handoff.id,
                targetName: handoff.targetName,
                phase: .active,
                deliveredAt: deliveredAt,
                elapsed: max(0, now.timeIntervalSince(deliveredAt)),
                endedAt: nil,
                progress: progress,
                targetSignal: targetSignal,
                quiet: silence >= DelegationVisibility.quietWindow
                    ? DelegationVisibility.Quiet(since: newestOwned, duration: silence)
                    : nil
            )
        }

        let endedAt = handoff.transitions.last(where: { $0.state == handoff.state })?.occurredAt ?? handoff.updatedAt
        return DelegationVisibility(
            handoffID: handoff.id,
            targetName: handoff.targetName,
            phase: .returned(handoff.state),
            deliveredAt: deliveredAt,
            elapsed: max(0, endedAt.timeIntervalSince(deliveredAt)),
            endedAt: endedAt,
            progress: progress,
            targetSignal: targetSignal,
            quiet: nil
        )
    }
}
