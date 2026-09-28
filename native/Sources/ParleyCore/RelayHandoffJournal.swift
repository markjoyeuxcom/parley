import Darwin
import Foundation

public enum RelayHandoffJournalError: LocalizedError {
    case invalidRecord(Int)
    case unsafeFile
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRecord(line):
            "Parley's handoff history contains an invalid record at line \(line)."
        case .unsafeFile:
            "Parley's handoff history is not a regular owner-controlled file."
        case let .writeFailed(detail):
            "Parley could not write its handoff history: \(detail)"
        }
    }
}

/// An owner-only JSON-lines journal. Every line is a complete handoff snapshot,
/// so a truncated final write can be discarded and replay needs no fragile
/// cross-record schema. Older snapshots are compacted periodically; the live
/// record remains append-only between those bounded compactions.
public final class RelayHandoffJournal: @unchecked Sendable {
    /// The system calls an append depends on. Checks inject faults here to
    /// prove partial writes, failed syncs and failed truncations never fuse
    /// into an acknowledged record; production uses `.system`.
    public struct IO: Sendable {
        public var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
        public var fsync: @Sendable (Int32) -> Int32
        public var truncate: @Sendable (Int32, off_t) -> Int32

        public init(write: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int,
                    fsync: @escaping @Sendable (Int32) -> Int32,
                    truncate: @escaping @Sendable (Int32, off_t) -> Int32) {
            self.write = write
            self.fsync = fsync
            self.truncate = truncate
        }

        public static let system = IO(
            write: { descriptor, base, count in Darwin.write(descriptor, base, count) },
            fsync: { descriptor in Darwin.fsync(descriptor) },
            truncate: { descriptor, size in Darwin.ftruncate(descriptor, size) })
    }

    private let file: URL
    private var maximumHandoffs: Int
    private let lock = NSLock()
    private var byID: [String: RelayHandoff]
    private var eventCount: Int
    private var storedError: String?
    /// A failed append whose partial bytes could not be truncated away. No
    /// further append is acknowledged until the file is rewritten from the
    /// acknowledged projection.
    private var uncertainTail = false
    private let io: IO

    public init(file: URL, maximumHandoffs: Int = 500, io: IO = .system) throws {
        self.file = file
        self.io = io
        self.maximumHandoffs = max(1, maximumHandoffs)

        let loaded = try Self.load(file: file)
        byID = loaded.byID
        eventCount = loaded.eventCount
        storedError = nil
        let removed = pruneLocked()

        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if removed || loaded.needsRepair || eventCount > self.maximumHandoffs * 8 {
            try compactLocked()
        }
    }

    public func handoffs() -> [RelayHandoff] {
        lock.withLock {
            byID.values.sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
        }
    }

    public var lastError: String? {
        lock.withLock { storedError }
    }

    public var hasUncertainTail: Bool {
        lock.withLock { uncertainTail }
    }

    /// Persistence failure must not break a relay that already reached a live
    /// terminal. Keep the in-memory projection current and retain the error for
    /// the Status Center's core-health diagnostics.
    public func record(_ handoff: RelayHandoff) {
        lock.withLock {
            byID[handoff.id] = handoff
            _ = pruneLocked()
            do {
                let repaired = uncertainTail
                try repairUncertainTailLocked()
                // Repair already writes this latest in-memory projection.
                if !repaired {
                    try appendLocked(handoff)
                    eventCount += 1
                }
                if eventCount > maximumHandoffs * 8 {
                    try compactLocked()
                }
                storedError = nil
            } catch {
                storedError = error.localizedDescription
                // The projection keeps this record but the file does not have
                // it: the next write rewrites the whole projection first, so
                // an error is never cleared over a record that was lost.
                uncertainTail = true
            }
        }
    }

    /// Human review mutations acknowledge success only after the append is
    /// synced. A failed save leaves the previous projection and revision intact.
    public func recordDurably(_ handoff: RelayHandoff) throws {
        try lock.withLock {
            do {
                try repairUncertainTailLocked()
                try appendLocked(handoff)
            } catch {
                storedError = error.localizedDescription
                throw error
            }
            byID[handoff.id] = handoff
            _ = pruneLocked()
            eventCount += 1
            storedError = nil
            // Compaction is maintenance: the appended record is already durable.
            if eventCount > maximumHandoffs * 8 {
                do { try compactLocked() }
                catch { storedError = error.localizedDescription }
            }
        }
    }

    /// Permanently removes complete snapshots and rewrites the bounded journal
    /// atomically. The caller decides which records are safe to remove; this
    /// type deliberately knows nothing about live broker state.
    @discardableResult
    public func removeHandoffs(ids: Set<String>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try lock.withLock {
            let removed = byID.filter { ids.contains($0.key) }
            guard !removed.isEmpty else { return 0 }
            byID = byID.filter { !ids.contains($0.key) }
            do {
                try compactLocked()
                storedError = nil
                return removed.count
            } catch {
                byID.merge(removed) { _, original in original }
                storedError = error.localizedDescription
                throw error
            }
        }
    }

