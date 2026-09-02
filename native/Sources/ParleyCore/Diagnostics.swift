import Darwin
import Foundation

public struct DiagnosticsApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let runtime: String

    public init(bundleIdentifier: String, version: String, build: String, runtime: String = "unknown") {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.runtime = runtime
    }
}

public struct DiagnosticsSystem: Codable, Equatable, Sendable {
    public let operatingSystem: String
    public let architecture: String
}

public struct DiagnosticsMemory: Codable, Equatable, Sendable {
    public let uiResidentBytes: UInt64?
    public let coreResidentBytes: UInt64?
}

public struct DiagnosticsCounts: Codable, Equatable, Sendable {
    public let workspaces: Int
    public let panes: Int
    public let runningAgents: Int
    public let stoppedAgents: Int
    public let activeHandoffs: Int
    public let outstandingQuestions: Int
    public let trackedDelegations: Int
    public let failures: Int
    public let unreadResults: Int
}

public struct DiagnosticsHealth: Codable, Equatable, Sendable {
    public let terminalAvailable: Bool
    public let coreAvailable: Bool
    public let condition: String
    public let counts: DiagnosticsCounts
}

public struct DiagnosticsCoordinationUsage: Codable, Equatable, Sendable {
    public let relayHandoffs: Int
    public let pasteHandoffs: Int
    public let askHandoffs: Int
    public let delegateHandoffs: Int
    public let challengeHandoffs: Int
    public let verifyHandoffs: Int
    public let reviewedResults: Int
    public let vendorSignals: Int
}

public struct DiagnosticsDeliveryQuality: Codable, Equatable, Sendable {
    public let totalHandoffs: Int
    public let submittedHandoffs: Int
    public let deliveredHandoffs: Int
    public let completedHandoffs: Int
    public let returnedResults: Int
    public let preDeliveryFailures: Int
    public let uncertainDeliveryFailures: Int
    public let interruptedHandoffs: Int
    public let cancelledHandoffs: Int
    public let medianTerminalDurationMilliseconds: Int64?
}

/// Counts and timestamps describe the retained content-free source window.
/// They do not claim that a particular external consumer received every event.
public struct DiagnosticsEventReplayWindow: Codable, Equatable, Sendable {
    public let retainedHandoffTransitions: Int
    public let retainedActivityEvents: Int
    public let retainedVendorSignals: Int
    public let oldestEventAt: Date?
    public let newestEventAt: Date?
}

/// Recovery is measured only when a failed or interrupted target later emits
/// an authoritative pane-restarted or vendor-session-started event.
public struct DiagnosticsRecoveryQuality: Codable, Equatable, Sendable {
    public let authoritativeSamples: Int
    public let medianMilliseconds: Int64?
    public let maximumMilliseconds: Int64?
}

public struct DiagnosticsCoordination: Codable, Equatable, Sendable {
    public let usage: DiagnosticsCoordinationUsage
    public let delivery: DiagnosticsDeliveryQuality
    public let eventReplay: DiagnosticsEventReplayWindow
    public let recovery: DiagnosticsRecoveryQuality
}
/// A process-state projection which deliberately excludes every string drawn
/// from terminal content or human naming: no cwd, command, title, pane name,
/// workspace name, return route, or terminal buffer content is represented.
public struct DiagnosticsPane: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let workspaceID: String
    public let isActive: Bool
    public let isStarted: Bool
    public let isDead: Bool
    public let exitStatus: Int?
    public let relayEnabled: Bool
    public let protocolVersion: String?
    public let protocolCurrent: Bool
    public let inputAvailable: Bool
}

public struct DiagnosticsTransition: Codable, Equatable, Sendable {
    public let state: String
    public let occurredAt: Date
    public let origin: String?
}

/// Only typed operational facts survive this projection. Handoff text,
/// returned results, pane/workspace names and transition detail never enter it.
public struct DiagnosticsFailure: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let state: String
    public let sourcePaneID: String
    public let targetPaneID: String
    public let submitted: Bool
    public let updatedAt: Date
    public let retryDisposition: String?
    public let attention: String?
    public let transitions: [DiagnosticsTransition]
}

