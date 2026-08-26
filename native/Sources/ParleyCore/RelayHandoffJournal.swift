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
    private let file: URL
    private var maximumHandoffs: Int
    private let lock = NSLock()
    private var byID: [String: RelayHandoff]
    private var eventCount: Int
    private var storedError: String?

    public init(file: URL, maximumHandoffs: Int = 500) throws {
        self.file = file
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

    /// Persistence failure must not break a relay that already reached a live
    /// terminal. Keep the in-memory projection current and retain the error for
    /// the Status Center's core-health diagnostics.
    public func record(_ handoff: RelayHandoff) {
        lock.withLock {
            byID[handoff.id] = handoff
            _ = pruneLocked()
            do {
                try appendLocked(handoff)
                eventCount += 1
                if eventCount > maximumHandoffs * 8 {
                    try compactLocked()
                }
                storedError = nil
            } catch {
                storedError = error.localizedDescription
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
            guard removed else { return 0 }
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
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
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
        guard Darwin.fsync(descriptor) == 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw RelayHandoffJournalError.writeFailed(String(cString: strerror(errno)))
        }
        installed = true
        eventCount = ordered.count
    }
}