    /// Applies a person-selected bound immediately and durably. Only terminal
    /// records are eligible; active work may keep the journal above the bound
    /// until it reaches a terminal state.
    @discardableResult
    public func updateMaximumHandoffs(_ maximumHandoffs: Int) throws -> Int {
        try lock.withLock {
            let previousMaximum = self.maximumHandoffs
            let previous = byID
            self.maximumHandoffs = max(1, maximumHandoffs)
            let removed = pruneLocked()
            let removedCount = previous.count - byID.count
            // Appends may already have pruned the projection while older
            // snapshots remain on disk. Persist that pruning before a larger
            // bound can make those snapshots visible again at reload.
            guard removed || eventCount > byID.count || uncertainTail else { return 0 }
            do {
                try compactLocked()
                storedError = nil
                return removedCount
            } catch {
                self.maximumHandoffs = previousMaximum
                byID = previous
                storedError = error.localizedDescription
                throw error
            }
        }
    }

    private static func load(file: URL) throws -> (
        byID: [String: RelayHandoff],
        eventCount: Int,
        needsRepair: Bool
    ) {
        guard FileManager.default.fileExists(atPath: file.path) else { return ([:], 0, false) }
        var metadata = stat()
        guard Darwin.lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid() else {
            throw RelayHandoffJournalError.unsafeFile
        }
        let data = try Data(contentsOf: file)
        let endsWithNewline = data.last == 10
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var records: [String: RelayHandoff] = [:]
        var decodedCount = 0
        for (index, line) in lines.enumerated() {
            do {
                let handoff = try decoder.decode(RelayHandoff.self, from: Data(line))
                records[handoff.id] = handoff
                decodedCount += 1
            } catch {
                let isTruncatedTail = index == lines.count - 1 && !endsWithNewline
                if isTruncatedTail { break }
                throw RelayHandoffJournalError.invalidRecord(index + 1)
            }
        }
        return (records, decodedCount, !data.isEmpty && !endsWithNewline)
    }

    @discardableResult
    private func pruneLocked() -> Bool {
        let excess = byID.count - maximumHandoffs
        guard excess > 0 else { return false }
        let terminal: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        let removalIDs = byID.values
            .filter { terminal.contains($0.state) }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt < $1.updatedAt
            }
            .prefix(excess)
            .map(\.id)
        for id in removalIDs { byID.removeValue(forKey: id) }
        return !removalIDs.isEmpty
    }

    private func appendLocked(_ handoff: RelayHandoff) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(handoff)
        data.append(10)

        let descriptor = Darwin.open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid() else {
            throw RelayHandoffJournalError.unsafeFile
        }
        // The committed boundary: everything before it was acknowledged.
        let committed = metadata.st_size
        do {
            try writeAll(data, to: descriptor)
            guard io.fsync(descriptor) == 0 else {
                throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
            }
        } catch {
            // Partial bytes or an unsynced record must not survive past the
            // boundary. A later append would otherwise start mid-line and fuse
            // the two into one record that no launch can decode. If they cannot
            // be cut away, every later append first rewrites the projection.
            if io.truncate(descriptor, committed) != 0 || io.fsync(descriptor) != 0 {
                uncertainTail = true
            }
            throw error
        }
    }

    /// Rewrites the acknowledged projection when an earlier append left bytes
    /// past the committed boundary. Appending after them is what turns a failed
    /// write into an unreadable journal, so this runs before any further append.
    private func repairUncertainTailLocked() throws {
        guard uncertainTail else { return }
        do {
            try compactLocked()
        } catch {
            throw RelayHandoffJournalError.writeFailed(
                "the journal tail is uncertain after an earlier failed append and could not be repaired: \(error.localizedDescription)"
            )
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = io.write(descriptor, base.advanced(by: written), raw.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
                }
                written += count
            }
        }
    }

    private func compactLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ordered = byID.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt < $1.updatedAt
        }
        var data = Data()
        for handoff in ordered {
            data.append(try encoder.encode(handoff))
            data.append(10)
        }
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".handoffs-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        var installed = false
        defer {
            Darwin.close(descriptor)
            if !installed { try? FileManager.default.removeItem(at: temporary) }
        }
        try writeAll(data, to: descriptor)
        guard io.fsync(descriptor) == 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        installed = true
        eventCount = ordered.count
        // Every successful atomic install is a complete, valid file: any
        // earlier maintenance failure or uncertain tail is over.
        uncertainTail = false
    }
}
