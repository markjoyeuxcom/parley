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
    public var pack: ContextPack
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
        self.pack = pack
        self.state = state
        self.requestedTargetPaneID = requestedTargetPaneID
        self.requestedTargetName = requestedTargetName
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.detail = detail
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

    public init(
        reviewID: String,
        expectedUpdatedAt: Date,
        targetPaneID: String,
        pack: ContextPack
    ) {
        self.reviewID = reviewID
        self.expectedUpdatedAt = expectedUpdatedAt
        self.targetPaneID = targetPaneID
        self.name = pack.name
        self.note = pack.note
        self.parts = pack.parts.map { AgentContextPartApproval(id: $0.id, text: $0.text) }
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

    public init(
        reviewID: String,
        kind: AgentContextTrustedCaptureKind,
        paths: [String] = [],
        paneID: String? = nil,
        executablePath: String? = nil,
        arguments: [String] = [],
        evidencePaneID: String? = nil,
        sourceURL: String? = nil,
        selectedText: String? = nil
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

    public func record(_ review: AgentContextReview) throws {
        try lock.withLock {
            let isNewPending = byID[review.id] == nil && review.state.needsHumanReview
            if isNewPending, byID.values.count(where: { $0.state.needsHumanReview }) >= Self.maximumPending {
                throw AgentContextReviewStoreError.tooManyPending
            }
            byID[review.id] = review
            pruneLocked()
            try writeLocked()
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

    private func pruneLocked() {
        guard byID.count > Self.maximumRecords else { return }
        let removable = byID.values
            .filter { !$0.state.needsHumanReview }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt < $1.updatedAt
            }
        for review in removable.prefix(byID.count - Self.maximumRecords) {
            byID.removeValue(forKey: review.id)
        }
    }

    private func writeLocked() throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try Self.validate(file: file) }
        let ordered = byID.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, reviews: ordered)).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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