public struct DiagnosticsReadinessItem: Codable, Equatable, Sendable {
    public let id: String
    public let category: String
    public let state: String
    public let required: Bool
}

public struct DiagnosticsReadiness: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let items: [DiagnosticsReadinessItem]
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let application: DiagnosticsApplication
    public let system: DiagnosticsSystem
    public let memory: DiagnosticsMemory
    public let health: DiagnosticsHealth
    public let coordination: DiagnosticsCoordination
    public let panes: [DiagnosticsPane]
    public let failures: [DiagnosticsFailure]
    public let readiness: DiagnosticsReadiness?
}

public enum DiagnosticsReportBuilder {
    public static let schemaVersion = 3
    public static let maximumTransitionsPerFailure = 20

    public static func build(
        generatedAt: Date = Date(),
        application: DiagnosticsApplication,
        operatingSystem: String,
        architecture: String,
        uiResidentBytes: UInt64?,
        coreResidentBytes: UInt64?,
        terminalAvailable: Bool,
        coreAvailable: Bool,
        workspaceCount: Int,
        panes: [WorkbenchPane],
        handoffs: [RelayHandoff],
        activityEvents: [RelayActivityEvent] = [],
        readiness: RuntimeReadinessSnapshot?,
        maximumFailures: Int = 50
    ) -> DiagnosticsReport {
        let status = StatusCenterProjection.snapshot(
            panes: panes,
            handoffs: handoffs,
            workspaceID: nil,
            coreAvailable: coreAvailable
        )
        let safePanes = panes
            .map { pane in
                DiagnosticsPane(
                    id: pane.id,
                    kind: pane.kind.rawValue,
                    workspaceID: pane.workspaceID,
                    isActive: pane.isActive,
                    isStarted: pane.isStarted,
                    isDead: pane.isDead,
                    exitStatus: pane.exitStatus,
                    relayEnabled: pane.relayEnabled,
                    protocolVersion: pane.protocolVersion,
                    protocolCurrent: pane.hasCurrentProtocol,
                    inputAvailable: pane.inputAvailable
                )
            }
            .sorted { $0.id < $1.id }
        let safeFailures = handoffs
            .filter { $0.state == .failed || $0.state == .interrupted }
            .sorted { left, right in
                if left.updatedAt == right.updatedAt { return left.id < right.id }
                return left.updatedAt > right.updatedAt
            }
            .prefix(max(0, maximumFailures))
            .map { handoff in
                DiagnosticsFailure(
                    id: handoff.id,
                    kind: handoff.kind.rawValue,
                    state: handoff.state.rawValue,
                    sourcePaneID: handoff.sourcePaneID,
                    targetPaneID: handoff.targetPaneID,
                    submitted: handoff.submitted,
                    updatedAt: handoff.updatedAt,
                    retryDisposition: handoff.retryDisposition?.rawValue,
                    attention: handoff.attention?.rawValue,
                    transitions: handoff.transitions.suffix(maximumTransitionsPerFailure).map { transition in
                        DiagnosticsTransition(
                            state: transition.state.rawValue,
                            occurredAt: transition.occurredAt,
                            origin: transition.origin?.rawValue
                        )
                    }
                )
            }
        let safeReadiness = readiness.map { snapshot in
            DiagnosticsReadiness(
                checkedAt: snapshot.checkedAt,
                items: snapshot.items.map { item in
                    DiagnosticsReadinessItem(
                        id: item.id.rawValue,
                        category: item.category.rawValue,
                        state: item.state.rawValue,
                        required: item.required
                    )
                }
            )
        }
        let vendorSignalCount = activityEvents.reduce(into: 0) { count, event in
            if VendorHookSignal(activityKind: event.kind) != nil { count += 1 }
        }
        let terminalDurations = handoffs.compactMap { handoff -> Int64? in
            guard isTerminal(handoff.state),
                  let first = handoff.transitions.map(\.occurredAt).min(),
                  let last = handoff.transitions
                    .filter({ isTerminal($0.state) })
                    .map(\.occurredAt)
                    .max() else { return nil }
            return milliseconds(last.timeIntervalSince(first))
        }
        var eventDates = handoffs.flatMap { $0.transitions.map(\.occurredAt) }
        eventDates.append(contentsOf: activityEvents.map(\.occurredAt))
        let recoveryDurations = handoffs
            .filter { $0.state == .failed || $0.state == .interrupted }
            .compactMap { handoff -> Int64? in
                let recoveryEvents = activityEvents.filter { event in
                    event.paneID == handoff.targetPaneID
                        && event.occurredAt >= handoff.updatedAt
                        && (
                            event.kind == .paneRestarted
                                || event.kind == .vendorSessionStarted
                        )
                }
                guard let recoveredAt = recoveryEvents.map(\.occurredAt).min() else { return nil }
                return milliseconds(recoveredAt.timeIntervalSince(handoff.updatedAt))
            }
        let coordination = DiagnosticsCoordination(
            usage: DiagnosticsCoordinationUsage(
                relayHandoffs: handoffs.count(where: { $0.kind == .relay }),
                pasteHandoffs: handoffs.count(where: { $0.kind == .paste }),
                askHandoffs: handoffs.count(where: { $0.kind == .ask }),
                delegateHandoffs: handoffs.count(where: { $0.kind == .delegate }),
                challengeHandoffs: handoffs.count(where: { $0.relationship == .challenge }),
                verifyHandoffs: handoffs.count(where: { $0.relationship == .verify }),
                reviewedResults: handoffs.count(where: { $0.reviewedAt != nil }),
                vendorSignals: vendorSignalCount
            ),
            delivery: DiagnosticsDeliveryQuality(
                totalHandoffs: handoffs.count,
                submittedHandoffs: handoffs.count(where: \.submitted),
                deliveredHandoffs: handoffs.count(where: {
                    $0.transitions.contains(where: { $0.state == .delivered })
                }),
                completedHandoffs: handoffs.count(where: { $0.state == .completed }),
                returnedResults: handoffs.count(where: \.hasReturnedResult),
                preDeliveryFailures: handoffs.count(where: {
                    $0.state == .failed && $0.retryDisposition == .safe
                }),
                uncertainDeliveryFailures: handoffs.count(where: {
                    $0.state == .failed && $0.retryDisposition == .uncertain
                }),
                interruptedHandoffs: handoffs.count(where: { $0.state == .interrupted }),
                cancelledHandoffs: handoffs.count(where: { $0.state == .cancelled }),
                medianTerminalDurationMilliseconds: median(terminalDurations)
            ),
            eventReplay: DiagnosticsEventReplayWindow(
                retainedHandoffTransitions: handoffs.reduce(0) { $0 + $1.transitions.count },
                retainedActivityEvents: activityEvents.count,
                retainedVendorSignals: vendorSignalCount,
                oldestEventAt: eventDates.min(),
                newestEventAt: eventDates.max()
            ),
            recovery: DiagnosticsRecoveryQuality(
                authoritativeSamples: recoveryDurations.count,
                medianMilliseconds: median(recoveryDurations),
                maximumMilliseconds: recoveryDurations.max()
            )
        )

        return DiagnosticsReport(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            application: application,
            system: DiagnosticsSystem(
                operatingSystem: operatingSystem,
                architecture: architecture
            ),
            memory: DiagnosticsMemory(
                uiResidentBytes: uiResidentBytes,
                coreResidentBytes: coreResidentBytes
            ),
            health: DiagnosticsHealth(
                terminalAvailable: terminalAvailable,
                coreAvailable: coreAvailable,
                condition: status.condition.rawValue,
                counts: DiagnosticsCounts(
                    workspaces: max(0, workspaceCount),
                    panes: safePanes.count,
                    runningAgents: status.counts.runningAgents,
                    stoppedAgents: status.counts.stoppedAgents,
                    activeHandoffs: status.activeHandoffs.count,
                    outstandingQuestions: status.counts.outstandingQuestions,
                    trackedDelegations: status.counts.trackedDelegations,
                    failures: status.counts.failures,
                    unreadResults: status.counts.unreadResults
                )
            ),
            coordination: coordination,
            panes: safePanes,
            failures: safeFailures,
            readiness: safeReadiness
        )
    }

