import Darwin
import Foundation

public struct TaskManagerProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

public struct TaskManagerRawProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let ttyDevice: UInt64?
    public let name: String
    public let residentBytes: UInt64
    public let totalCPUTimeNanoseconds: UInt64
    public let startedAt: Date

    public init(
        pid: Int32,
        parentPID: Int32,
        processGroupID: Int32,
        ttyDevice: UInt64?,
        name: String,
        residentBytes: UInt64,
        totalCPUTimeNanoseconds: UInt64,
        startedAt: Date
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.ttyDevice = ttyDevice
        self.name = name
        self.residentBytes = residentBytes
        self.totalCPUTimeNanoseconds = totalCPUTimeNanoseconds
        self.startedAt = startedAt
    }

    public var identity: TaskManagerProcessIdentity {
        TaskManagerProcessIdentity(pid: pid, startedAt: startedAt)
    }
}

public struct TaskManagerPaneDescriptor: Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let workspaceName: String
    public let paneName: String
    public let kind: PaneKind
    public let workingDirectory: String
    public let isSelected: Bool
    public let isStarted: Bool
    public let foregroundPID: Int32?
    public let ttyName: String?
    public let ttyDevice: UInt64?
    public let anchorSource: PaneProcessAnchorSource

    public init(
        paneID: String,
        workspaceID: String,
        workspaceName: String,
        paneName: String,
        kind: PaneKind,
        workingDirectory: String,
        isSelected: Bool,
        isStarted: Bool,
        foregroundPID: Int32?,
        ttyName: String?,
        ttyDevice: UInt64?,
        anchorSource: PaneProcessAnchorSource? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.paneName = paneName
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.isSelected = isSelected
        self.isStarted = isStarted
        self.foregroundPID = foregroundPID
        self.ttyName = ttyName
        self.ttyDevice = ttyDevice
        self.anchorSource = anchorSource
            ?? ((foregroundPID != nil || ttyDevice != nil) ? .ghostty : .unavailable)
    }
}

public struct TaskManagerProcessSample: Equatable, Identifiable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let name: String
    public let residentBytes: UInt64
    public let cpuPercent: Double?
    public let startedAt: Date
    public let depth: Int

    public var id: TaskManagerProcessIdentity {
        TaskManagerProcessIdentity(pid: pid, startedAt: startedAt)
    }
}

public struct TaskManagerApplicationSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let residentBytes: UInt64
    public let cpuPercent: Double?
}

public struct TaskManagerPaneSnapshot: Equatable, Identifiable, Sendable {
    public let paneID: String
    public let workspaceID: String
    public let paneName: String
    public let kind: PaneKind
    public let workingDirectory: String
    public let isSelected: Bool
    public let isStarted: Bool
    public let ttyName: String?
    public let foregroundPID: Int32?
    public let anchorSource: PaneProcessAnchorSource
    public let processes: [TaskManagerProcessSample]
    public let residentBytes: UInt64
    public let cpuPercent: Double?

    public var id: String { paneID }
    public var processCount: Int { processes.count }
}

public struct TaskManagerWorkspaceSnapshot: Equatable, Identifiable, Sendable {
    public let workspaceID: String
    public let name: String
    public let panes: [TaskManagerPaneSnapshot]
    public let residentBytes: UInt64
    public let cpuPercent: Double?

    public var id: String { workspaceID }
    public var processCount: Int { panes.reduce(0) { $0 + $1.processCount } }
    public var isSelected: Bool { panes.contains(where: \.isSelected) }
}

public struct TaskManagerProgramTotal: Equatable, Identifiable, Sendable {
    public let name: String
    public let processCount: Int
    public let residentBytes: UInt64
    public let cpuPercent: Double?

    public var id: String { name }
}

public struct TaskManagerSnapshot: Equatable, Sendable {
    public let sampledAt: Date
    public let application: TaskManagerApplicationSnapshot?
    public let childResidentBytes: UInt64
    public let processCount: Int
    public let workspaces: [TaskManagerWorkspaceSnapshot]
    public let programTotals: [TaskManagerProgramTotal]
    public let totalCPUPercent: Double?
}

