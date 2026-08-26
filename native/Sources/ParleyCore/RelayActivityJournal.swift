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

/// A small owner-only JSON-lines record for successful native UI operations.
/// Operations are infrequent, so each change rewrites the bounded projection
/// atomically instead of exposing a half-deleted history across two launches.
public final class RelayActivityJournal: @unchecked Sendable {
    private let file: URL
    private var maximumEvents: Int
    private let lock = NSLock()
    private var byID: [String: RelayActivityEvent]

    public init(file: URL, maximumEvents: Int = 500) throws {
        self.file = file
        self.maximumEvents = max(1, maximumEvents)
        let loaded = try Self.load(file: file)
        byID = loaded.events

        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let removed = pruneLocked()
        if removed || loaded.needsRepair { try compactLocked() }
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
            let previous = byID
            byID[event.id] = event
            _ = pruneLocked()
            do {
                try compactLocked()
            } catch {
                byID = previous
                throw error
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
            guard removed else { return 0 }
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
        needsRepair: Bool
    ) {
        guard FileManager.default.fileExists(atPath: file.path) else { return ([:], false) }
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
        return (events, !data.isEmpty && !endsWithNewline)
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
        guard Darwin.fsync(descriptor) == 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
        }
        installed = true
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw RelayActivityJournalError.writeFailed(String(cString: strerror(errno)))
                }
                written += count
            }
        }
    }
}
