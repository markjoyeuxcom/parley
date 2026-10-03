import Darwin
import Foundation

public enum AgentContextReviewState: String, Codable, Equatable, Sendable {
    case draft
    case awaitingReview
    case approved
    case rejected
    case discarded
    case completed
    case failed
    case interrupted

    /// Deletion must not interrupt approval or an approved delivery in flight.
    public var canDelete: Bool { self != .awaitingReview && self != .approved }

    public var needsHumanReview: Bool {
        self == .draft || self == .awaitingReview
    }
}

/// A pane-authored context proposal. Its source identity comes from the pane
/// capability, while file contents and paths remain explicitly labelled as
/// agent-provided until a person reviews and approves the editable pack.
public struct AgentContextReview: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourcePaneID: String
    public let sourcePaneName: String
    public let sourcePaneKind: PaneKind
    public let sourceFolder: String
    public let sourceWorkspaceID: String?
    public let sourceWorkspaceName: String?
    public var pack: ContextPack
    /// For a `parley done --file` return, the exact part as staged. Approval
    /// rebuilds `pack` from the reviewed part set, so this is the only copy
    /// that survives an edit or removal before delivery.
    public var returnedPart: ContextPackPart?
    public var state: AgentContextReviewState
    public var requestedTargetPaneID: String?
    public var requestedTargetName: String?
    public var idempotencyKey: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var detail: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        sourcePaneID: String,
        sourcePaneName: String,
        sourcePaneKind: PaneKind,
        sourceFolder: String,
        pack: ContextPack,
        sourceWorkspaceID: String? = nil,
        sourceWorkspaceName: String? = nil,
        returnedPart: ContextPackPart? = nil,
        state: AgentContextReviewState = .draft,
        requestedTargetPaneID: String? = nil,
        requestedTargetName: String? = nil,
        idempotencyKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        detail: String? = nil
    ) {
        self.id = id
        self.sourcePaneID = sourcePaneID
        self.sourcePaneName = sourcePaneName
        self.sourcePaneKind = sourcePaneKind
        self.sourceFolder = sourceFolder
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceWorkspaceName = sourceWorkspaceName
        self.pack = pack
        self.returnedPart = returnedPart
        self.state = state
        self.requestedTargetPaneID = requestedTargetPaneID
        self.requestedTargetName = requestedTargetName
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourcePaneID, sourcePaneName, sourcePaneKind, sourceFolder, pack, returnedPart, state
        case requestedTargetPaneID, requestedTargetName, idempotencyKey, createdAt, updatedAt, detail
        case sourceWorkspaceID, sourceWorkspaceName
    }

    /// Every review is agent-staged. A record written before packs carried an
    /// origin decodes with the origin its state proves, and says so when the
    /// state proves nothing. None of them is ever the person's own selection.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourcePaneID = try container.decode(String.self, forKey: .sourcePaneID)
        sourcePaneName = try container.decode(String.self, forKey: .sourcePaneName)
        sourcePaneKind = try container.decode(PaneKind.self, forKey: .sourcePaneKind)
        sourceFolder = try container.decode(String.self, forKey: .sourceFolder)
        sourceWorkspaceID = try container.decodeIfPresent(String.self, forKey: .sourceWorkspaceID)
        sourceWorkspaceName = try container.decodeIfPresent(String.self, forKey: .sourceWorkspaceName)
        var decodedPack = try container.decode(ContextPack.self, forKey: .pack)
        let decodedState = try container.decode(AgentContextReviewState.self, forKey: .state)
        let packKeys = try container.nestedContainer(keyedBy: ContextPack.CodingKeys.self, forKey: .pack)
        if !packKeys.contains(.origin) {
            decodedPack.origin = Self.legacyOrigin(for: decodedState)
        }
        pack = decodedPack
        returnedPart = try container.decodeIfPresent(ContextPackPart.self, forKey: .returnedPart)
        state = decodedState
        requestedTargetPaneID = try container.decodeIfPresent(String.self, forKey: .requestedTargetPaneID)
        requestedTargetName = try container.decodeIfPresent(String.self, forKey: .requestedTargetName)
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    /// Recorded links only; a moved or closed pane does not change ownership.
    public func isLinked(to handoff: RelayHandoff) -> Bool {
        if handoff.resultContextReviewID == id { return true }
        if let idempotencyKey, handoff.idempotencyKey == idempotencyKey,
           handoff.sourcePaneID == sourcePaneID { return true }
        return pack.parts.contains {
            $0.source.kind == .handoffResult && $0.source.referenceID == handoff.id
        }
    }

    public func belongs(to workspaceID: String, handoffs: [RelayHandoff]) -> Bool {
        sourceWorkspaceID == workspaceID || handoffs.contains {
            ($0.sourceWorkspaceID == workspaceID || $0.targetWorkspaceID == workspaceID) && isLinked(to: $0)
        }
    }

    /// `approved` is written only by approval and `completed` only after it;
    /// `draft`, `awaitingReview`, `rejected` and `discarded` never passed it.
    /// `failed` is reached both by a timed-out approval wait and by a failed
    /// delivery after approval, and a restart turns both a waiting and an
    /// approved review into `interrupted`, so those two record no approval
    /// status rather than guessing one.
    public static func legacyOrigin(for state: AgentContextReviewState) -> ContextPackOrigin {
        switch state {
        case .approved, .completed: .agentApproved
        case .draft, .awaitingReview, .rejected, .discarded: .agentProposed
        case .failed, .interrupted: .agentApprovalUnrecorded
        }
    }
}