public enum TaskManagerProjection {
    public static func project(
        applicationPID: Int32,
        paneDescriptors: [TaskManagerPaneDescriptor],
        rawProcesses: [TaskManagerRawProcess],
        previousCPUTimeByProcess: [TaskManagerProcessIdentity: UInt64],
        elapsedSeconds: TimeInterval?,
        sampledAt: Date
    ) -> TaskManagerSnapshot {
        let rawByPID = Dictionary(uniqueKeysWithValues: rawProcesses.map { ($0.pid, $0) })
        let ownedProcessesByPaneID = ownedProcessesByPaneID(
            applicationPID: applicationPID,
            paneDescriptors: paneDescriptors,
            rawProcesses: rawProcesses
        )
        let applicationRaw = rawByPID[applicationPID]
        let application = applicationRaw.map { process in
            TaskManagerApplicationSnapshot(
                pid: process.pid,
                name: process.name,
                residentBytes: process.residentBytes,
                cpuPercent: cpuPercent(
                    for: process,
                    previousCPUTimeByProcess: previousCPUTimeByProcess,
                    elapsedSeconds: elapsedSeconds
                )
            )
        }

        var paneSnapshots: [TaskManagerPaneSnapshot] = []
        paneSnapshots.reserveCapacity(paneDescriptors.count)

        for descriptor in paneDescriptors {
            let owned = ownedProcessesByPaneID[descriptor.paneID] ?? []

            let ordered = hierarchyOrder(owned)
            let processSamples = ordered.map { process, depth in
                TaskManagerProcessSample(
                    pid: process.pid,
                    parentPID: process.parentPID,
                    processGroupID: process.processGroupID,
                    name: process.name,
                    residentBytes: process.residentBytes,
                    cpuPercent: cpuPercent(
                        for: process,
                        previousCPUTimeByProcess: previousCPUTimeByProcess,
                        elapsedSeconds: elapsedSeconds
                    ),
                    startedAt: process.startedAt,
                    depth: depth
                )
            }
            paneSnapshots.append(TaskManagerPaneSnapshot(
                paneID: descriptor.paneID,
                workspaceID: descriptor.workspaceID,
                paneName: descriptor.paneName,
                kind: descriptor.kind,
                workingDirectory: descriptor.workingDirectory,
                isSelected: descriptor.isSelected,
                isStarted: descriptor.isStarted,
                ttyName: descriptor.ttyName,
                foregroundPID: descriptor.foregroundPID,
                anchorSource: descriptor.anchorSource,
                processes: processSamples,
                residentBytes: processSamples.reduce(0) { $0 + $1.residentBytes },
                cpuPercent: sumCPU(processSamples.map(\.cpuPercent))
            ))
        }

        var workspaceOrder: [String] = []
        var workspaceNames: [String: String] = [:]
        for descriptor in paneDescriptors where workspaceNames[descriptor.workspaceID] == nil {
            workspaceOrder.append(descriptor.workspaceID)
            workspaceNames[descriptor.workspaceID] = descriptor.workspaceName
        }
        let workspaces = workspaceOrder.map { workspaceID in
            let panes = paneSnapshots.filter { $0.workspaceID == workspaceID }
            return TaskManagerWorkspaceSnapshot(
                workspaceID: workspaceID,
                name: workspaceNames[workspaceID] ?? workspaceID,
                panes: panes,
                residentBytes: panes.reduce(0) { $0 + $1.residentBytes },
                cpuPercent: sumCPU(panes.map(\.cpuPercent))
            )
        }

        let ownedProcesses = paneSnapshots.flatMap(\.processes)
        let programGroups = Dictionary(grouping: ownedProcesses, by: \.name)
        let programTotals = programGroups.map { name, processes in
            TaskManagerProgramTotal(
                name: name,
                processCount: processes.count,
                residentBytes: processes.reduce(0) { $0 + $1.residentBytes },
                cpuPercent: sumCPU(processes.map(\.cpuPercent))
            )
        }.sorted { left, right in
            if left.residentBytes == right.residentBytes { return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending }
            return left.residentBytes > right.residentBytes
        }

        let totalCPU = sumCPU([application?.cpuPercent] + paneSnapshots.map(\.cpuPercent))
        return TaskManagerSnapshot(
            sampledAt: sampledAt,
            application: application,
            childResidentBytes: ownedProcesses.reduce(0) { $0 + $1.residentBytes },
            processCount: ownedProcesses.count + (application == nil ? 0 : 1),
            workspaces: workspaces,
            programTotals: programTotals,
            totalCPUPercent: totalCPU
        )
    }

