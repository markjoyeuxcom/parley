import Foundation

/// Content-free provenance for the latest supported official hook event from
/// the exact target pane shown in the reviewed handoff composer. This is a
/// display fact only; it never authorizes or refuses delivery.
public struct HandoffComposerSignalAdvisory: Equatable, Sendable {
    public let paneID: String
    public let paneName: String
    public let vendor: PaneKind
    public let state: VendorRuntimeState
    public let signal: VendorHookSignal
    public let reportedAt: Date

    public init(
        paneID: String,
        paneName: String,
        vendor: PaneKind,
        state: VendorRuntimeState,
        signal: VendorHookSignal,
        reportedAt: Date
    ) {
        self.paneID = paneID
        self.paneName = paneName
        self.vendor = vendor
        self.state = state
        self.signal = signal
        self.reportedAt = reportedAt
    }

    public var blocksDelivery: Bool { false }

    public var sourceLabel: String {
        "\(vendor.label.uppercased()) HOOK · \(paneName)"
    }

    public var stateLabel: String {
        switch state {
        case .ready: "READY REPORTED"
        case .working: "WORKING REPORTED"
        case .awaitingPermission: "PERMISSION REPORTED"
        case .exited: "EXIT REPORTED"
        case .unknown: "UNKNOWN REPORTED"
        }
    }

    public var signalLabel: String {
        signal.rawValue.replacingOccurrences(of: "-", with: " ").uppercased()
    }

    public func ageLabel(at now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(reportedAt)))
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    public func accessibilityDescription(at now: Date = Date()) -> String {
        "Authenticated signal from target pane \(paneName)'s \(vendor.label) hook capability: \(signal.rawValue), \(state.label.lowercased()) reported \(ageLabel(at: now)). Advisory only; it neither blocks nor authorizes delivery."
    }
}

public enum HandoffComposerSignalProjection {
    public static func advisory(for target: WorkbenchPane) -> HandoffComposerSignalAdvisory? {
        guard target.isStarted,
              !target.isDead,
              let projected = VendorRuntimeSignalProjection.signal(for: target),
              projected.source == .vendorOfficialHook,
              let reportedAt = projected.reportedAt,
              let signal = target.vendorRuntimeSignal,
              VendorHookAdapter.supportedSignals(for: target.kind).contains(signal) else {
            return nil
        }
        return HandoffComposerSignalAdvisory(
            paneID: target.id,
            paneName: target.displayName,
            vendor: target.kind,
            state: projected.state,
            signal: signal,
            reportedAt: reportedAt
        )
    }
}
