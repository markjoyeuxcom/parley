import Darwin
import Foundation

public enum ReviewedBusyDraftState: String, Codable, Equatable, Sendable {
    /// Reviewed by a person, durable, visible and not submitted.
    case queued
    /// A person explicitly chose Review and Send. This state is never entered
    /// by a timer or by target-idle observation.
    case dispatching
}

/// An exact person-reviewed Ask held because its chosen target already owns
/// tracked work. It contains routing facts and text, never pane credentials.
public struct ReviewedBusyDraft: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourcePaneID: String
    public let sourceName: String
    public let sourceKind: PaneKind
    public let sourceWorkspaceID: String
    public let sourceWorkspaceName: String?
    public let targetPaneID: String
    public let targetName: String
    public let targetKind: PaneKind
    public let targetWorkspaceID: String
    public let targetWorkspaceName: String?
    public var text: String
    public var preserveFormatting: Bool
    public var state: ReviewedBusyDraftState
    public let origin: RelayTransitionOrigin
    public let createdAt: Date
    public var updatedAt: Date
    public var detail: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        sourcePaneID: String,
        sourceName: String,
        sourceKind: PaneKind,
        sourceWorkspaceID: String,
        sourceWorkspaceName: String?,
        targetPaneID: String,
        targetName: String,
        targetKind: PaneKind,
        targetWorkspaceID: String,
        targetWorkspaceName: String?,
        text: String,
        preserveFormatting: Bool,
        state: ReviewedBusyDraftState = .queued,
        origin: RelayTransitionOrigin = .human,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        detail: String? = nil
    ) {
        self.id = id
        self.sourcePaneID = sourcePaneID
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceWorkspaceName = sourceWorkspaceName
        self.targetPaneID = targetPaneID
        self.targetName = targetName
        self.targetKind = targetKind
        self.targetWorkspaceID = targetWorkspaceID
        self.targetWorkspaceName = targetWorkspaceName
        self.text = text
        self.preserveFormatting = preserveFormatting
        self.state = state
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.detail = detail
    }
}

public struct ReviewedBusyDraftCreateRequest: Codable, Equatable, Sendable {
    public let sourcePaneID: String
    public let targetPaneID: String
    public let text: String
    public let preserveFormatting: Bool

    public init(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        preserveFormatting: Bool = false
    ) {
        self.sourcePaneID = sourcePaneID
        self.targetPaneID = targetPaneID
        self.text = text
        self.preserveFormatting = preserveFormatting
    }
}

public struct ReviewedBusyDraftSendRequest: Codable, Equatable, Sendable {
    public let draftID: String
    public let expectedUpdatedAt: Date
    public let text: String
    public let preserveFormatting: Bool

    public init(
        draftID: String,
        expectedUpdatedAt: Date,
        text: String,
        preserveFormatting: Bool = false
    ) {
        self.draftID = draftID
        self.expectedUpdatedAt = expectedUpdatedAt
        self.text = text
        self.preserveFormatting = preserveFormatting
    }
}

public enum ReviewedBusyDraftStoreError: LocalizedError, Equatable {
    case invalid(String)
    case stale
    case tooMany
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail), let .unreadable(detail): detail
        case .stale:
            "That queued draft changed after this preview. Reopen it before sending."
        case .tooMany:
            "Parley already has 32 reviewed drafts waiting on busy targets. Send or discard one before queueing another."
        }
    }
}