/// Exact native selections, checked together under the broker lock. Pane
/// credentials cannot use the deletion route.
public struct AgentContextDeletion: Codable, Equatable, Sendable {
    public let reviews: [AgentContextDraftDiscard]

    public init(reviews: [AgentContextDraftDiscard]) { self.reviews = reviews }
}

/// The native discard of one editable agent draft: the exact review and the
/// revision the person saw, so a draft that became a waiting Ask or changed in
/// the meantime is refused rather than declined by accident.
public struct AgentContextDraftDiscard: Codable, Equatable, Sendable {
    public let reviewID: String
    public let expectedUpdatedAt: Date

    public init(reviewID: String, expectedUpdatedAt: Date) {
        self.reviewID = reviewID
        self.expectedUpdatedAt = expectedUpdatedAt
    }
}

public struct AgentContextReviewSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let state: AgentContextReviewState
    public let sourceCount: Int
    public let sourceBytes: Int
    public let requestedTargetName: String?
    public let updatedAt: Date

    public init(_ review: AgentContextReview) {
        id = review.id
        name = review.pack.name
        state = review.state
        sourceCount = review.pack.parts.count
        sourceBytes = review.pack.sourceByteCount
        requestedTargetName = review.requestedTargetName
        updatedAt = review.updatedAt
    }
}

public struct AgentContextPartApproval: Codable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Carries only the editable projection back to the core. Captured originals
/// remain authoritative in the core-owned review record and are never trusted
/// back from the UI.
public struct AgentContextReviewApproval: Codable, Equatable, Sendable {
    public let reviewID: String
    public let expectedUpdatedAt: Date
    public let targetPaneID: String
    public let name: String
    public let note: String
    public let parts: [AgentContextPartApproval]
    /// The key the native UI minted for the correlated Ask a direct send
    /// becomes, so it can reveal that exact handoff afterwards. Absent from
    /// older callers and approvals of an agent's own Ask; the core derives one
    /// from the review when it is missing.
    public let idempotencyKey: String?

    public init(
        reviewID: String,
        expectedUpdatedAt: Date,
        targetPaneID: String,
        pack: ContextPack,
        idempotencyKey: String? = nil
    ) {
        self.reviewID = reviewID
        self.expectedUpdatedAt = expectedUpdatedAt
        self.targetPaneID = targetPaneID
        self.name = pack.name
        self.note = pack.note
        self.parts = pack.parts.map { AgentContextPartApproval(id: $0.id, text: $0.text) }
        self.idempotencyKey = idempotencyKey
    }
}

public enum AgentContextTrustedCaptureKind: String, Codable, Equatable, Sendable {
    case files
    case gitDiff
    case visibleTerminal
    case commandResult
    case browserURL
    case browserSelection
    case browserScreenshot
    case toolArtifact
    /// The person's own window capture, already held and written by the app
    /// (`image`), added to an agent's draft.
    case windowCapture
    /// A PNG or JPEG file the person chose with Add Files, already checked,
    /// held and written by the app (`image`); its one path is only a label.
    case imageFile
}

/// A control-token-authorized request for the app-resident core to capture a
/// local source itself. The UI supplies only capture inputs; source identity,
/// captured bytes and the resulting part id are established by the core.
public struct AgentContextTrustedCaptureRequest: Codable, Equatable, Sendable {
    public let reviewID: String
    public let kind: AgentContextTrustedCaptureKind
    public let paths: [String]
    public let paneID: String?
    public let executablePath: String?
    public let arguments: [String]
    public let evidencePaneID: String?
    public let sourceURL: String?
    public let selectedText: String?
    public let image: ContextPackImage?

