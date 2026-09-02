import Foundation

public enum VendorCompatibilityCapability: String, CaseIterable, Codable, Equatable, Sendable {
    case launch
    case submit
    case askAnswer
    case permissions

    public var label: String {
        switch self {
        case .launch: "Launch"
        case .submit: "Submit"
        case .askAnswer: "Ask/Answer"
        case .permissions: "Permissions"
        }
    }
}

public enum VendorCompatibilitySupport: String, Codable, Equatable, Sendable {
    case supported
    case partial
    case unavailable

    public var label: String {
        switch self {
        case .supported: "Supported"
        case .partial: "Partial"
        case .unavailable: "Unavailable"
        }
    }
}

public struct VendorCompatibilityCapabilityResult: Codable, Equatable, Sendable {
    public let capability: VendorCompatibilityCapability
    public let support: VendorCompatibilitySupport

    public init(capability: VendorCompatibilityCapability, support: VendorCompatibilitySupport) {
        self.capability = capability
        self.support = support
    }
}

public enum VendorCompatibilityState: String, Codable, Equatable, Sendable {
    case compatible
    case attention
    case unavailable

    public var label: String {
        switch self {
        case .compatible: "Compatible"
        case .attention: "Needs attention"
        case .unavailable: "Not installed"
        }
    }
}

public struct VendorCompatibilityResult: Codable, Equatable, Identifiable, Sendable {
    public let vendor: PaneKind
    public let installed: Bool
    public let version: String?
    public let state: VendorCompatibilityState
    public let detail: String
    public let versionChanged: Bool
    public let capabilities: [VendorCompatibilityCapabilityResult]

    public var id: PaneKind { vendor }

    public init(
        vendor: PaneKind,
        installed: Bool,
        version: String?,
        state: VendorCompatibilityState,
        detail: String,
        versionChanged: Bool,
        capabilities: [VendorCompatibilityCapabilityResult]
    ) {
        self.vendor = vendor
        self.installed = installed
        self.version = version
        self.state = state
        self.detail = detail
        self.versionChanged = versionChanged
        self.capabilities = capabilities
    }

    public func capability(_ capability: VendorCompatibilityCapability) -> VendorCompatibilityCapabilityResult? {
        capabilities.first { $0.capability == capability }
    }

    public func replacingVersion(_ version: String?) -> VendorCompatibilityResult {
        VendorCompatibilityResult(
            vendor: vendor,
            installed: installed,
            version: version,
            state: state,
            detail: detail,
            versionChanged: versionChanged,
            capabilities: capabilities
        )
    }
}

public enum VendorRuntimeState: String, Codable, Equatable, Sendable {
    case ready
    case working
    case awaitingPermission
    case exited
    case unknown

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .working: "Working"
        case .awaitingPermission: "Awaiting permission"
        case .exited: "Exited"
        case .unknown: "Unknown"
        }
    }
}

public enum VendorRuntimeSignalSource: String, Codable, Equatable, Sendable {
    case vendorOfficialHook
    case parleyProcess
    case unavailable
}

public struct VendorRuntimeSignal: Codable, Equatable, Identifiable, Sendable {
    public let paneID: String
    public let vendor: PaneKind
    public let state: VendorRuntimeState
    public let source: VendorRuntimeSignalSource
    public let reportedAt: Date?
    public let detail: String

    public var id: String { paneID }

    public init(
        paneID: String,
        vendor: PaneKind,
        state: VendorRuntimeState,
        source: VendorRuntimeSignalSource,
        reportedAt: Date? = nil,
        detail: String
    ) {
        self.paneID = paneID
        self.vendor = vendor
        self.state = state
        self.source = source
        self.reportedAt = reportedAt
        self.detail = detail
    }
}

/// A pane's terminal title, current command, visible text, silence and timing
/// never enter this projection. Only a supported structured per-session hook
/// may move a running pane out of Unknown. Parley can state an exit because it
/// owns the process lifecycle, not because it inferred meaning from the TUI.
public enum VendorRuntimeSignalProjection {
    public static func signal(for pane: WorkbenchPane) -> VendorRuntimeSignal? {
        guard pane.kind.isAgent else { return nil }
        if pane.isDead {
            return VendorRuntimeSignal(
                paneID: pane.id,
                vendor: pane.kind,
                state: .exited,
                source: .parleyProcess,
                detail: pane.exitStatus.map { "Parley observed process exit status \($0)." }
                    ?? "Parley observed the vendor process exit."
            )
        }
        if !pane.isStarted {
            return VendorRuntimeSignal(
                paneID: pane.id,
                vendor: pane.kind,
                state: .unknown,
                source: .unavailable,
                detail: "The pane is stopped; no vendor runtime exists to inspect."
            )
        }
        if let state = pane.vendorRuntimeState,
           let signal = pane.vendorRuntimeSignal,
           let reportedAt = pane.vendorRuntimeSignaledAt,
           VendorHookAdapter.supportedSignals(for: pane.kind).contains(signal) {
            return VendorRuntimeSignal(
                paneID: pane.id,
                vendor: pane.kind,
                state: state,
                source: .vendorOfficialHook,
                reportedAt: reportedAt,
                detail: "Reported through this pane's \(pane.kind.label) hook capability: \(signal.rawValue)."
            )
        }
        return VendorRuntimeSignal(
            paneID: pane.id,
            vendor: pane.kind,
            state: .unknown,
            source: .unavailable,
            detail: "No supported official hook has reported runtime state for this pane. Terminal text and timing are not evidence."
        )
    }
}

