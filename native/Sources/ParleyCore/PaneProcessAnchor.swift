import Darwin
import Foundation

/// How a pane's process tree was anchored to real kernel state.
public enum PaneProcessAnchorSource: String, Codable, Equatable, Sendable {
    /// The retained Ghostty surface reported its foreground PID or TTY.
    case ghostty
    /// A process in the pane's own launch tree carried this pane's
    /// `PARLEY_PANE_ID` marker; the tree's root and its controlling TTY anchor
    /// the pane.
    case paneMarker
    /// Neither source produced evidence. The pane stays honestly empty.
    case unavailable
}

/// One pane's root process, discovered from the launch marker Parley itself
/// injected. Only the process id and its TTY device are kept.
public struct PaneProcessRoot: Equatable, Sendable {
    public let paneID: String
    public let pid: Int32
    public let ttyDevice: UInt64?

    public init(paneID: String, pid: Int32, ttyDevice: UInt64?) {
        self.paneID = paneID
        self.pid = pid
        self.ttyDevice = ttyDevice
    }
}

/// Pure attribution over an already-read process list.
///
/// Ghostty's exec backend starts every pane through `/usr/bin/login`, a
/// privileged process the same-user task reader cannot list, so a pane root is
/// a visible process whose parent is the application or whose parent is one
/// invisible intermediate that itself belongs to the application. Platform
/// binaries such as `/bin/zsh` hide their environment from other processes, so
/// when a root's marker is unreadable the marker is looked for on its own
/// descendants, which inherit it. `markerValue` returns nothing but the
/// `PARLEY_PANE_ID` value and is only ever asked about processes inside the
/// application's own launch trees; argv and environment bytes never reach this
/// projection. `parentPID` is asked only about pids missing from the visible
/// list.
public enum PaneProcessAnchorProjection {
    public static let markerKey = "PARLEY_PANE_ID"
    public static let maximumDescendantReadsPerRoot = 64

    public static func roots(
        applicationPID: Int32,
        paneIDs: Set<String>,
        rawProcesses: [TaskManagerRawProcess],
        markerValue: (Int32) -> String?,
        parentPID: (Int32) -> Int32? = { _ in nil }
    ) -> [String: PaneProcessRoot] {
        guard applicationPID > 0, !paneIDs.isEmpty else { return [:] }
        let visible = Set(rawProcesses.map(\.pid))
        var intermediateParents: [Int32: Int32?] = [:]
        func parentOfInvisible(_ pid: Int32) -> Int32? {
            if let cached = intermediateParents[pid] { return cached }
            let resolved = parentPID(pid)
            intermediateParents[pid] = resolved
            return resolved
        }

        let candidateRoots = rawProcesses
            .filter { process in
                guard process.pid > 0, process.pid != applicationPID else { return false }
                if process.parentPID == applicationPID { return true }
                guard process.parentPID > 1, !visible.contains(process.parentPID) else { return false }
                return parentOfInvisible(process.parentPID) == applicationPID
            }
            .sorted { $0.pid < $1.pid }
        guard !candidateRoots.isEmpty else { return [:] }

        let childrenByParent = Dictionary(grouping: rawProcesses.filter { $0.pid != applicationPID }, by: \.parentPID)
        var claimants: [String: [TaskManagerRawProcess]] = [:]
        for root in candidateRoots {
            var marker = markerValue(root.pid)
            if marker == nil {
                var queue = (childrenByParent[root.pid] ?? []).sorted { $0.pid < $1.pid }
                var visited: Set<Int32> = [root.pid]
                var reads = 0
                while marker == nil, !queue.isEmpty, reads < maximumDescendantReadsPerRoot {
                    let next = queue.removeFirst()
                    guard visited.insert(next.pid).inserted else { continue }
                    reads += 1
                    marker = markerValue(next.pid)
                    queue.append(contentsOf: (childrenByParent[next.pid] ?? []).sorted { $0.pid < $1.pid })
                }
            }
            guard let paneID = marker, paneIDs.contains(paneID) else { continue }
            claimants[paneID, default: []].append(root)
        }

        var roots: [String: PaneProcessRoot] = [:]
        for (paneID, processes) in claimants where processes.count == 1 {
            let root = processes[0]
            roots[paneID] = PaneProcessRoot(paneID: paneID, pid: root.pid, ttyDevice: root.ttyDevice)
        }
        return roots
    }

