import Darwin
import Foundation

public enum RelayActivityJournalError: LocalizedError {
    case invalidRecord(Int)
    case unsafeFile
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRecord(line):
            "Parley's operational activity contains an invalid record at line \(line)."
        case .unsafeFile:
            "Parley's operational activity is not a regular owner-controlled file."
        case let .writeFailed(detail):
            "Parley could not write its operational activity: \(detail)"
        }
    }
}

/// A small owner-only JSON-lines record for successful native UI operations
/// and vendor lifecycle signals. Each record is one appended, synced line, so
/// a record is durable before it is acknowledged and a truncated final write
/// is discarded on replay. Pruned lines are dropped by periodic compaction
/// (past eight times the bound) and immediately by removal or a smaller
/// bound, so a half-deleted history is never exposed across two launches.
public final class RelayActivityJournal: @unchecked Sendable {
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
    private var maximumEvents: Int
    private let lock = NSLock()
    private var byID: [String: RelayActivityEvent]
    /// Lines in the file since the last compaction, pruned records included.
    private var lineCount: Int
    /// A compaction failure after a durable append; retried by the next one.
    private var storedError: String?
    /// A failed append whose partial bytes could not be truncated away. No
    /// further append is acknowledged until the file is rewritten from the
    /// acknowledged projection.
    private var uncertainTail = false
    private let io: IO

    public init(file: URL, maximumEvents: Int = 500, io: IO = .system) throws {
        self.file = file
        self.io = io
        self.maximumEvents = max(1, maximumEvents)
        let loaded = try Self.load(file: file)
        byID = loaded.events
        lineCount = loaded.lineCount

        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let removed = pruneLocked()
        if removed || loaded.needsRepair || lineCount > self.maximumEvents * 8 { try compactLocked() }
    }

    public var lastError: String? {
        lock.withLock { storedError }
    }

    public var hasUncertainTail: Bool {
        lock.withLock { uncertainTail }
    }

    public func events() -> [RelayActivityEvent] {
        lock.withLock {
            byID.values.sorted {
                if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
                return $0.occurredAt > $1.occurredAt
            }
        }
    }

    public func record(_ event: RelayActivityEvent) throws {
        try lock.withLock {
            // An earlier failure may have left bytes past the committed
            // boundary; rewrite the acknowledged projection before appending
            // anything after them, and refuse if that rewrite fails.
            if uncertainTail {
                do {
                    try compactLocked()
                } catch {
                    throw RelayActivityJournalError.writeFailed("the journal tail is uncertain after an earlier failed append and could not be repaired: \(error.localizedDescription)")
                }
            }
            // Durable first: a failed append throws and changes nothing.
            try appendLocked(event)
            byID[event.id] = event
            _ = pruneLocked()
            lineCount += 1
            // Compaction is maintenance; the appended record is already durable.
            if lineCount > maximumEvents * 8 {
                do {
                    try compactLocked()
                } catch {
                    storedError = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
    public func removeEvents(ids: Set<String>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try lock.withLock {
            let removed = byID.filter { ids.contains($0.key) }
            guard !removed.isEmpty else { return 0 }
            byID = byID.filter { !ids.contains($0.key) }
            do {
                try compactLocked()
                return removed.count
            } catch {
                byID.merge(removed) { _, original in original }
                throw error
            }
        }
    }

    /// Applies the same core-owned bound used for handoff history. Lifecycle
    /// events have no active state, so the oldest events are removed first.
    @discardableResult
    public func updateMaximumEvents(_ maximumEvents: Int) throws -> Int {
        try lock.withLock {
            let previousMaximum = self.maximumEvents
            let previous = byID
            self.maximumEvents = max(1, maximumEvents)
            let removed = pruneLocked()
            let removedCount = previous.count - byID.count
            // Lines already pruned from the projection may still be on disk;
            // a larger bound must never read them back, so any retention
            // change rewrites the file when the two differ.
            guard removed || lineCount > byID.count || uncertainTail else { return 0 }
            do {
                try compactLocked()
                return removedCount
            } catch {
                self.maximumEvents = previousMaximum
                byID = previous
                throw error
            }
        }
    }

    private static func load(file: URL) throws -> (
        events: [String: RelayActivityEvent],
        needsRepair: Bool,
        lineCount: Int
    ) {
        guard FileManager.default.fileExists(atPath: file.path) else { return ([:], false, 0) }
        var metadata = stat()
        guard Darwin.lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid() else {
            throw RelayActivityJournalError.unsafeFile
        }
        let data = try Data(contentsOf: file)
        let endsWithNewline = data.last == 10
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var events: [String: RelayActivityEvent] = [:]
        for (index, line) in lines.enumerated() {
            do {
                let event = try decoder.decode(RelayActivityEvent.self, from: Data(line))
                events[event.id] = event
            } catch {
                let isTruncatedTail = index == lines.count - 1 && !endsWithNewline
                if isTruncatedTail { break }
                throw RelayActivityJournalError.invalidRecord(index + 1)
            }
        }
        return (events, !data.isEmpty && !endsWithNewline, lines.count)
    }

    private func appendLocked(_ event: RelayActivityEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(10)

        let descriptor = Darwin.open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid() else {
            throw RelayActivityJournalError.unsafeFile
        }
        // The committed boundary: everything before it was acknowledged.
        let committed = metadata.st_size
        do {
            try writeAll(data, to: descriptor)
            guard io.fsync(descriptor) == 0 else {
                throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
            }
        } catch {
            // Partial bytes or an unsynced record must not survive past the
            // boundary. If they cannot be cut away, every later append first
            // rewrites the acknowledged projection.
            if io.truncate(descriptor, committed) != 0 || io.fsync(descriptor) != 0 {
                uncertainTail = true
            }
            throw error
        }
    }

    @discardableResult
    private func pruneLocked() -> Bool {
        let excess = byID.count - maximumEvents
        guard excess > 0 else { return false }
        let removalIDs = byID.values.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt < $1.occurredAt
        }.prefix(excess).map(\.id)
        for id in removalIDs { byID.removeValue(forKey: id) }
        return !removalIDs.isEmpty
    }

    private func compactLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ordered = byID.values.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt < $1.occurredAt
        }
        var data = Data()
        for event in ordered {
            data.append(try encoder.encode(event))
            data.append(10)
        }

        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".activity-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        var installed = false
        defer {
            Darwin.close(descriptor)
            if !installed { try? FileManager.default.removeItem(at: temporary) }
        }
        try writeAll(data, to: descriptor)
        guard io.fsync(descriptor) == 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        installed = true
        lineCount = ordered.count
        // Every successful atomic install is a complete, valid file: any
        // earlier maintenance failure or uncertain tail is over.
        storedError = nil
        uncertainTail = false
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = io.write(descriptor, base.advanced(by: written), raw.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
                }
                written += count
            }
        }
    }
}
