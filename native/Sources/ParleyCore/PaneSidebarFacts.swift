import Foundation

public struct PaneListeningPortSnapshot: Equatable, Sendable {
    public let sampledAt: Date
    public let portsByPaneID: [String: [UInt16]]

    public init(sampledAt: Date, portsByPaneID: [String: [UInt16]]) {
        self.sampledAt = sampledAt
        self.portsByPaneID = portsByPaneID
    }

    public static let empty = PaneListeningPortSnapshot(
        sampledAt: .distantPast,
        portsByPaneID: [:]
    )
}

/// Parses only lsof's machine-oriented PID and network-name fields, then joins
/// them to process ids Parley has already attributed to one retained pane.
public enum PaneListeningPortProjection {
    public static let maximumInspectedProcesses = 256
    public static let maximumPortsPerPane = 8

    /// The bounded, deduplicated process ids handed to lsof, newest process
    /// first so a freshly started server is never the one the bound drops.
    public static func inspectedProcessIDs(
        ownedProcesses: [String: [TaskManagerRawProcess]]
    ) -> [Int32] {
        var newestByPID: [Int32: TaskManagerRawProcess] = [:]
        for process in ownedProcesses.values.joined() where process.pid > 0 {
            if let existing = newestByPID[process.pid], existing.startedAt >= process.startedAt { continue }
            newestByPID[process.pid] = process
        }
        return Array(
            newestByPID.values
                .sorted {
                    if $0.startedAt == $1.startedAt { return $0.pid > $1.pid }
                    return $0.startedAt > $1.startedAt
                }
                .prefix(maximumInspectedProcesses)
                .map(\.pid)
        )
    }

    public static func commandArguments(
        ownedProcesses: [String: [TaskManagerRawProcess]]
    ) -> [String]? {
        let bounded = inspectedProcessIDs(ownedProcesses: ownedProcesses)
        guard !bounded.isEmpty else { return nil }
        return [
            "-nP",
            "-a",
            "-p", bounded.map(String.init).joined(separator: ","),
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fpn",
        ]
    }

    public static func snapshot(
        ownedProcesses: [String: [TaskManagerRawProcess]],
        lsofOutput: String,
        sampledAt: Date
    ) -> PaneListeningPortSnapshot {
        let allowedProcesses = Set(inspectedProcessIDs(ownedProcesses: ownedProcesses))
        let processPorts = parseProcessPorts(lsofOutput)
        var portsByPaneID: [String: [UInt16]] = [:]
        for (paneID, processes) in ownedProcesses {
            var ports: Set<UInt16> = []
            for process in processes where allowedProcesses.contains(process.pid) {
                ports.formUnion(processPorts[process.pid] ?? [])
            }
            portsByPaneID[paneID] = Array(ports.sorted().prefix(maximumPortsPerPane))
        }
        return PaneListeningPortSnapshot(
            sampledAt: sampledAt,
            portsByPaneID: portsByPaneID
        )
    }

    /// True when lsof's machine output names at least one process (`p<pid>`),
    /// which is the only shape a successful `-Fpn` listing can take.
    public static func containsProcessRecord(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            guard line.first == "p" else { return false }
            let digits = line.dropFirst()
            return !digits.isEmpty && digits.allSatisfy(\.isNumber)
        }
    }

    private static func parseProcessPorts(_ output: String) -> [Int32: Set<UInt16>] {
        var currentProcessID: Int32?
        var portsByProcessID: [Int32: Set<UInt16>] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            switch field {
            case "p":
                let processID = Int32(line.dropFirst())
                currentProcessID = processID.flatMap { $0 > 0 ? $0 : nil }
            case "n":
                guard let currentProcessID,
                      let separator = line.lastIndex(of: ":") else { continue }
                let suffix = line[line.index(after: separator)...]
                let digits = suffix.prefix { $0.isNumber }
                guard !digits.isEmpty,
                      let port = UInt16(digits),
                      port > 0 else { continue }
                portsByProcessID[currentProcessID, default: []].insert(port)
            default:
                continue
            }
        }
        return portsByProcessID
    }
}

public enum PaneListeningPortRefreshPolicy {
    public static let interval: TimeInterval = 10

    public static func shouldRefresh(
        lastSampledAt: Date,
        now: Date,
        inputsChanged: Bool,
        isRefreshing: Bool
    ) -> Bool {
        guard !isRefreshing else { return false }
        return inputsChanged || now.timeIntervalSince(lastSampledAt) >= interval
    }
}

/// Throttle and retention state for listener sampling. Attempts are throttled
/// by when inspection last ran; the published snapshot changes only when an
/// inspection actually produced one.
public struct PaneListeningPortRefreshState: Equatable, Sendable {
    public private(set) var snapshot = PaneListeningPortSnapshot.empty
    public private(set) var lastAttemptAt = Date.distantPast
    public private(set) var inputSignature: [String] = []
    public private(set) var isRefreshing = false