    /// Fills only started descriptors that have neither a Ghostty foreground
    /// PID nor a Ghostty TTY. Ghostty's own evidence is always preferred.
    public static func anchored(
        _ descriptors: [TaskManagerPaneDescriptor],
        roots: [String: PaneProcessRoot]
    ) -> [TaskManagerPaneDescriptor] {
        descriptors.map { descriptor in
            guard descriptor.isStarted,
                  descriptor.foregroundPID == nil,
                  descriptor.ttyDevice == nil,
                  let root = roots[descriptor.paneID],
                  root.pid > 0 else { return descriptor }
            return TaskManagerPaneDescriptor(
                paneID: descriptor.paneID,
                workspaceID: descriptor.workspaceID,
                workspaceName: descriptor.workspaceName,
                paneName: descriptor.paneName,
                kind: descriptor.kind,
                workingDirectory: descriptor.workingDirectory,
                isSelected: descriptor.isSelected,
                isStarted: descriptor.isStarted,
                foregroundPID: root.pid,
                ttyName: descriptor.ttyName,
                ttyDevice: root.ttyDevice,
                anchorSource: .paneMarker
            )
        }
    }
}

/// Bounded same-user resolver over the application's own launch trees. It
/// discards every byte except the marker value and never persists or logs
/// what it read.
public struct PaneProcessAnchorResolver: Sendable {
    public typealias MarkerValue = @Sendable (Int32) -> String?
    public typealias ParentPID = @Sendable (Int32) -> Int32?

    private let markerValue: MarkerValue
    private let parentPID: ParentPID

    public init(
        markerValue: @escaping MarkerValue = { pid in
            ProcessEnvironmentMarker.value(PaneProcessAnchorProjection.markerKey, forProcess: pid)
        },
        parentPID: @escaping ParentPID = { pid in
            ProcessKernelFacts.parentPID(ofProcess: pid)
        }
    ) {
        self.markerValue = markerValue
        self.parentPID = parentPID
    }

    public func roots(
        applicationPID: Int32,
        paneIDs: Set<String>,
        rawProcesses: [TaskManagerRawProcess]
    ) -> [String: PaneProcessRoot] {
        PaneProcessAnchorProjection.roots(
            applicationPID: applicationPID,
            paneIDs: paneIDs,
            rawProcesses: rawProcesses,
            markerValue: markerValue,
            parentPID: parentPID
        )
    }

    public func anchored(
        _ descriptors: [TaskManagerPaneDescriptor],
        applicationPID: Int32,
        rawProcesses: [TaskManagerRawProcess]
    ) -> [TaskManagerPaneDescriptor] {
        let unanchored = Set(descriptors.filter {
            $0.isStarted && $0.foregroundPID == nil && $0.ttyDevice == nil
        }.map(\.paneID))
        guard !unanchored.isEmpty else { return descriptors }
        return PaneProcessAnchorProjection.anchored(
            descriptors,
            roots: roots(applicationPID: applicationPID, paneIDs: unanchored, rawProcesses: rawProcesses)
        )
    }
}

/// Reads one environment marker of one same-user process through
/// `KERN_PROCARGS2`. The buffer is local to the call, zeroed and released
/// before it returns; nothing else from argv or the environment is exposed,
/// logged or retained. macOS withholds the environment of platform binaries
/// from every other process, in which case this returns nil.
public enum ProcessEnvironmentMarker {
    public static let maximumBytes = 1 << 20