public struct VendorCompatibilitySnapshot: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let vendors: [VendorCompatibilityResult]
    public let runtimeSignals: [VendorRuntimeSignal]

    public init(
        checkedAt: Date = Date(),
        vendors: [VendorCompatibilityResult],
        runtimeSignals: [VendorRuntimeSignal]
    ) {
        self.checkedAt = checkedAt
        self.vendors = vendors
        self.runtimeSignals = runtimeSignals
    }

    public func result(for vendor: PaneKind) -> VendorCompatibilityResult? {
        vendors.first { $0.vendor == vendor }
    }
}

/// Runs exactly one version-only command for each installed vendor. It does
/// not open a session, submit a prompt, inspect configuration or spend quota.
public final class VendorCompatibilityChecker: @unchecked Sendable {
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        runner: any CommandRunning = ProcessCommandRunner(timeout: 8),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func check(
        environment: [String: String],
        readiness: RuntimeReadinessSnapshot?,
        panes: [WorkbenchPane],
        previous: VendorCompatibilitySnapshot?,
        checkedAt: Date = Date()
    ) -> VendorCompatibilitySnapshot {
        let vendors = PaneKind.allCases.filter(\.isAgent).map { vendor in
            result(
                for: vendor,
                environment: environment,
                readiness: readiness,
                previous: previous?.result(for: vendor)
            )
        }
        return VendorCompatibilitySnapshot(
            checkedAt: checkedAt,
            vendors: vendors,
            runtimeSignals: panes.compactMap(VendorRuntimeSignalProjection.signal)
        )
    }

    private func result(
        for vendor: PaneKind,
        environment: [String: String],
        readiness: RuntimeReadinessSnapshot?,
        previous: VendorCompatibilityResult?
    ) -> VendorCompatibilityResult {
        guard let executable = executable(named: vendor.rawValue, environment: environment) else {
            return VendorCompatibilityResult(
                vendor: vendor,
                installed: false,
                version: nil,
                state: .unavailable,
                detail: "The CLI is not installed on Parley's resolved login PATH.",
                versionChanged: false,
                capabilities: capabilityResults(installed: false)
            )
        }

        let output = try? runner.run(
            executable: executable,
            arguments: ["--version"],
            environment: Self.probeEnvironment(from: environment),
            input: Data()
        )
        let combined = [output?.stdoutText, output?.stderrText]
            .compactMap { $0 }
            .joined(separator: "\n")
        let version = Self.semanticVersion(in: combined)
        let succeeded = output?.status == 0 && version != nil
        let probeFailure: String = if output == nil {
            "The CLI was found, but Parley could not launch its version-only probe."
        } else if output?.status == 124 {
            "The CLI was found, but its bounded version-only probe timed out."
        } else if let status = output?.status, status != 0 {
            "The CLI was found, but its version-only probe exited with status \(status)."
        } else {
            "The CLI was found, but its version-only probe did not return a semantic version."
        }
        let readinessState = RuntimeReadinessID(rawValue: vendor.rawValue)
            .flatMap { readiness?.item($0)?.state }
        let readinessSuffix = switch readinessState {
        case .ready?: " Authentication was confirmed by the vendor's status-only command."
        case .attention?: " Authentication needs attention according to the vendor's status-only command."
        case .unchecked?: " Authentication is Unknown because this vendor exposes no safe status-only check."
        case .unavailable?, nil: " Authentication was not established by this compatibility check."
        }
        return VendorCompatibilityResult(
            vendor: vendor,
            installed: true,
            version: version,
            state: succeeded ? .compatible : .attention,
            detail: succeeded
                ? "The version-only probe succeeded; adapter contracts are available.\(readinessSuffix)"
                : probeFailure,
            versionChanged: version != nil && previous?.version != nil && version != previous?.version,
            capabilities: capabilityResults(installed: succeeded)
        )
    }

    private func capabilityResults(installed: Bool) -> [VendorCompatibilityCapabilityResult] {
        VendorCompatibilityCapability.allCases.map { capability in
            VendorCompatibilityCapabilityResult(
                capability: capability,
                support: installed
                    ? (capability == .permissions ? .partial : .supported)
                    : .unavailable
            )
        }
    }

    private func executable(named name: String, environment: [String: String]) -> URL? {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        let conventionalCandidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        var seen = Set<String>()
        return (pathCandidates + conventionalCandidates).first { candidate in
            seen.insert(candidate.standardizedFileURL.path).inserted
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    public static func semanticVersion(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        let expression = try? NSRegularExpression(
            pattern: #"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)"#
        )
        guard let match = expression?.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

    private static func probeEnvironment(from environment: [String: String]) -> [String: String] {
        let allowed = Set([
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
        ])
        var probe = environment.filter { allowed.contains($0.key) }
        probe["TERM"] = "dumb"
        probe["NO_COLOR"] = "1"
        probe["CI"] = "1"
        return probe
    }
}