    private static func isTerminal(_ state: RelayHandoffState) -> Bool {
        switch state {
        case .completed, .cancelled, .failed, .interrupted:
            true
        case .created, .delivered, .waiting, .answered:
            false
        }
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int64? {
        guard interval.isFinite, interval >= 0 else { return nil }
        let value = interval * 1_000
        guard value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded())
    }

    private static func median(_ values: [Int64]) -> Int64? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let midpoint = ordered.count / 2
        guard ordered.count.isMultiple(of: 2) else { return ordered[midpoint] }
        let lower = ordered[midpoint - 1]
        return lower + ((ordered[midpoint] - lower) / 2)
    }
}

public enum DiagnosticsReportEncoder {
    public static func encode(_ report: DiagnosticsReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

public enum DiagnosticsArchiveError: LocalizedError, Equatable {
    case invalidDestination
    case archiveFailed(String)
    case archiveMissing

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "Diagnostics must be saved to a local ZIP file."
        case let .archiveFailed(detail):
            "Parley could not create the diagnostics ZIP. \(detail)"
        case .archiveMissing:
            "The diagnostics archiver finished without creating a ZIP."
        }
    }
}

public final class DiagnosticsArchiveWriter: @unchecked Sendable {
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        runner: any CommandRunning = ProcessCommandRunner(timeout: 30),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func write(report: DiagnosticsReport, to destination: URL) throws {
        guard destination.isFileURL,
              destination.pathExtension.caseInsensitiveCompare("zip") == .orderedSame,
              !destination.lastPathComponent.isEmpty else {
            throw DiagnosticsArchiveError.invalidDestination
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("parley-diagnostics-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let bundle = temporaryRoot.appendingPathComponent("Parley Diagnostics", isDirectory: true)
        try fileManager.createDirectory(
            at: bundle,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let reportFile = bundle.appendingPathComponent("diagnostics.json")
        try DiagnosticsReportEncoder.encode(report).write(to: reportFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportFile.path)
        let readmeFile = bundle.appendingPathComponent("README.txt")
        try Data(Self.readme.utf8).write(to: readmeFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readmeFile.path)

        let temporaryArchive = temporaryRoot.appendingPathComponent("Parley-Diagnostics.zip")
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", bundle.path, temporaryArchive.path],
            environment: ProcessInfo.processInfo.environment,
            input: nil
        )
        guard output.status == 0 else {
            let detail = (output.stderrText + "\n" + output.stdoutText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiagnosticsArchiveError.archiveFailed(detail.isEmpty ? "ditto exited with status \(output.status)." : detail)
        }
        guard fileManager.fileExists(atPath: temporaryArchive.path) else {
            throw DiagnosticsArchiveError.archiveMissing
        }

        let destinationDirectory = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw DiagnosticsArchiveError.invalidDestination
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryArchive)
        } else {
            try fileManager.moveItem(at: temporaryArchive, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public static let readme = """
    Parley local diagnostics

    This archive contains machine-readable local health and process-state facts.
    It is designed for troubleshooting and never leaves this Mac unless you share it.

    Excluded by design:
    - prompts, questions, delegated instructions, answers, and result bodies
    - terminal contents, selections, titles, current commands, and working folders
    - pane and workspace display names
    - relay credentials, control tokens, socket paths, raw journals, and raw logs
    - vendor authentication data and subscription details

    Pane and handoff identifiers are ephemeral local correlation values. Recent
    failures contain only typed states, timestamps, and structured recovery flags.
    Coordination usage, delivery, replay-window, and recovery sections contain
    aggregate counts and timings only, never event bodies. The report keeps at
    most 50 recent failures and 20 transitions per failure.
    """
}

public enum DiagnosticsProcessMemory {
    public static func residentBytes(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.stride)
        let received = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, expected)
        }
        guard received == expected else { return nil }
        return info.pti_resident_size
    }
}
