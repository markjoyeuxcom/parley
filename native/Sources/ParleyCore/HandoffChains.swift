import Darwin
import Foundation

public enum HandoffChainBookmarkKind: String, Codable, Equatable, Sendable {
    case answer
    case objection
    case decision

    public var label: String {
        switch self {
        case .answer: "Answer"
        case .objection: "Objection"
        case .decision: "Human decision"
        }
    }
}

/// An immutable snapshot of one broker handoff. Curated chains must remain
/// readable after the bounded broker journal has pruned the source record.
public struct HandoffChainEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let handoffID: String
    public let kind: RelayHandoffKind
    public let sourceName: String
    public let sourceKind: PaneKind?
    public let targetName: String
    public let targetKind: PaneKind?
    public let prompt: String
    public let result: String?
    public let state: RelayHandoffState
    public let occurredAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        handoffID: String,
        kind: RelayHandoffKind,
        sourceName: String,
        sourceKind: PaneKind?,
        targetName: String,
        targetKind: PaneKind?,
        prompt: String,
        result: String?,
        state: RelayHandoffState,
        occurredAt: Date
    ) {
        self.id = id
        self.handoffID = handoffID
        self.kind = kind
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.targetName = targetName
        self.targetKind = targetKind
        self.prompt = prompt
        self.result = result
        self.state = state
        self.occurredAt = occurredAt
    }

    public init(handoff: RelayHandoff) {
        self.init(
            handoffID: handoff.id,
            kind: handoff.kind,
            sourceName: handoff.sourceName,
            sourceKind: handoff.sourceKind,
            targetName: handoff.targetName,
            targetKind: handoff.targetKind,
            prompt: handoff.text,
            result: handoff.resultText,
            state: handoff.state,
            occurredAt: handoff.transitions.first?.occurredAt ?? handoff.updatedAt
        )
    }
}

/// A person-curated piece of evidence. Answers and objections retain the exact
/// selected handoff result; decisions retain the exact text the person entered.
public struct HandoffChainBookmark: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let entryID: String?
    public let kind: HandoffChainBookmarkKind
    public let text: String
    public let createdAt: Date
    public let origin: RelayTransitionOrigin?

    public init(
        id: String = UUID().uuidString.lowercased(),
        entryID: String?,
        kind: HandoffChainBookmarkKind,
        text: String,
        createdAt: Date = Date(),
        origin: RelayTransitionOrigin? = nil
    ) {
        self.id = id
        self.entryID = entryID
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.origin = origin
    }
}

public struct HandoffChain: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public let workspaceID: String
    public let workspaceName: String
    public let createdAt: Date
    public var updatedAt: Date
    public var entries: [HandoffChainEntry]
    public var bookmarks: [HandoffChainBookmark]

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        workspaceID: String,
        workspaceName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        entries: [HandoffChainEntry],
        bookmarks: [HandoffChainBookmark] = []
    ) {
        self.id = id
        self.title = title
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = entries
        self.bookmarks = bookmarks
    }
}

public enum HandoffChainError: LocalizedError, Equatable {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail), let .unreadable(detail): detail
        }
    }
}

public enum HandoffChainProjection {
    public static func chains(reloaded chains: [HandoffChain], workspaceID: String?) -> [HandoffChain] {
        chains
            .filter { workspaceID == nil || $0.workspaceID == workspaceID }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
    }
}