    public static func ownedProcesses(
        applicationPID: Int32,
        paneDescriptors: [TaskManagerPaneDescriptor],
        rawProcesses: [TaskManagerRawProcess]
    ) -> [String: [TaskManagerRawProcess]] {
        ownedProcessesByPaneID(
            applicationPID: applicationPID,
            paneDescriptors: paneDescriptors,
            rawProcesses: rawProcesses
        )
    }

    public static func ownedProcessIDs(
        applicationPID: Int32,
        paneDescriptors: [TaskManagerPaneDescriptor],
        rawProcesses: [TaskManagerRawProcess]
    ) -> [String: Set<Int32>] {
        ownedProcessesByPaneID(
            applicationPID: applicationPID,
            paneDescriptors: paneDescriptors,
            rawProcesses: rawProcesses
        ).mapValues { Set($0.map(\.pid)) }
    }

    private static func ownedProcessesByPaneID(
        applicationPID: Int32,
        paneDescriptors: [TaskManagerPaneDescriptor],
        rawProcesses: [TaskManagerRawProcess]
    ) -> [String: [TaskManagerRawProcess]] {
        var claimedPIDs: Set<Int32> = []
        var result: [String: [TaskManagerRawProcess]] = [:]
        for descriptor in paneDescriptors {
            guard descriptor.isStarted else {
                result[descriptor.paneID] = []
                continue
            }
            let exactTTY = descriptor.ttyDevice.map { tty in
                rawProcesses.filter { $0.pid != applicationPID && $0.ttyDevice == tty }
            } ?? []
            let candidates = exactTTY.isEmpty
                ? fallbackProcesses(
                    for: descriptor,
                    rawProcesses: rawProcesses,
                    applicationPID: applicationPID
                )
                : exactTTY
            result[descriptor.paneID] = candidates.filter {
                claimedPIDs.insert($0.pid).inserted
            }
        }
        return result
    }

    private static func fallbackProcesses(
        for descriptor: TaskManagerPaneDescriptor,
        rawProcesses: [TaskManagerRawProcess],
        applicationPID: Int32
    ) -> [TaskManagerRawProcess] {
        guard let foregroundPID = descriptor.foregroundPID else { return [] }
        var ownedPIDs: Set<Int32> = [foregroundPID]
        var changed = true
        while changed {
            changed = false
            for process in rawProcesses where process.pid != applicationPID {
                if ownedPIDs.contains(process.parentPID) || process.processGroupID == foregroundPID {
                    changed = ownedPIDs.insert(process.pid).inserted || changed
                }
            }
        }
        return rawProcesses.filter { $0.pid != applicationPID && ownedPIDs.contains($0.pid) }
    }

    private static func hierarchyOrder(_ processes: [TaskManagerRawProcess]) -> [(TaskManagerRawProcess, Int)] {
        let pids = Set(processes.map(\.pid))
        let byParent = Dictionary(grouping: processes, by: \.parentPID)
        let roots = processes.filter { !pids.contains($0.parentPID) }.sorted { $0.pid < $1.pid }
        var result: [(TaskManagerRawProcess, Int)] = []
        var visited: Set<Int32> = []

        func append(_ process: TaskManagerRawProcess, depth: Int) {
            guard visited.insert(process.pid).inserted else { return }
            result.append((process, depth))
            for child in (byParent[process.pid] ?? []).sorted(by: { $0.pid < $1.pid }) {
                append(child, depth: depth + 1)
            }
        }
        for root in roots { append(root, depth: 0) }
        for process in processes.sorted(by: { $0.pid < $1.pid }) where !visited.contains(process.pid) {
            append(process, depth: 0)
        }
        return result
    }