    public init() {}

    public func shouldAttempt(now: Date, inputSignature: [String], forced: Bool) -> Bool {
        PaneListeningPortRefreshPolicy.shouldRefresh(
            lastSampledAt: lastAttemptAt,
            now: now,
            inputsChanged: forced || inputSignature != self.inputSignature,
            isRefreshing: isRefreshing
        )
    }

    public mutating func beginAttempt(at now: Date, inputSignature: [String]) {
        lastAttemptAt = now
        self.inputSignature = inputSignature
        isRefreshing = true
    }

    /// A nil result means inspection itself failed; the previous snapshot and
    /// its freshness stay exactly as they were, while the attempt still counts
    /// for throttling so a broken lsof is not retried in a hot loop.
    public mutating func finishAttempt(with sampled: PaneListeningPortSnapshot?) {
        isRefreshing = false
        guard let sampled else { return }
        snapshot = sampled
    }

    public mutating func publish(_ produced: PaneListeningPortSnapshot) {
        isRefreshing = false
        snapshot = produced
    }
}

/// Bounded live inspection of only process trees already owned by Parley's
/// Ghostty panes. No shell is involved and no terminal bytes are read.
public struct PaneListeningPortResolver: Sendable {
    private let executable: URL
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let anchorResolver: PaneProcessAnchorResolver

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 2,
        anchorResolver: PaneProcessAnchorResolver = PaneProcessAnchorResolver()
    ) {
        self.executable = executable
        var resolvedEnvironment = environment
        resolvedEnvironment["LC_ALL"] = "C"
        self.environment = resolvedEnvironment
        self.timeout = max(0.1, timeout)
        self.anchorResolver = anchorResolver
    }

    /// Returns nil when inspection itself failed (lsof could not start or timed
    /// out), so the caller keeps its previous snapshot.
    public func sample(
        applicationPID: Int32,
        paneDescriptors: [TaskManagerPaneDescriptor],
        sampledAt: Date = Date()
    ) -> PaneListeningPortSnapshot? {
        let rawProcesses = TaskManagerProcessReader.readAll()
        let descriptors = anchorResolver.anchored(
            paneDescriptors,
            applicationPID: applicationPID,
            rawProcesses: rawProcesses
        )
        let ownedProcesses = TaskManagerProjection.ownedProcesses(
            applicationPID: applicationPID,
            paneDescriptors: descriptors,
            rawProcesses: rawProcesses
        )
        guard let arguments = PaneListeningPortProjection.commandArguments(
            ownedProcesses: ownedProcesses
        ) else {
            return PaneListeningPortProjection.snapshot(
                ownedProcesses: ownedProcesses,
                lsofOutput: "",
                sampledAt: sampledAt
            )
        }
        guard let output = try? ProcessCommandRunner(timeout: timeout).run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: nil
        ) else { return nil }
        // lsof exits 1 when any listed pid vanished between the process scan
        // and its own lookup while still printing every listener it found, but
        // it also exits 1 for permission and general failures that print no
        // machine output. Status 1 is therefore usable only when stdout carries
        // at least one process record; everything else is a failed inspection
        // that must not replace a valid earlier snapshot.
        let stdout = output.stdoutText
        switch output.status {
        case 0:
            break
        case 1:
            guard PaneListeningPortProjection.containsProcessRecord(stdout) else { return nil }
        default:
            return nil
        }
        return PaneListeningPortProjection.snapshot(
            ownedProcesses: ownedProcesses,
            lsofOutput: stdout,
            sampledAt: sampledAt
        )
    }
}

public struct PaneSidebarFacts: Equatable, Sendable {
    public let paneID: String
    public let workingDirectory: String
    public let gitContext: GitProjectContext?
    public let listeningPorts: [UInt16]
    public let listeningPortsSampledAt: Date?
    public let latestAttention: PaneAttentionItem?
}

public enum PaneSidebarFactsProjection {
    public static func facts(
        for pane: WorkbenchPane,
        projectContext: GitProjectContext?,
        listeningPortSnapshot: PaneListeningPortSnapshot,
        attentionItems: [PaneAttentionItem]
    ) -> PaneSidebarFacts {
        let latestAttention = attentionItems
            .filter { $0.paneID == pane.id }
            .sorted {
                if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
                return $0.occurredAt > $1.occurredAt
            }
            .first
        return PaneSidebarFacts(
            paneID: pane.id,
            workingDirectory: pane.cwd,
            gitContext: projectContext,
            listeningPorts: listeningPortSnapshot.portsByPaneID[pane.id] ?? [],
            listeningPortsSampledAt: listeningPortSnapshot.sampledAt == .distantPast
                ? nil
                : listeningPortSnapshot.sampledAt,
            latestAttention: latestAttention
        )
    }
}