    public static func value(_ key: String, forProcess pid: Int32) -> String? {
        guard pid > 0, !key.isEmpty, !key.contains("=") else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        size = min(size, maximumBytes)
        var buffer = [UInt8](repeating: 0, count: size)
        defer {
            buffer.withUnsafeMutableBytes { bytes in
                _ = memset(bytes.baseAddress, 0, bytes.count)
            }
        }
        let readStatus = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, UInt32(mib.count), bytes.baseAddress, &size, nil, 0)
        }
        guard readStatus == 0, size > 4 else { return nil }
        let length = min(size, buffer.count)

        var argumentCount = Int(buffer[0]) | (Int(buffer[1]) << 8) | (Int(buffer[2]) << 16) | (Int(buffer[3]) << 24)
        var index = 4
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }
        while argumentCount > 0, index < length {
            while index < length, buffer[index] != 0 { index += 1 }
            index += 1
            argumentCount -= 1
        }

        let prefix = Array("\(key)=".utf8)
        while index < length {
            let start = index
            while index < length, buffer[index] != 0 { index += 1 }
            let entry = buffer[start..<index]
            index += 1
            if entry.isEmpty { break }
            if entry.count >= prefix.count, entry.prefix(prefix.count).elementsEqual(prefix) {
                return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
        }
        return nil
    }
}

/// Kernel-owned facts about one process id, read through `kern.proc.pid` and
/// used only for the pane launch processes Parley itself started and the
/// root-owned `login` intermediate Ghostty places above them. No terminal text
/// is involved.
public enum ProcessKernelFacts {
    public static func parentPID(ofProcess pid: Int32) -> Int32? {
        guard let info = kernelInfo(pid) else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func ttyDevice(forProcess pid: Int32) -> UInt64? {
        guard let info = kernelInfo(pid) else { return nil }
        let raw = UInt32(bitPattern: info.kp_eproc.e_tdev)
        return raw == UInt32.max ? nil : UInt64(raw)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func kernelInfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            sysctl(&mib, UInt32(mib.count), pointer, &size, nil, 0)
        }
        guard status == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}

/// One pane's observed shell evidence in the real-Ghostty soak: the pid the
/// shell itself wrote, whether that process is alive, and its TTY device.
public struct SoakPaneObservation: Equatable, Sendable {
    public let index: Int
    public let pid: Int32?
    public let isAlive: Bool
    public let ttyDevice: UInt64?

    public init(index: Int, pid: Int32?, isAlive: Bool, ttyDevice: UInt64?) {
        self.index = index
        self.pid = pid
        self.isAlive = isAlive
        self.ttyDevice = ttyDevice
    }
}

public enum SoakPaneEvidenceVerdict: Equatable, Sendable {
    case ready
    case failed(String)
}

/// Fail-closed readiness for the soak: every pane must have written a live
/// shell pid that owns its own distinct controlling TTY.
public enum SoakPaneEvidence {
    public static func evaluate(_ observations: [SoakPaneObservation], expectedPanes: Int) -> SoakPaneEvidenceVerdict {
        guard observations.count == expectedPanes else {
            return .failed("expected \(expectedPanes) pane observations, found \(observations.count)")
        }
        var ttyOwners: [UInt64: Int] = [:]
        for observation in observations.sorted(by: { $0.index < $1.index }) {
            guard let pid = observation.pid, pid > 0 else {
                return .failed("pane \(observation.index) did not write a live shell pid")
            }
            guard observation.isAlive else {
                return .failed("pane \(observation.index) shell \(pid) is not alive")
            }
            guard let tty = observation.ttyDevice else {
                return .failed("pane \(observation.index) shell \(pid) has no controlling TTY")
            }
            if let owner = ttyOwners[tty] {
                return .failed("panes \(owner) and \(observation.index) share one TTY device")
            }
            ttyOwners[tty] = observation.index
        }
        return .ready
    }
}