    private static func cpuPercent(
        for process: TaskManagerRawProcess,
        previousCPUTimeByProcess: [TaskManagerProcessIdentity: UInt64],
        elapsedSeconds: TimeInterval?
    ) -> Double? {
        guard let elapsedSeconds, elapsedSeconds > 0,
              let previous = previousCPUTimeByProcess[process.identity],
              process.totalCPUTimeNanoseconds >= previous else { return nil }
        let delta = process.totalCPUTimeNanoseconds - previous
        return Double(delta) / (elapsedSeconds * 1_000_000_000) * 100
    }

    private static func sumCPU(_ values: [Double?]) -> Double? {
        let available = values.compactMap { $0 }
        guard !available.isEmpty else { return nil }
        return available.reduce(0, +)
    }
}

public enum TaskManagerTTY {
    public static func deviceID(for path: String) -> UInt64? {
        guard !path.isEmpty else { return nil }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { return nil }
        return UInt64(information.st_rdev)
    }
}

public final class TaskManagerSampler {
    private var previousCPUTimeByProcess: [TaskManagerProcessIdentity: UInt64] = [:]
    private var previousSampledAt: Date?
    private let anchorResolver: PaneProcessAnchorResolver

    public init(anchorResolver: PaneProcessAnchorResolver = PaneProcessAnchorResolver()) {
        self.anchorResolver = anchorResolver
    }

    public func sample(
        applicationPID: Int32,
        paneDescriptors: [TaskManagerPaneDescriptor],
        sampledAt: Date = Date()
    ) -> TaskManagerSnapshot {
        let rawProcesses = TaskManagerProcessReader.readAll()
        let elapsed = previousSampledAt.map { sampledAt.timeIntervalSince($0) }
        let anchoredDescriptors = anchorResolver.anchored(
            paneDescriptors,
            applicationPID: applicationPID,
            rawProcesses: rawProcesses
        )
        let snapshot = TaskManagerProjection.project(
            applicationPID: applicationPID,
            paneDescriptors: anchoredDescriptors,
            rawProcesses: rawProcesses,
            previousCPUTimeByProcess: previousCPUTimeByProcess,
            elapsedSeconds: elapsed,
            sampledAt: sampledAt
        )
        previousCPUTimeByProcess = Dictionary(
            rawProcesses.map { ($0.identity, $0.totalCPUTimeNanoseconds) },
            uniquingKeysWith: { _, latest in latest }
        )
        previousSampledAt = sampledAt
        return snapshot
    }
}

enum TaskManagerProcessReader {
    static func readAll() -> [TaskManagerRawProcess] {
        let capacity = max(64, Int(proc_listallpids(nil, 0)))
        var pids = [Int32](repeating: 0, count: capacity)
        let byteCount = Int32(pids.count * MemoryLayout<Int32>.stride)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, byteCount)
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap(read(pid:))
    }

    private static func read(pid: Int32) -> TaskManagerRawProcess? {
        guard pid > 0 else { return nil }
        var allInfo = proc_taskallinfo()
        let expected = Int32(MemoryLayout<proc_taskallinfo>.stride)
        let received = withUnsafeMutablePointer(to: &allInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, pointer, expected)
        }
        guard received == expected else { return nil }

        let bsd = allInfo.pbsd
        let task = allInfo.ptinfo
        let startSeconds = TimeInterval(bsd.pbi_start_tvsec)
        let startMicroseconds = TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
        let rawTTY = UInt64(bsd.e_tdev)
        return TaskManagerRawProcess(
            pid: pid,
            parentPID: Int32(bsd.pbi_ppid),
            processGroupID: Int32(bsd.pbi_pgid),
            ttyDevice: rawTTY == UInt64.max || rawTTY == UInt64(UInt32.max) ? nil : rawTTY,
            name: processName(pid: pid),
            residentBytes: task.pti_resident_size,
            totalCPUTimeNanoseconds: task.pti_total_user &+ task.pti_total_system,
            startedAt: Date(timeIntervalSince1970: startSeconds + startMicroseconds)
        )
    }

    private static func processName(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_name(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return "Process \(pid)" }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