/// The app-resident core owns this bounded, owner-only queue. No method observes
/// target idleness and no method dispatches without an explicit send request.
public final class ReviewedBusyDraftStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let drafts: [ReviewedBusyDraft]
    }

    public static let maximumDrafts = 32
    private static let maximumDocumentBytes = 4 * 1_024 * 1_024

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var byID: [String: ReviewedBusyDraft]

    public init(file: URL, fileManager: FileManager = .default) throws {
        self.file = file
        self.fileManager = fileManager
        self.byID = try Self.load(file: file, fileManager: fileManager)
    }

    public func drafts() -> [ReviewedBusyDraft] {
        lock.withLock { orderedLocked() }
    }

    public func draft(id: String) -> ReviewedBusyDraft? {
        lock.withLock { byID[id] }
    }

    public func record(_ draft: ReviewedBusyDraft) throws {
        try lock.withLock {
            try Self.validate(draft)
            guard byID[draft.id] != nil || byID.count < Self.maximumDrafts else {
                throw ReviewedBusyDraftStoreError.tooMany
            }
            var updated = byID
            updated[draft.id] = draft
            try writeLocked(updated)
            byID = updated
        }
    }

    public func beginExplicitSend(
        id: String,
        expectedUpdatedAt: Date,
        text: String,
        preserveFormatting: Bool,
        now: Date = Date()
    ) throws -> ReviewedBusyDraft {
        try lock.withLock {
            guard var draft = byID[id] else {
                throw ReviewedBusyDraftStoreError.invalid("That queued draft no longer exists.")
            }
            guard draft.state == .queued else {
                throw ReviewedBusyDraftStoreError.invalid("That queued draft is already being sent.")
            }
            guard draft.updatedAt == expectedUpdatedAt else {
                throw ReviewedBusyDraftStoreError.stale
            }
            draft.text = text
            draft.preserveFormatting = preserveFormatting
            draft.state = .dispatching
            draft.updatedAt = now
            draft.detail = "A person explicitly chose Review and Send."
            try Self.validate(draft)
            var updated = byID
            updated[id] = draft
            try writeLocked(updated)
            byID = updated
            return draft
        }
    }

    public func restoreQueued(id: String, detail: String, now: Date = Date()) throws {
        try lock.withLock {
            guard var draft = byID[id] else { return }
            draft.state = .queued
            draft.updatedAt = now
            draft.detail = detail
            var updated = byID
            updated[id] = draft
            try writeLocked(updated)
            byID = updated
        }
    }

    public func remove(id: String) throws {
        try lock.withLock {
            guard byID[id] != nil else { return }
            var updated = byID
            updated.removeValue(forKey: id)
            try writeLocked(updated)
            byID = updated
        }
    }

    private func orderedLocked(_ drafts: [String: ReviewedBusyDraft]? = nil) -> [ReviewedBusyDraft] {
        (drafts ?? byID).values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    private static func validate(_ draft: ReviewedBusyDraft) throws {
        guard draft.origin == .human,
              draft.sourceKind.isAgent,
              draft.targetKind.isAgent,
              !draft.sourcePaneID.isEmpty,
              !draft.targetPaneID.isEmpty,
              draft.sourcePaneID != draft.targetPaneID,
              !draft.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.sourceWorkspaceID.isEmpty,
              !draft.targetWorkspaceID.isEmpty else {
            throw ReviewedBusyDraftStoreError.invalid("A queued draft needs an exact route between two distinct live agent panes.")
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewedBusyDraftStoreError.invalid("A queued draft cannot be empty.")
        }
        guard draft.text.utf8.count <= ContextPackBuilder.defaultMaximumRenderedBytes else {
            throw ReviewedBusyDraftStoreError.invalid("That reviewed draft is too large to queue.")
        }
    }

    private static func load(file: URL, fileManager: FileManager) throws -> [String: ReviewedBusyDraft] {
        guard fileManager.fileExists(atPath: file.path) else { return [:] }
        try validateExistingFile(file)
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= maximumDocumentBytes,
                  let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == 1,
                  document.drafts.count <= maximumDrafts,
                  Set(document.drafts.map(\.id)).count == document.drafts.count else {
                throw ReviewedBusyDraftStoreError.unreadable("Parley's reviewed busy queue is invalid or unsupported.")
            }
            for draft in document.drafts { try validate(draft) }
            return Dictionary(uniqueKeysWithValues: document.drafts.map { ($0.id, $0) })
        } catch let error as ReviewedBusyDraftStoreError {
            throw error
        } catch {
            throw ReviewedBusyDraftStoreError.unreadable(
                "Parley's reviewed busy queue could not be read: \(error.localizedDescription)"
            )
        }
    }

    private func writeLocked(_ drafts: [String: ReviewedBusyDraft]) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try Self.validateExistingFile(file) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, drafts: orderedLocked(drafts)))
        guard data.count <= Self.maximumDocumentBytes else {
            throw ReviewedBusyDraftStoreError.invalid("Parley's reviewed busy queue reached its 4 MB local safety bound.")
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func validateExistingFile(_ file: URL) throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw ReviewedBusyDraftStoreError.unreadable(
                "Parley's reviewed busy queue is not an owner-only regular file."
            )
        }
    }
}