/// Owner-only, explicitly curated collaboration history. This is deliberately
/// independent of the relay state machine: adding evidence never sends input,
/// changes a handoff, infers a verdict, or starts an agent.
public final class HandoffChainStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let chains: [HandoffChain]
    }

    public static let maximumChains = 100
    public static let maximumEntriesPerChain = 100
    public static let maximumBookmarksPerChain = 100
    public static let maximumTextBytes = ContextPackBuilder.defaultMaximumRenderedBytes
    private static let maximumDocumentBytes = 20 * 1_024 * 1_024

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func chains() throws -> [HandoffChain] {
        try lock.withLock { try HandoffChainProjection.chains(reloaded: loadLocked(), workspaceID: nil) }
    }

    public func create(
        title: String,
        workspaceID: String,
        workspaceName: String,
        firstEntry: HandoffChainEntry,
        now: Date = Date()
    ) throws -> HandoffChain {
        try lock.withLock {
            let title = try Self.validTitle(title)
            let workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspaceID.isEmpty, !workspaceName.isEmpty else {
                throw HandoffChainError.invalid("A handoff chain needs a workspace id and name.")
            }
            try Self.validate(firstEntry)
            var current = try loadLocked()
            guard current.count < Self.maximumChains else {
                throw HandoffChainError.invalid("Parley keeps at most \(Self.maximumChains) curated handoff chains. Delete one before creating another.")
            }
            let chain = HandoffChain(
                title: title,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                createdAt: now,
                updatedAt: now,
                entries: [firstEntry]
            )
            current.append(chain)
            try writeLocked(current)
            return chain
        }
    }

    public func add(
        entry: HandoffChainEntry,
        to chainID: String,
        now: Date = Date()
    ) throws -> HandoffChain {
        try lock.withLock {
            try Self.validate(entry)
            var current = try loadLocked()
            guard let index = current.firstIndex(where: { $0.id == chainID }) else {
                throw HandoffChainError.invalid("Unknown handoff chain.")
            }
            guard !current[index].entries.contains(where: { $0.handoffID == entry.handoffID }) else {
                throw HandoffChainError.invalid("That handoff is already in this chain.")
            }
            guard current[index].entries.count < Self.maximumEntriesPerChain else {
                throw HandoffChainError.invalid("This chain already has \(Self.maximumEntriesPerChain) handoffs.")
            }
            current[index].entries.append(entry)
            current[index].updatedAt = now
            try writeLocked(current)
            return current[index]
        }
    }

    public func bookmark(
        chainID: String,
        entryID: String,
        kind: HandoffChainBookmarkKind,
        text: String,
        now: Date = Date()
    ) throws -> HandoffChain {
        try lock.withLock {
            guard kind != .decision else {
                throw HandoffChainError.invalid("Use a human decision for decision bookmarks.")
            }
            var current = try loadLocked()
            guard let index = current.firstIndex(where: { $0.id == chainID }) else {
                throw HandoffChainError.invalid("Unknown handoff chain.")
            }
            guard current[index].entries.contains(where: { $0.id == entryID }) else {
                throw HandoffChainError.invalid("The bookmarked handoff is not in this chain.")
            }
            try Self.appendBookmark(
                HandoffChainBookmark(entryID: entryID, kind: kind, text: text, createdAt: now),
                to: &current[index]
            )
            current[index].updatedAt = now
            try writeLocked(current)
            return current[index]
        }
    }

    public func addDecision(
        chainID: String,
        text: String,
        now: Date = Date()
    ) throws -> HandoffChain {
        try lock.withLock {
            var current = try loadLocked()
            guard let index = current.firstIndex(where: { $0.id == chainID }) else {
                throw HandoffChainError.invalid("Unknown handoff chain.")
            }
            try Self.appendBookmark(
                HandoffChainBookmark(
                    entryID: nil,
                    kind: .decision,
                    text: text,
                    createdAt: now,
                    origin: .human
                ),
                to: &current[index]
            )
            current[index].updatedAt = now
            try writeLocked(current)
            return current[index]
        }
    }

    public func delete(id: String) throws {
        try lock.withLock {
            var current = try loadLocked()
            guard current.contains(where: { $0.id == id }) else { return }
            current.removeAll { $0.id == id }
            try writeLocked(current)
        }
    }

    private static func appendBookmark(_ bookmark: HandoffChainBookmark, to chain: inout HandoffChain) throws {
        let text = bookmark.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HandoffChainError.invalid("A bookmarked answer, objection or decision cannot be empty.")
        }
        guard text.utf8.count <= maximumTextBytes else {
            throw HandoffChainError.invalid("That evidence is too large to bookmark in one handoff chain.")
        }
        guard chain.bookmarks.count < maximumBookmarksPerChain else {
            throw HandoffChainError.invalid("This chain already has \(maximumBookmarksPerChain) bookmarks.")
        }
        chain.bookmarks.append(bookmark)
    }

    private static func validTitle(_ value: String) throws -> String {
        let title = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 160 else {
            throw HandoffChainError.invalid("A handoff chain title must be 1–160 bytes on one line.")
        }
        return title
    }

    private static func validate(_ entry: HandoffChainEntry) throws {
        guard !entry.handoffID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HandoffChainError.invalid("A handoff chain entry needs its source record, participants and prompt.")
        }
        let textBytes = entry.prompt.utf8.count + (entry.result?.utf8.count ?? 0)
        guard textBytes <= maximumTextBytes else {
            throw HandoffChainError.invalid("That handoff is too large to preserve in one chain.")
        }
    }

    private func loadLocked() throws -> [HandoffChain] {
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        do {
            try validateExistingFile()
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumDocumentBytes,
                  let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == 1,
                  document.chains.count <= Self.maximumChains,
                  Set(document.chains.map(\.id)).count == document.chains.count else {
                throw HandoffChainError.unreadable("Parley's handoff chain file is invalid or unsupported.")
            }
            return document.chains
        } catch let error as HandoffChainError {
            throw error
        } catch {
            throw HandoffChainError.unreadable("Handoff chains could not be read: \(error.localizedDescription)")
        }
    }

    private func writeLocked(_ chains: [HandoffChain]) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, chains: chains))
        guard data.count <= Self.maximumDocumentBytes else {
            throw HandoffChainError.invalid("Curated handoff chains have reached Parley's 20 MB local safety bound.")
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw HandoffChainError.unreadable("The handoff chain file is not an owner-only regular file.")
        }
    }
}