    public init(
        reviewID: String,
        kind: AgentContextTrustedCaptureKind,
        paths: [String] = [],
        paneID: String? = nil,
        executablePath: String? = nil,
        arguments: [String] = [],
        evidencePaneID: String? = nil,
        sourceURL: String? = nil,
        selectedText: String? = nil,
        image: ContextPackImage? = nil
    ) {
        self.reviewID = reviewID
        self.kind = kind
        self.paths = paths
        self.paneID = paneID
        self.executablePath = executablePath
        self.arguments = arguments
        self.evidencePaneID = evidencePaneID
        self.sourceURL = sourceURL
        self.selectedText = selectedText
        self.image = image
    }
}

public struct AgentContextTrustedCaptureResponse: Codable, Equatable, Sendable {
    public let parts: [ContextPackPart]
    public let reviewUpdatedAt: Date

    public init(parts: [ContextPackPart], reviewUpdatedAt: Date) {
        self.parts = parts
        self.reviewUpdatedAt = reviewUpdatedAt
    }
}

public enum AgentContextReviewStoreError: LocalizedError {
    case unsafeFile
    case invalidDocument
    case tooManyPending

    public var errorDescription: String? {
        switch self {
        case .unsafeFile:
            "Parley's context review store is not a regular owner-controlled file."
        case .invalidDocument:
            "Parley's context review store is invalid or from an unsupported version."
        case .tooManyPending:
            "Parley already has 32 context drafts awaiting review. Resolve one before staging another."
        }
    }
}

/// A small owner-only local store. Pending reviews survive UI and core restarts;
/// a restarted core marks an impossible blocked waiter interrupted rather than
/// pretending the original pane command can still receive an answer.
public final class AgentContextReviewStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let reviews: [AgentContextReview]
    }

    private static let maximumRecords = 100
    private static let maximumPending = 32

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var byID: [String: AgentContextReview]

    public init(file: URL, fileManager: FileManager = .default) throws {
        self.file = file
        self.fileManager = fileManager
        self.byID = try Self.load(file: file, fileManager: fileManager)
    }

    public func reviews() -> [AgentContextReview] {
        lock.withLock {
            byID.values.sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
        }
    }

    /// Returns the reviews the store dropped to stay within its bound, so the
    /// broker can drop them too.
    @discardableResult
    public func record(_ review: AgentContextReview) throws -> Set<String> {
        try lock.withLock {
            let isNewPending = byID[review.id] == nil && review.state.needsHumanReview
            if isNewPending, byID.values.count(where: { $0.state.needsHumanReview }) >= Self.maximumPending {
                throw AgentContextReviewStoreError.tooManyPending
            }
            var proposed = byID
            proposed[review.id] = review
            Self.prune(&proposed)
            try writeLocked(proposed)
            let pruned = Set(byID.keys).union([review.id]).subtracting(proposed.keys)
            byID = proposed
            return pruned
        }
    }

    /// Publish only after the rewritten document is durable. A failed purge
    /// leaves the store's in-memory projection available for retry.
    public func remove(ids: Set<String>) throws {
        try lock.withLock {
            guard !ids.isEmpty else { return }
            let remaining = byID.filter { !ids.contains($0.key) }
            try writeLocked(remaining)
            byID = remaining
        }
    }

    private static func load(file: URL, fileManager: FileManager) throws -> [String: AgentContextReview] {
        guard fileManager.fileExists(atPath: file.path) else { return [:] }
        try validate(file: file)
        guard let document = try? JSONDecoder().decode(Document.self, from: Data(contentsOf: file)),
              document.version == 1,
              Set(document.reviews.map(\.id)).count == document.reviews.count else {
            throw AgentContextReviewStoreError.invalidDocument
        }
        return Dictionary(uniqueKeysWithValues: document.reviews.map { ($0.id, $0) })
    }

    private static func prune(_ records: inout [String: AgentContextReview]) {
        guard records.count > maximumRecords else { return }
        // Never a draft, a waiting Ask or an approved review whose delivery
        // is still in flight: the broker now drops what the store prunes.
        let removable = records.values
            .filter { !$0.state.needsHumanReview && $0.state.canDelete }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt < $1.updatedAt
            }
        for review in removable.prefix(records.count - maximumRecords) {
            records.removeValue(forKey: review.id)
        }
    }

    private func writeLocked(_ records: [String: AgentContextReview]? = nil) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try Self.validate(file: file) }
        let ordered = (records ?? byID).values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, reviews: ordered))
        try OwnerOnlyFile.write(data, to: file, fileManager: fileManager)
        // Rename is the commit point. Permissions and sync already succeeded;
        // no fallible maintenance may report a failed save after this point.
    }

    private static func validate(file: URL) throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw AgentContextReviewStoreError.unsafeFile
        }
    }
}
