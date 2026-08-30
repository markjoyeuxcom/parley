import Darwin
import Foundation

public enum CollaborationHistoryRetentionError: LocalizedError, Equatable {
    case unsupportedMaximum(Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedMaximum(value):
            "Parley cannot retain \(value) history records. Choose 100, 250, or 500."
        case let .unreadable(detail):
            detail
        }
    }
}

/// One bounded limit is applied independently to collaboration handoffs and
/// native lifecycle activity. Active handoffs may temporarily exceed it: no
/// retention operation is allowed to delete work that has not reached a
/// terminal state.
public struct CollaborationHistoryRetentionPolicy: Codable, Equatable, Sendable {
    public static let allowedMaximumRecords = [100, 250, 500]
    public static let defaultPolicy = CollaborationHistoryRetentionPolicy(uncheckedMaximumRecords: 500)

    public let maximumRecords: Int

    public init(maximumRecords: Int) throws {
        guard Self.allowedMaximumRecords.contains(maximumRecords) else {
            throw CollaborationHistoryRetentionError.unsupportedMaximum(maximumRecords)
        }
        self.maximumRecords = maximumRecords
    }

    private init(uncheckedMaximumRecords: Int) {
        maximumRecords = uncheckedMaximumRecords
    }

    private enum CodingKeys: String, CodingKey {
        case maximumRecords
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumRecords: values.decode(Int.self, forKey: .maximumRecords))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximumRecords, forKey: .maximumRecords)
    }
}

public struct CollaborationHistoryRetentionChange: Codable, Equatable, Sendable {
    public let policy: CollaborationHistoryRetentionPolicy
    public let removedHandoffs: Int
    public let removedActivityEvents: Int

    public init(
        policy: CollaborationHistoryRetentionPolicy,
        removedHandoffs: Int,
        removedActivityEvents: Int
    ) {
        self.policy = policy
        self.removedHandoffs = removedHandoffs
        self.removedActivityEvents = removedActivityEvents
    }
}

/// The app-resident core owns this preference across window hiding and remounts.
/// The file is runtime-local, owner-only and deliberately contains no content
/// beyond the bounded record-count policy.
public final class CollaborationHistoryRetentionStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let policy: CollaborationHistoryRetentionPolicy
    }

    private static let maximumDocumentBytes = 4 * 1_024

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func policy() throws -> CollaborationHistoryRetentionPolicy {
        try lock.withLock { try loadLocked() }
    }

    public func save(_ policy: CollaborationHistoryRetentionPolicy) throws {
        try lock.withLock { try writeLocked(policy) }
    }

    private func loadLocked() throws -> CollaborationHistoryRetentionPolicy {
        guard fileManager.fileExists(atPath: file.path) else { return .defaultPolicy }
        do {
            try validateExistingFile()
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumDocumentBytes else {
                throw CollaborationHistoryRetentionError.unreadable(
                    "Parley's history-retention preference is larger than its 4 KB safety bound."
                )
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw CollaborationHistoryRetentionError.unreadable(
                    "Parley's history-retention preference uses an unsupported version."
                )
            }
            return document.policy
        } catch let error as CollaborationHistoryRetentionError {
            throw error
        } catch {
            throw CollaborationHistoryRetentionError.unreadable(
                "Parley's history-retention preference could not be read: \(error.localizedDescription)"
            )
        }
    }

    private func writeLocked(_ policy: CollaborationHistoryRetentionPolicy) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, policy: policy))
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw CollaborationHistoryRetentionError.unreadable(
                "Parley's history-retention preference is not an owner-only regular file."
            )
        }
    }
}
