import Darwin
import Foundation
import Security

public enum RelayDraft {
    /// Relaying is composition, not transcript trimming. A real selection is
    /// useful context; without one the person starts with an empty editor and
    /// can explicitly insert the visible pane if they want it.
    public static func initialText(selection: String?) -> String {
        guard let selection else { return "" }
        return RelayText.clean(selection)
    }
}

public enum RelayCredentialError: LocalizedError {
    case randomGenerationFailed
    case invalidCredentialFile
    case lockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "Parley could not create a relay credential."
        case .invalidCredentialFile:
            "Parley's relay credential file is invalid."
        case let .lockFailed(detail):
            "Parley could not lock its relay credentials: \(detail)"
        }
    }
}

/// One durable credential per retained agent pane. The credential is the
/// sender identity; a caller never gets to claim which pane it came from.
public final class RelayCredentials: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var byPane: [String: String]

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw RelayCredentialError.invalidCredentialFile
            }
            byPane = decoded
        } else {
            byPane = [:]
        }
    }

    public func token(for paneID: String) throws -> String {
        try lock.withLock {
            try withFileLock {
                try reloadLocked()
                if let existing = byPane[paneID] { return existing }
                let token = try newToken()
                byPane[paneID] = token
                try persistLocked()
                return token
            }
        }
    }

    public func rotate(_ paneID: String) throws -> String {
        try lock.withLock {
            try withFileLock {
                try reloadLocked()
                let token = try newToken()
                byPane[paneID] = token
                try persistLocked()
                return token
            }
        }
    }

    public func paneID(for presented: String) -> String? {
        lock.withLock {
            do {
                return try withFileLock {
                    try reloadLocked()
                    var match: String?
                    for (paneID, token) in byPane where constantTimeEqual(token, presented) {
                        match = paneID
                    }
                    return match
                }
            } catch {
                // Authentication fails closed if the durable credential store
                // cannot be refreshed. Accepting the last in-memory snapshot
                // could revive a token another process has already revoked.
                return nil
            }
        }
    }

    public func forget(_ paneID: String) throws {
        try lock.withLock {
            try withFileLock {
                try reloadLocked()
                guard byPane.removeValue(forKey: paneID) != nil else { return }
                try persistLocked()
            }
        }
    }

    public func retain(paneIDs: Set<String>) throws {
        try lock.withLock {
            try withFileLock {
                try reloadLocked()
                let retained = byPane.filter { paneIDs.contains($0.key) }
                guard retained.count != byPane.count else { return }
                byPane = retained
                try persistLocked()
            }
        }
    }

    public func allTokens() throws -> [String] {
        try lock.withLock {
            try withFileLock {
                try reloadLocked()
                return Array(byPane.values)
            }
        }
    }

    private func reloadLocked() throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            byPane = [:]
            return
        }
        let data = try Data(contentsOf: file)
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw RelayCredentialError.invalidCredentialFile
        }
        byPane = decoded
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = file.path + ".lock"
        // O_EXLOCK acquires a process-wide advisory lock as part of open and
        // holds it until close, avoiding a Swift name collision between the
        // flock(2) function and Darwin's `flock` structure.
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_EXLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RelayCredentialError.lockFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        return try operation()
    }

    private func persistLocked() throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(byPane)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RelayCredentialError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ known: String, _ presented: String) -> Bool {
        let left = Array(known.utf8)
        let right = Array(presented.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }
}

public struct RelayRuntime: Sendable {
    public let infoFile: URL
    public let shimDirectory: URL
    public let transportDirectory: URL
    public let credentials: RelayCredentials
    public let runtimeMarker: String?

    public init(
        infoFile: URL,
        shimDirectory: URL,
        transportDirectory: URL,
        credentials: RelayCredentials,
        runtimeMarker: String? = nil
    ) {
        self.infoFile = infoFile
        self.shimDirectory = shimDirectory
        self.transportDirectory = transportDirectory
        self.credentials = credentials
        self.runtimeMarker = runtimeMarker
    }
}

public struct RelayResponseBody: Codable, Equatable, Sendable {
    public let ok: Bool
    public let delivered: String?
    public let submitted: Bool?
    public let note: String?
    public let error: String?
    public let handoffID: String?
    public let state: RelayHandoffState?

    public init(
        ok: Bool,
        delivered: String?,
        submitted: Bool?,
        note: String?,
        error: String?,
        handoffID: String? = nil,
        state: RelayHandoffState? = nil
    ) {
        self.ok = ok
        self.delivered = delivered
        self.submitted = submitted
        self.note = note
        self.error = error
        self.handoffID = handoffID
        self.state = state
    }
}

public struct RelayResponse: Equatable, Sendable {
    public let status: Int
    public let body: RelayResponseBody
}

public struct RelayTextResponse: Equatable, Sendable {
    public let status: Int
    public let text: String

    public init(status: Int, text: String) {
        self.status = status
        self.text = text
    }
}

public struct RelayAskManyAnswer: Codable, Equatable, Sendable {
    public let requestedTarget: String
    public let targetPaneID: String
    public let targetName: String
    public let handoffID: String?
    public let status: Int
    public let answer: String?
    public let error: String?

    public init(
        requestedTarget: String,
        targetPaneID: String,
        targetName: String,
        handoffID: String? = nil,
        status: Int,
        answer: String?,
        error: String?
    ) {
        self.requestedTarget = requestedTarget
        self.targetPaneID = targetPaneID
        self.targetName = targetName
        self.handoffID = handoffID
        self.status = status
        self.answer = answer
        self.error = error
    }
}

public struct RelayAskManyBundle: Codable, Equatable, Sendable {
    public let ok: Bool
    public let answers: [RelayAskManyAnswer]

    public init(ok: Bool, answers: [RelayAskManyAnswer]) {
        self.ok = ok
        self.answers = answers
    }
}

public enum RelayHandoffKind: String, Codable, Equatable, Sendable {
    case relay
    case paste
    case ask
    case delegate
}

public enum RelayHandoffState: String, Codable, Equatable, Sendable {
    case created
    case delivered
    case waiting
    case answered
    case completed
    case cancelled
    case failed
    case interrupted
}

public enum RelayRetryDisposition: String, Codable, Equatable, Sendable {
    /// Parley knows the writer failed before terminal input began.
    case safe
    /// Terminal input may have started, so retrying could duplicate text.
    case uncertain
    /// The operation cannot be meaningfully resumed from the activity UI.
    case unsupported
}

public enum RelayAttention: String, Codable, Equatable, Sendable {
    case targetNotReady
    case permissionRequired
    case targetUnavailable
}

public enum RelayTransitionOrigin: String, Codable, Equatable, Sendable {
    case human
}

public enum RelayActivityEventKind: String, Codable, Equatable, Sendable {
    case paneRestarted
    case paneReaped
    case workspaceCreated
    case workspaceClosed
    case workspaceRestored
    case recipeSubmitted
    case recipeInterrupted
    case comparisonForwarded
}

/// A successful operation initiated from Parley's native controls. These are
/// deliberately separate from handoffs: restarting a pane or opening a saved
/// layout is not a relay transition and must not be presented as one.
public struct RelayActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: RelayActivityEventKind
    public let occurredAt: Date
    public let workspaceID: String
    public let workspaceName: String
    public let paneID: String?
    public let paneName: String?
    public let paneKind: PaneKind?
    public let detail: String?
    public let origin: RelayTransitionOrigin

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: RelayActivityEventKind,
        occurredAt: Date = Date(),
        workspaceID: String,
        workspaceName: String,
        paneID: String? = nil,
        paneName: String? = nil,
        paneKind: PaneKind? = nil,
        detail: String? = nil,
        origin: RelayTransitionOrigin = .human
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.paneID = paneID
        self.paneName = paneName
        self.paneKind = paneKind
        self.detail = detail
        self.origin = origin
    }
}

/// The UI supplies only facts it learned from a successful native operation.
/// Identity, time and human origin are stamped by the app-resident core.
public struct RelayActivityEventRequest: Codable, Equatable, Sendable {
    public let kind: RelayActivityEventKind
    public let workspaceID: String
    public let workspaceName: String
    public let paneID: String?
    public let paneName: String?
    public let paneKind: PaneKind?
    public let detail: String?

    public init(
        kind: RelayActivityEventKind,
        workspaceID: String,
        workspaceName: String,
        paneID: String? = nil,
        paneName: String? = nil,
        paneKind: PaneKind? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.paneID = paneID
        self.paneName = paneName
        self.paneKind = paneKind
        self.detail = detail
    }
}

public enum RelayActivityError: LocalizedError {
    case invalidEvent

    public var errorDescription: String? {
        switch self {
        case .invalidEvent:
            "Parley activity needs a workspace id and name."
        }
    }
}

public struct RelayHandoffTransition: Codable, Equatable, Sendable {
    public let state: RelayHandoffState
    public let occurredAt: Date
    public let detail: String?
    public let origin: RelayTransitionOrigin?

    public init(
        state: RelayHandoffState,
        occurredAt: Date,
        detail: String?,
        origin: RelayTransitionOrigin? = nil
    ) {
        self.state = state
        self.occurredAt = occurredAt
        self.detail = detail
        self.origin = origin
    }
}

public struct RelayHandoff: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let idempotencyKey: String
    public let kind: RelayHandoffKind
    public let sourcePaneID: String
    public let sourceName: String
    public let sourceKind: PaneKind?
    public let sourceWorkspaceID: String
    public let sourceWorkspaceName: String?
    public let targetPaneID: String
    public let targetName: String
    public let targetKind: PaneKind?
    public let targetWorkspaceID: String
    public let targetWorkspaceName: String?
    public let text: String
    public let submitted: Bool
    public var resultText: String?
    public var readAt: Date? = nil
    public var state: RelayHandoffState
    public var updatedAt: Date
    public var transitions: [RelayHandoffTransition]
    public var retryDisposition: RelayRetryDisposition? = nil
    public var attention: RelayAttention? = nil

    public var canRetrySafely: Bool {
        state == .failed
            && retryDisposition == .safe
            && (kind == .relay || kind == .paste)
    }

    public var hasReturnedResult: Bool {
        (kind == .ask || kind == .delegate)
            && !(resultText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public var hasUnreadResult: Bool {
        hasReturnedResult && readAt == nil
    }
}

public enum RelayConsultationState: String, Codable, Equatable, Sendable {
    case awaitingAnswer
}

/// A single correlated question from one live agent pane to another. It is
/// intentionally owned by the app-resident core's memory: a window may hide, but
/// the waiting shell command and socket cannot survive a core restart. A
/// restart interrupts the caller explicitly instead of reviving half a route.
public struct RelayConsultation: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourcePaneID: String
    public let sourceName: String
    public let targetPaneID: String
    public let targetName: String
    public let question: String
    public let state: RelayConsultationState
    public let createdAt: Date
}

/// The machine-readable projection returned by `parley status`. It contains
/// only work initiated by the authenticated pane; credentials and terminal control
/// details never cross the broker boundary.
public struct RelayDelegationStatus: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourcePaneID: String
    public let sourceName: String
    public let targetPaneID: String
    public let targetName: String
    public let task: String
    public let state: RelayHandoffState
    public let resultText: String?
    public let createdAt: Date
    public let updatedAt: Date

    fileprivate init(handoff: RelayHandoff) {
        id = handoff.id
        sourcePaneID = handoff.sourcePaneID
        sourceName = handoff.sourceName
        targetPaneID = handoff.targetPaneID
        targetName = handoff.targetName
        task = handoff.text
        state = handoff.state
        resultText = handoff.resultText
        createdAt = handoff.transitions.first?.occurredAt ?? handoff.updatedAt
        updatedAt = handoff.updatedAt
    }
}

public final class RelayBroker: @unchecked Sendable {
    public typealias Panes = () throws -> [WorkbenchPane]
    public typealias Paste = (_ paneID: String, _ text: String) throws -> Void
    public typealias Submit = (_ paneID: String, _ text: String) throws -> Void
    public typealias DirectContextSubmit = (_ sourcePaneID: String, _ targetPaneID: String, _ text: String) throws -> Void
    public typealias SelectedText = (_ paneID: String) throws -> String

    private static let abandonedContextDraftLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let credentials: RelayCredentials
    private let panes: Panes
    private let paste: Paste
    private let submit: Submit
    private let contextSubmit: Submit
    private let directContextSubmit: DirectContextSubmit
    private let selectedText: SelectedText?
    private let consultationTimeout: TimeInterval
    private let livenessPollInterval: TimeInterval
    private let handoffJournal: RelayHandoffJournal?
    private let activityJournal: RelayActivityJournal?
    private let historyRetentionStore: CollaborationHistoryRetentionStore?
    private let contextReviewStore: AgentContextReviewStore?
    private let busyDraftStore: ReviewedBusyDraftStore?
    private let contextPackBuilder = ContextPackBuilder()
    private let consultationCondition = NSCondition()
    private var consultationRecords: [String: ConsultationRecord] = [:]
    /// In-memory only: a persisted `.dispatching` draft after restart is an
    /// uncertain record that the person may dismiss, while an entry here is
    /// actively crossing the terminal-submission boundary and cannot be
    /// truthfully described as discarded.
    private var busyDraftDispatches: Set<String> = []
    private var delegationRecords: [String: DelegationRecord] = [:]
    private var delegationResponses: [String: RelayTextResponse] = [:]
    private var handoffRecords: [String: RelayHandoff] = [:]
    private var activityRecords: [String: RelayActivityEvent] = [:]
    private var historyRetentionPolicy: CollaborationHistoryRetentionPolicy
    private var contextReviewRecords: [String: AgentContextReview] = [:]
    private var idempotencyRecords: [IdempotencyScope: IdempotencyRecord] = [:]

    public init(
        credentials: RelayCredentials,
        panes: @escaping Panes,
        paste: @escaping Paste,
        submit: @escaping Submit,
        contextSubmit: Submit? = nil,
        directContextSubmit: DirectContextSubmit? = nil,
        selectedText: SelectedText? = nil,
        consultationTimeout: TimeInterval = 30 * 60,
        livenessPollInterval: TimeInterval = 0.5,
        handoffJournal: RelayHandoffJournal? = nil,
        activityJournal: RelayActivityJournal? = nil,
        historyRetentionPolicy: CollaborationHistoryRetentionPolicy = .defaultPolicy,
        historyRetentionStore: CollaborationHistoryRetentionStore? = nil,
        contextReviewStore: AgentContextReviewStore? = nil,
        busyDraftStore: ReviewedBusyDraftStore? = nil
    ) {
        self.credentials = credentials
        self.panes = panes
        self.paste = paste
        self.submit = submit
        self.contextSubmit = contextSubmit ?? submit
        self.directContextSubmit = directContextSubmit ?? { _, targetPaneID, text in
            try (contextSubmit ?? submit)(targetPaneID, text)
        }
        self.selectedText = selectedText
        self.consultationTimeout = consultationTimeout
        self.livenessPollInterval = max(0.01, livenessPollInterval)
        self.handoffJournal = handoffJournal
        self.activityJournal = activityJournal
        self.historyRetentionPolicy = historyRetentionPolicy
        self.historyRetentionStore = historyRetentionStore
        self.contextReviewStore = contextReviewStore
        self.busyDraftStore = busyDraftStore

        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        var recovered = Dictionary(uniqueKeysWithValues: (handoffJournal?.handoffs() ?? []).map { ($0.id, $0) })
        for (id, var handoff) in recovered where !terminalStates.contains(handoff.state) {
            let now = Date()
            let reason = "Parley core restarted before this handoff reached a terminal state."
            handoff.state = .interrupted
            handoff.updatedAt = now
            handoff.transitions.append(RelayHandoffTransition(state: .interrupted, occurredAt: now, detail: reason))
            recovered[id] = handoff
            handoffJournal?.record(handoff)
        }
        handoffRecords = recovered
        activityRecords = Dictionary(uniqueKeysWithValues: (activityJournal?.events() ?? []).map { ($0.id, $0) })
        var recoveredContext = Dictionary(
            uniqueKeysWithValues: (contextReviewStore?.reviews() ?? []).map { ($0.id, $0) }
        )
        let recoveredAt = Date()
        for (id, var review) in recoveredContext
        where review.state == .draft
            && recoveredAt.timeIntervalSince(review.updatedAt) >= Self.abandonedContextDraftLifetime {
            review.state = .discarded
            review.updatedAt = recoveredAt
            review.detail = "Parley discarded this editable draft after seven days without review activity."
            recoveredContext[id] = review
            try? contextReviewStore?.record(review)
        }
        for (id, var review) in recoveredContext where review.state == .awaitingReview || review.state == .approved {
            review.state = .interrupted
            review.updatedAt = recoveredAt
            review.detail = "Parley core restarted before the reviewed context Ask completed."
            recoveredContext[id] = review
            try? contextReviewStore?.record(review)
        }
        contextReviewRecords = recoveredContext
        pruneHandoffsLocked()
    }

    public func handleContextDraft(
        token: String,
        name suppliedName: String,
        path suppliedPath: String,
        text: String
    ) -> RelayTextResponse {
        do {
            guard contextReviewStore != nil else {
                throw BrokerFailure(status: 503, message: "context review storage is unavailable")
            }
            let sender = try authenticatedSender(token: token)
            let name = suppliedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 80 else { throw BrokerFailure(status: 400, message: "context name is too long") }
            let path = try normalizedAgentContextPath(suppliedPath, cwd: sender.cwd)
            let normalized = ContextPackText.normalize(text)
            guard !normalized.isEmpty else { throw BrokerFailure(status: 400, message: "the context file is empty") }
            guard normalized.utf8.count <= ContextPackBuilder.defaultMaximumPartBytes else {
                throw BrokerFailure(status: 413, message: "the context file is too large")
            }
            let part = ContextPackPart(
                source: ContextPackSource(
                    kind: .agentFileDraft,
                    label: URL(fileURLWithPath: path).lastPathComponent,
                    detail: "\(path) · provided by \(sender.displayName); not independently read by Parley"
                ),
                capturedText: normalized
            )
            let pack = ContextPack(
                name: name.isEmpty ? "\(sender.displayName) context" : name,
                parts: [part]
            )
            _ = try contextPackBuilder.render(pack)
            let review = AgentContextReview(
                sourcePaneID: sender.id,
                sourcePaneName: sender.displayName,
                sourcePaneKind: sender.kind,
                sourceFolder: sender.cwd,
                pack: pack
            )
            try recordContextReview(review)
            return encodeContext(review, status: 201)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func handleContextAdd(
        token: String,
        draftID: String,
        path suppliedPath: String,
        text: String
    ) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            let path = try normalizedAgentContextPath(suppliedPath, cwd: sender.cwd)
            let normalized = ContextPackText.normalize(text)
            guard !normalized.isEmpty else { throw BrokerFailure(status: 400, message: "the context file is empty") }
            guard normalized.utf8.count <= ContextPackBuilder.defaultMaximumPartBytes else {
                throw BrokerFailure(status: 413, message: "the context file is too large")
            }
            consultationCondition.lock()
            guard var review = contextReviewRecords[draftID],
                  review.sourcePaneID == sender.id,
                  review.state == .draft else {
                consultationCondition.unlock()
                throw BrokerFailure(status: 404, message: "no editable context draft named \(draftID)")
            }
            review.pack.parts.append(ContextPackPart(
                source: ContextPackSource(
                    kind: .agentFileDraft,
                    label: URL(fileURLWithPath: path).lastPathComponent,
                    detail: "\(path) · provided by \(sender.displayName); not independently read by Parley"
                ),
                capturedText: normalized
            ))
            do {
                _ = try contextPackBuilder.render(review.pack)
                review.updatedAt = Date()
                try contextReviewStore?.record(review)
                contextReviewRecords[review.id] = review
                consultationCondition.broadcast()
                consultationCondition.unlock()
            } catch {
                consultationCondition.unlock()
                throw error
            }
            return encodeContext(review)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func contextDrafts(token: String) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            consultationCondition.lock()
            let records = contextReviewRecords.values
                .filter { $0.sourcePaneID == sender.id }
                .sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                    return $0.updatedAt > $1.updatedAt
                }
                .map(AgentContextReviewSummary.init)
            consultationCondition.unlock()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return RelayTextResponse(status: 200, text: String(decoding: try encoder.encode(records), as: UTF8.self))
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func contextDraft(token: String, draftID: String) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            consultationCondition.lock()
            guard let review = contextReviewRecords[draftID], review.sourcePaneID == sender.id else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 404, text: "unknown context draft")
            }
            consultationCondition.unlock()
            let rendered = try contextPackBuilder.render(review.pack)
            return RelayTextResponse(
                status: 200,
                text: "Context review state: \(review.state.rawValue)\nReview id: \(review.id)\n\n\(rendered)"
            )
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func discardContextDraft(token: String, draftID: String) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            consultationCondition.lock()
            guard var review = contextReviewRecords[draftID], review.sourcePaneID == sender.id else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 404, text: "unknown context draft")
            }
            guard review.state.needsHumanReview else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "that context draft is no longer awaiting review")
            }
            review.state = .discarded
            review.updatedAt = Date()
            review.detail = "The source pane discarded this context draft."
            do {
                try contextReviewStore?.record(review)
                contextReviewRecords[review.id] = review
            } catch {
                consultationCondition.unlock()
                throw error
            }
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return RelayTextResponse(status: 200, text: review.detail ?? "Context draft discarded.")
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func captureTrustedContext(_ request: AgentContextTrustedCaptureRequest) -> RelayTextResponse {
        do {
            consultationCondition.lock()
            guard let original = contextReviewRecords[request.reviewID], original.state.needsHumanReview else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "that context draft is not awaiting review")
            }
            let sourceFolder = original.sourceFolder
            let existingPartCount = original.pack.parts.count
            consultationCondition.unlock()

            let captured: [ContextPackPart]
            func evidencePane() throws -> WorkbenchPane {
                guard let paneID = request.evidencePaneID,
                      let pane = try panes().first(where: {
                          $0.id == paneID && $0.kind.isAgent && $0.isStarted && !$0.isDead
                      }) else {
                    throw BrokerFailure(status: 409, message: "that vendor pane is no longer available for evidence attribution")
                }
                return pane
            }
            switch request.kind {
            case .files:
                guard !request.paths.isEmpty,
                      request.paths.count <= ContextPackBuilder.maximumParts - existingPartCount,
                      request.paneID == nil,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      request.evidencePaneID == nil,
                      request.sourceURL == nil,
                      request.selectedText == nil else {
                    throw BrokerFailure(status: 400, message: "invalid trusted file capture request")
                }
                captured = try request.paths.map {
                    try contextPackBuilder.file(at: URL(fileURLWithPath: $0))
                }
            case .gitDiff:
                guard request.paths.isEmpty,
                      request.paneID == nil,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      request.evidencePaneID == nil,
                      request.sourceURL == nil,
                      request.selectedText == nil else {
                    throw BrokerFailure(status: 400, message: "invalid trusted Git capture request")
                }
                captured = [try contextPackBuilder.gitDiff(in: sourceFolder)]
            case .visibleTerminal:
                guard request.paths.isEmpty,
                      let paneID = request.paneID,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      request.evidencePaneID == nil,
                      request.sourceURL == nil,
                      request.selectedText == nil,
                      let selectedText else {
                    throw BrokerFailure(status: 400, message: "invalid trusted terminal-selection capture request")
                }
                guard let pane = try panes().first(where: {
                    $0.id == paneID && $0.isStarted && !$0.isDead
                }) else {
                    throw BrokerFailure(status: 409, message: "that pane is no longer available for terminal-selection capture")
                }
                captured = [try contextPackBuilder.terminalSelection(
                    paneID: pane.id,
                    paneName: pane.displayName,
                    text: try selectedText(pane.id)
                )]
            case .commandResult:
                guard request.paths.isEmpty,
                      request.paneID == nil,
                      let executablePath = request.executablePath,
                      request.evidencePaneID == nil,
                      request.sourceURL == nil,
                      request.selectedText == nil else {
                    throw BrokerFailure(status: 400, message: "invalid trusted command capture request")
                }
                captured = [try contextPackBuilder.commandResult(
                    executablePath: executablePath,
                    arguments: request.arguments,
                    workingDirectory: URL(fileURLWithPath: sourceFolder, isDirectory: true)
                )]
            case .browserURL:
                guard request.paths.isEmpty,
                      request.paneID == nil,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      let sourceURL = request.sourceURL,
                      request.selectedText == nil else {
                    throw BrokerFailure(status: 400, message: "invalid browser URL evidence request")
                }
                captured = [try contextPackBuilder.browserURLEvidence(
                    from: evidencePane(),
                    url: sourceURL
                )]
            case .browserSelection:
                guard request.paths.isEmpty,
                      request.paneID == nil,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      let sourceURL = request.sourceURL,
                      let selectedText = request.selectedText else {
                    throw BrokerFailure(status: 400, message: "invalid browser selection evidence request")
                }
                captured = [try contextPackBuilder.browserSelectionEvidence(
                    from: evidencePane(),
                    url: sourceURL,
                    text: selectedText
                )]
            case .browserScreenshot, .toolArtifact:
                guard request.paths.count == 1,
                      request.paneID == nil,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      request.selectedText == nil else {
                    throw BrokerFailure(status: 400, message: "invalid local vendor artifact evidence request")
                }
                captured = [try contextPackBuilder.vendorArtifactEvidence(
                    kind: request.kind == .browserScreenshot ? .browserScreenshot : .savedArtifact,
                    from: evidencePane(),
                    file: URL(fileURLWithPath: request.paths[0]),
                    sourceURL: request.sourceURL
                )]
            }

            consultationCondition.lock()
            guard var review = contextReviewRecords[request.reviewID],
                  review.state.needsHumanReview,
                  review.sourceFolder == sourceFolder else {
                consultationCondition.unlock()
                return RelayTextResponse(
                    status: 409,
                    text: "the context draft changed while the trusted source was being captured; nothing was added"
                )
            }
            review.pack.parts.append(contentsOf: captured)
            do {
                _ = try contextPackBuilder.render(review.pack)
                review.updatedAt = Date()
                review.detail = "A person added \(captured.count) source\(captured.count == 1 ? "" : "s") through Parley's authenticated review control; each part states what Parley independently established."
                try contextReviewStore?.record(review)
                contextReviewRecords[review.id] = review
                consultationCondition.broadcast()
                consultationCondition.unlock()
            } catch {
                consultationCondition.unlock()
                throw error
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return RelayTextResponse(
                status: 200,
                text: String(decoding: try encoder.encode(
                    AgentContextTrustedCaptureResponse(
                        parts: captured,
                        reviewUpdatedAt: review.updatedAt
                    )
                ), as: UTF8.self)
            )
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func handleContextAsk(
        token: String,
        draftID: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil
    ) -> RelayTextResponse {

        let sender: WorkbenchPane
        let target: WorkbenchPane
        let idempotencyKey: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            try authorize(.ask, for: sender)
            idempotencyKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            let request = ContextPackText.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { throw BrokerFailure(status: 400, message: "nothing to ask with this context") }

            consultationCondition.lock()
            guard var review = contextReviewRecords[draftID], review.sourcePaneID == sender.id else {
                consultationCondition.unlock()
                throw BrokerFailure(status: 404, message: "unknown context draft")
            }
            if review.state == .awaitingReview {
                guard review.idempotencyKey == idempotencyKey,
                      review.requestedTargetPaneID == target.id else {
                    consultationCondition.unlock()
                    throw BrokerFailure(status: 409, message: "that context draft already has a different Ask awaiting review")
                }
            } else {
                guard review.state == .draft else {
                    consultationCondition.unlock()
                    throw BrokerFailure(status: 409, message: "that context draft is no longer available for a new Ask")
                }
                review.pack.note = request
                do {
                    _ = try contextPackBuilder.render(review.pack)
                } catch {
                    consultationCondition.unlock()
                    throw error
                }
                review.state = .awaitingReview
                review.requestedTargetPaneID = target.id
                review.requestedTargetName = target.displayName
                review.idempotencyKey = idempotencyKey
                review.updatedAt = Date()
                review.detail = "Waiting for a person to review and approve this context Ask."
                do {
                    try contextReviewStore?.record(review)
                    contextReviewRecords[review.id] = review
                } catch {
                    consultationCondition.unlock()
                    throw error
                }
                consultationCondition.broadcast()
            }

            let deadline = Date().addingTimeInterval(consultationTimeout)
            while contextReviewRecords[draftID]?.state == .awaitingReview {
                if !consultationCondition.wait(until: deadline) {
                    if var expired = contextReviewRecords[draftID], expired.state == .awaitingReview {
                        expired.state = .failed
                        expired.updatedAt = Date()
                        expired.detail = "Context review timed out before approval."
                        contextReviewRecords[draftID] = expired
                        try? contextReviewStore?.record(expired)
                    }
                    consultationCondition.unlock()
                    return RelayTextResponse(status: 408, text: "context review timed out before approval")
                }
            }
            guard let reviewed = contextReviewRecords[draftID] else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "context review disappeared before approval")
            }
            guard reviewed.state == .approved else {
                let detail = reviewed.detail ?? "The person declined this context Ask."
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: detail)
            }
            let rendered: String
            do {
                rendered = try contextPackBuilder.render(reviewed.pack)
            } catch {
                consultationCondition.unlock()
                throw error
            }
            let approvedTarget = reviewed.requestedTargetPaneID ?? target.id
            consultationCondition.unlock()

            let response = handleAsk(
                token: token,
                target: approvedTarget,
                text: rendered,
                idempotencyKey: idempotencyKey,
                humanInitiated: true,
                preserveFormatting: true
            )
            finishContextReview(draftID, response: response)
            return response
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func contextReviews() -> [AgentContextReview] {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        return contextReviewRecords.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func approveContextReview(
        reviewID: String,
        pack: ContextPack,
        targetPaneID: String
    ) -> RelayTextResponse {
        consultationCondition.lock()
        guard let expectedUpdatedAt = contextReviewRecords[reviewID]?.updatedAt else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown context review")
        }
        consultationCondition.unlock()
        return approveContextReview(AgentContextReviewApproval(
            reviewID: reviewID,
            expectedUpdatedAt: expectedUpdatedAt,
            targetPaneID: targetPaneID,
            pack: pack
        ))
    }

    public func approveContextReview(_ approval: AgentContextReviewApproval) -> RelayTextResponse {
        do {
            let livePanes = try panes()
            consultationCondition.lock()
            guard var review = contextReviewRecords[approval.reviewID], review.state == .awaitingReview else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "that context Ask is not awaiting review")
            }
            guard let source = livePanes.first(where: { $0.id == review.sourcePaneID }),
                  let target = livePanes.first(where: { $0.id == approval.targetPaneID }),
                  source.kind.isAgent,
                  target.kind.isAgent,
                  source.id != target.id else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "the reviewed source or selected target pane is no longer available")
            }
            let pack: ContextPack
            do {
                pack = try reviewedContextPackLocked(approval, review: review)
                let request = pack.note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !request.isEmpty else {
                    throw BrokerFailure(status: 400, message: "the reviewed pack needs a request")
                }
                _ = try contextPackBuilder.render(pack)
            } catch {
                consultationCondition.unlock()
                throw error
            }
            review.pack = pack
            review.state = .approved
            review.requestedTargetPaneID = target.id
            review.requestedTargetName = target.displayName
            review.updatedAt = Date()
            review.detail = "Approved by the person using Parley."
            do {
                try contextReviewStore?.record(review)
                contextReviewRecords[review.id] = review
            } catch {
                consultationCondition.unlock()
                throw error
            }
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return RelayTextResponse(status: 200, text: "Context Ask approved; the waiting pane will submit it now.")
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func completeContextDraft(_ approval: AgentContextReviewApproval) -> RelayTextResponse {
        do {
            let livePanes = try panes()
            let prepared: (source: WorkbenchPane, target: WorkbenchPane, rendered: String)
            consultationCondition.lock()
            guard var review = contextReviewRecords[approval.reviewID], review.state == .draft else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "that context draft is not awaiting a person's direct send")
            }
            guard let source = livePanes.first(where: { $0.id == review.sourcePaneID }),
                  let target = livePanes.first(where: { $0.id == approval.targetPaneID }),
                  source.kind.isAgent,
                  target.kind.isAgent,
                  source.id != target.id else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "the reviewed source or selected target pane is no longer available")
            }
            let pack: ContextPack
            do {
                pack = try reviewedContextPackLocked(approval, review: review)
                prepared = (source, target, try contextPackBuilder.render(pack))
            } catch {
                consultationCondition.unlock()
                throw error
            }
            review.pack = pack
            review.state = .approved
            review.requestedTargetPaneID = target.id
            review.requestedTargetName = target.displayName
            review.updatedAt = Date()
            review.detail = "Direct context delivery was approved by the person using Parley."
            do {
                try contextReviewStore?.record(review)
                contextReviewRecords[review.id] = review
            } catch {
                consultationCondition.unlock()
                throw error
            }
            consultationCondition.broadcast()
            consultationCondition.unlock()

            do {
                try directContextSubmit(prepared.source.id, prepared.target.id, prepared.rendered)
            } catch {
                let detail = "Context delivery failed: \(error.localizedDescription). Check the target before retrying."
                consultationCondition.lock()
                if var failed = contextReviewRecords[approval.reviewID] {
                    failed.state = .failed
                    failed.updatedAt = Date()
                    failed.detail = detail
                    contextReviewRecords[failed.id] = failed
                    try? contextReviewStore?.record(failed)
                }
                consultationCondition.broadcast()
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: detail)
            }

            consultationCondition.lock()
            guard var completed = contextReviewRecords[approval.reviewID], completed.state == .approved else {
                consultationCondition.unlock()
                return RelayTextResponse(
                    status: 202,
                    text: "Context was delivered, but its durable review changed unexpectedly. Do not resend it."
                )
            }
            completed.state = .completed
            completed.updatedAt = Date()
            completed.detail = "Reviewed and sent directly by the person using Parley."
            contextReviewRecords[completed.id] = completed
            do {
                try contextReviewStore?.record(completed)
                consultationCondition.broadcast()
                consultationCondition.unlock()
                return RelayTextResponse(status: 200, text: completed.detail ?? "Context draft sent.")
            } catch {
                let detail = "Context was delivered to \(prepared.target.displayName), but Parley could not persist its completion: \(error.localizedDescription). Do not resend it."
                completed.detail = detail
                contextReviewRecords[completed.id] = completed
                consultationCondition.broadcast()
                consultationCondition.unlock()
                return RelayTextResponse(status: 202, text: detail)
            }
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func rejectContextReview(reviewID: String) -> RelayTextResponse {
        consultationCondition.lock()
        guard var review = contextReviewRecords[reviewID], review.state.needsHumanReview else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "that context draft is not awaiting review")
        }
        let wasAwaitingAsk = review.state == .awaitingReview
        review.state = wasAwaitingAsk ? .rejected : .discarded
        review.updatedAt = Date()
        review.detail = wasAwaitingAsk
            ? "The person declined this context Ask."
            : "The person discarded this context draft."
        do {
            try contextReviewStore?.record(review)
            contextReviewRecords[review.id] = review
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
        consultationCondition.broadcast()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: review.detail ?? "Context draft declined.")
    }

    private func finishContextReview(_ reviewID: String, response: RelayTextResponse) {
        consultationCondition.lock()
        guard var review = contextReviewRecords[reviewID] else {
            consultationCondition.unlock()
            return
        }
        review.state = (200..<300).contains(response.status) ? .completed : .failed
        review.updatedAt = Date()
        review.detail = response.text
        contextReviewRecords[review.id] = review
        try? contextReviewStore?.record(review)
        consultationCondition.broadcast()
        consultationCondition.unlock()
    }

    /// The caller must hold consultationCondition from reading `review`
    /// through committing its state transition. That makes the editable
    /// projection and the mutation one transaction with respect to add,
    /// discard, timeout and competing approval.
    private func reviewedContextPackLocked(
        _ approval: AgentContextReviewApproval,
        review: AgentContextReview
    ) throws -> ContextPack {
        guard approval.expectedUpdatedAt == review.updatedAt else {
            throw BrokerFailure(
                status: 409,
                message: "the context draft changed after this preview opened; reopen it and review the latest sources"
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: review.pack.parts.map { ($0.id, $0) })
        let suppliedIDs = approval.parts.map(\.id)
        guard Set(suppliedIDs).count == suppliedIDs.count,
              !suppliedIDs.isEmpty,
              suppliedIDs.allSatisfy({ byID[$0] != nil }) else {
            throw BrokerFailure(status: 400, message: "the reviewed context parts do not match the staged draft")
        }
        let parts = approval.parts.compactMap { decision in
            byID[decision.id]?.replacingText(decision.text)
        }
        return ContextPack(
            id: review.pack.id,
            name: approval.name,
            note: approval.note,
            parts: parts
        )
    }

    private func recordContextReview(_ review: AgentContextReview) throws {
        try contextReviewStore?.record(review)
        consultationCondition.lock()
        contextReviewRecords[review.id] = review
        consultationCondition.broadcast()
        consultationCondition.unlock()
    }

    private func encodeContext(_ review: AgentContextReview, status: Int = 200) -> RelayTextResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(AgentContextReviewSummary(review)) else {
            return RelayTextResponse(status: 500, text: "could not encode context review")
        }
        return RelayTextResponse(status: status, text: String(decoding: data, as: UTF8.self))
    }

    private func authenticatedSender(token: String) throws -> WorkbenchPane {
        guard let senderID = credentials.paneID(for: token) else {
            throw BrokerFailure(status: 401, message: "bad token")
        }
        guard let sender = try panes().first(where: { $0.id == senderID }), sender.kind.isAgent else {
            throw BrokerFailure(status: 400, message: "unknown sender pane")
        }
        return sender
    }

    private func normalizedAgentContextPath(_ supplied: String, cwd: String) throws -> String {
        let path = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.contains("\0") else {
            throw BrokerFailure(status: 400, message: "context draft needs a valid file path")
        }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = (path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: path, relativeTo: root))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw BrokerFailure(
                status: 403,
                message: "agent context files must stay inside the pane folder \(root.path)"
            )
        }
        return candidate.path
    }

    public func handle(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey: String? = nil
    ) -> RelayResponse {
        return deliver(
            token: token,
            target: requestedTarget,
            text: text,
            kind: .relay,
            submitted: true,
            idempotencyKey: idempotencyKey,
            writer: submit
        )
    }

    public func handlePaste(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey: String? = nil
    ) -> RelayResponse {
        return deliver(
            token: token,
            target: requestedTarget,
            text: text,
            kind: .paste,
            submitted: false,
            idempotencyKey: idempotencyKey,
            writer: paste
        )
    }

    private func deliver(
        token: String,
        target requestedTarget: String,
        text: String,
        kind: RelayHandoffKind,
        submitted: Bool,
        idempotencyKey suppliedIdempotencyKey: String?,
        writer: (_ paneID: String, _ text: String) throws -> Void
    ) -> RelayResponse {
        do {
            let cleaned = RelayText.clean(text)
            guard !cleaned.isEmpty else { return failure(400, "nothing to relay") }
            guard cleaned.count <= RelayText.maximumCharacters else {
                return failure(400, "text too long")
            }
            let (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            try authorize(kind, for: sender)
            let idempotencyKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            let scope = IdempotencyScope(senderPaneID: sender.id, key: idempotencyKey)
            let signature = [kind.rawValue, target.id, cleaned].joined(separator: "\u{1f}")

            consultationCondition.lock()
            if let existing = idempotencyRecords[scope] {
                guard existing.signature == signature else {
                    consultationCondition.unlock()
                    return failure(409, "that idempotency key belongs to a different handoff")
                }
                let deadline = Date().addingTimeInterval(15)
                while idempotencyRecords[scope]?.response == nil {
                    if !consultationCondition.wait(until: deadline) { break }
                }
                let response = idempotencyRecords[scope]?.response
                consultationCondition.unlock()
                if case let .delivery(cached)? = response { return cached }
                return failure(409, "the handoff is still being delivered")
            }

            let handoff = makeHandoff(
                idempotencyKey: idempotencyKey,
                kind: kind,
                sender: sender,
                target: target,
                text: cleaned,
                submitted: submitted
            )
            handoffRecords[handoff.id] = handoff
            handoffJournal?.record(handoff)
            idempotencyRecords[scope] = IdempotencyRecord(
                signature: signature,
                handoffID: handoff.id,
                response: nil
            )
            consultationCondition.broadcast()
            consultationCondition.unlock()

            do {
                try writer(target.id, "\(sender.displayName) said:\n\n\(cleaned)")
                consultationCondition.lock()
                transitionHandoffLocked(handoff.id, to: .delivered)
                transitionHandoffLocked(handoff.id, to: .completed)
                let response = RelayResponse(
                    status: 200,
                    body: RelayResponseBody(
                        ok: true,
                        delivered: target.displayName,
                        submitted: submitted,
                        note: submitted
                            ? "Submitted to \(target.displayName)."
                            : "Pasted into the prompt and NOT sent. The person there presses Enter.",
                        error: nil,
                        handoffID: handoff.id,
                        state: .completed
                    )
                )
                idempotencyRecords[scope]?.response = .delivery(response)
                pruneHandoffsLocked()
                consultationCondition.broadcast()
                consultationCondition.unlock()
                return response
            } catch {
                let assessment = failureAssessment(kind: kind, error: error)
                consultationCondition.lock()
                transitionHandoffLocked(
                    handoff.id,
                    to: .failed,
                    detail: error.localizedDescription,
                    failure: assessment
                )
                let response = failure(
                    409,
                    error.localizedDescription,
                    handoffID: handoff.id,
                    state: .failed
                )
                idempotencyRecords[scope]?.response = .delivery(response)
                pruneHandoffsLocked()
                consultationCondition.broadcast()
                consultationCondition.unlock()
                return response
            }
        } catch let error as BrokerFailure {
            return failure(error.status, error.message)
        } catch {
            return failure(409, error.localizedDescription)
        }
    }

    /// Starts agent-to-agent work without blocking the initiating command. The
    /// exact target owns the terminal result, while status and wait remain
    /// scoped to the initiating pane's authenticated identity.
    public func handleDelegate(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil
    ) -> RelayResponse {
        let sender: WorkbenchPane
        let target: WorkbenchPane
        let idempotencyKey: String
        let targetCredential: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            try authorize(.delegate, for: sender)
            idempotencyKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            targetCredential = try credentials.token(for: target.id)
        } catch let error as BrokerFailure {
            return failure(error.status, error.message)
        } catch {
            return failure(409, error.localizedDescription)
        }

        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else { return failure(400, "nothing to delegate") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return failure(400, "delegated task too long")
        }

        let scope = IdempotencyScope(senderPaneID: sender.id, key: idempotencyKey)
        let signature = [RelayHandoffKind.delegate.rawValue, target.id, cleaned].joined(separator: "\u{1f}")

        consultationCondition.lock()
        if let existing = idempotencyRecords[scope] {
            guard existing.signature == signature else {
                consultationCondition.unlock()
                return failure(409, "that idempotency key belongs to a different handoff")
            }
            let deadline = Date().addingTimeInterval(15)
            while idempotencyRecords[scope]?.response == nil {
                if !consultationCondition.wait(until: deadline) { break }
            }
            let response = idempotencyRecords[scope]?.response
            consultationCondition.unlock()
            if case let .delivery(cached)? = response { return cached }
            return failure(409, "the delegated task is still being delivered")
        }
        if targetHasTrackedWorkLocked(target.id) {
            consultationCondition.unlock()
            return failure(409, "\(target.displayName) already has tracked work awaiting a result.")
        }

        let handoff = makeHandoff(
            idempotencyKey: idempotencyKey,
            kind: .delegate,
            sender: sender,
            target: target,
            text: cleaned,
            submitted: true
        )
        handoffRecords[handoff.id] = handoff
        handoffJournal?.record(handoff)
        idempotencyRecords[scope] = IdempotencyRecord(
            signature: signature,
            handoffID: handoff.id,
            response: nil
        )
        delegationRecords[handoff.id] = DelegationRecord(
            sourceCredential: token,
            targetCredential: targetCredential
        )
        consultationCondition.broadcast()
        consultationCondition.unlock()

        do {
            try submit(target.id, delegationPrompt(for: handoff))
            consultationCondition.lock()
            if delegationRecords[handoff.id] != nil {
                transitionHandoffLocked(handoff.id, to: .delivered)
                transitionHandoffLocked(handoff.id, to: .waiting)
            }
            let observedState = handoffRecords[handoff.id]?.state ?? .failed
            let response = RelayResponse(
                status: 200,
                body: RelayResponseBody(
                    ok: true,
                    delivered: target.displayName,
                    submitted: true,
                    note: "Delegated to \(target.displayName). Track it with `parley status` or wait with `parley wait \(handoff.id)`.",
                    error: nil,
                    handoffID: handoff.id,
                    state: observedState
                )
            )
            idempotencyRecords[scope]?.response = .delivery(response)
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return response
        } catch {
            let response = failure(
                409,
                "Parley could not submit the delegated task: \(error.localizedDescription)",
                handoffID: handoff.id,
                state: .failed
            )
            consultationCondition.lock()
            transitionHandoffLocked(
                handoff.id,
                to: .failed,
                detail: response.body.error,
                failure: failureAssessment(kind: .delegate, error: error)
            )
            delegationRecords.removeValue(forKey: handoff.id)
            idempotencyRecords[scope]?.response = .delivery(response)
            pruneHandoffsLocked()
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return response
        }
    }

    public func handleDelegationResult(
        token: String,
        handoffID requestedHandoffID: String,
        text: String,
        succeeded: Bool
    ) -> RelayTextResponse {
        guard let senderID = credentials.paneID(for: token) else {
            return RelayTextResponse(status: 401, text: "bad token")
        }
        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else {
            return RelayTextResponse(status: 400, text: succeeded ? "nothing to report as done" : "nothing to report as failed")
        }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: "delegation result too long")
        }

        consultationCondition.lock()
        let handoffID: String
        if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
            let matches = delegationRecords.keys.filter { handoffRecords[$0]?.targetPaneID == senderID }
            guard matches.count == 1, let match = matches.first else {
                consultationCondition.unlock()
                return RelayTextResponse(
                    status: matches.isEmpty ? 404 : 409,
                    text: matches.isEmpty
                        ? "this pane has no delegated work awaiting a result"
                        : "this pane has more than one delegated item awaiting a result"
                )
            }
            handoffID = match
        } else {
            handoffID = requestedHandoffID
        }
        guard let record = delegationRecords[handoffID], let handoff = handoffRecords[handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown active delegation")
        }
        guard handoff.targetPaneID == senderID else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the delegated target pane can report this result")
        }
        guard record.targetCredential == token else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this delegation belongs to an earlier run of the target pane")
        }
        if var updated = handoffRecords[handoffID] {
            updated.resultText = cleaned
            handoffRecords[handoffID] = updated
        }
        if succeeded {
            transitionHandoffLocked(handoffID, to: .completed, detail: cleaned)
            delegationResponses[handoffID] = RelayTextResponse(status: 200, text: cleaned)
        } else {
            transitionHandoffLocked(
                handoffID,
                to: .failed,
                detail: cleaned,
                failure: RelayFailureAssessment(retryDisposition: .unsupported, attention: nil)
            )
            delegationResponses[handoffID] = RelayTextResponse(status: 409, text: cleaned)
        }
        delegationRecords.removeValue(forKey: handoffID)
        pruneHandoffsLocked()
        consultationCondition.broadcast()
        consultationCondition.unlock()
        return RelayTextResponse(
            status: 200,
            text: succeeded
                ? "Completion returned to \(handoff.sourceName)."
                : "Failure returned to \(handoff.sourceName)."
        )
    }

    public func delegationStatus(token: String) -> RelayTextResponse {
        guard let sourceID = credentials.paneID(for: token) else {
            return RelayTextResponse(status: 401, text: "bad token")
        }
        reconcileDelegations()
        consultationCondition.lock()
        let statuses = handoffRecords.values
            .filter { $0.kind == .delegate && $0.sourcePaneID == sourceID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(RelayDelegationStatus.init)
        consultationCondition.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(statuses) else {
            return RelayTextResponse(status: 500, text: "could not encode delegation status")
        }
        return RelayTextResponse(status: 200, text: String(decoding: data, as: UTF8.self))
    }

    public func waitForDelegation(token: String, handoffID requestedHandoffID: String) -> RelayTextResponse {
        guard let sourceID = credentials.paneID(for: token) else {
            return RelayTextResponse(status: 401, text: "bad token")
        }

        consultationCondition.lock()
        let handoffID: String
        if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
            let matches = delegationRecords.keys.filter { handoffRecords[$0]?.sourcePaneID == sourceID }
            guard matches.count == 1, let match = matches.first else {
                consultationCondition.unlock()
                return RelayTextResponse(
                    status: matches.isEmpty ? 404 : 409,
                    text: matches.isEmpty
                        ? "this pane has no active delegated work"
                        : "this pane has more than one active delegation; name its id"
                )
            }
            handoffID = match
        } else {
            handoffID = requestedHandoffID
        }
        guard let original = handoffRecords[handoffID], original.kind == .delegate else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown delegation")
        }
        guard original.sourcePaneID == sourceID else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the initiating pane can wait for this delegation")
        }
        consultationCondition.unlock()

        while true {
            reconcileDelegation(handoffID)
            consultationCondition.lock()
            guard let handoff = handoffRecords[handoffID] else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 404, text: "unknown delegation")
            }
            if let response = delegationResponses[handoffID] ?? delegationWaitResponse(for: handoff) {
                consultationCondition.unlock()
                return response
            }
            _ = consultationCondition.wait(until: Date().addingTimeInterval(livenessPollInterval))
            consultationCondition.unlock()
        }
    }

    /// Submits one attributed question, then waits until its exact target
    /// returns an answer. Unlike relay, Ask also owns the response route.
    public func handleAsk(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil
    ) -> RelayTextResponse {
        handleAsk(
            token: token,
            target: requestedTarget,
            text: text,
            idempotencyKey: suppliedIdempotencyKey,
            humanInitiated: false,
            preserveFormatting: false
        )
    }

    private func handleAsk(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String?,
        humanInitiated: Bool,
        preserveFormatting: Bool,
        onSubmitted: (() -> Void)? = nil
    ) -> RelayTextResponse {
        let sender: WorkbenchPane
        let target: WorkbenchPane
        let idempotencyKey: String
        let targetCredential: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            if !humanInitiated {
                try authorize(.ask, for: sender)
            }
            idempotencyKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            targetCredential = try credentials.token(for: target.id)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        let cleaned = preserveFormatting
            ? ContextPackText.normalize(text)
            : RelayText.clean(text)
        guard !cleaned.isEmpty else { return RelayTextResponse(status: 400, text: "nothing to ask") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: "question too long")
        }

        let scope = IdempotencyScope(senderPaneID: sender.id, key: idempotencyKey)
        let signature = [RelayHandoffKind.ask.rawValue, target.id, cleaned].joined(separator: "\u{1f}")

        consultationCondition.lock()
        if let existing = idempotencyRecords[scope] {
            guard existing.signature == signature else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "that idempotency key belongs to a different handoff")
            }
            let handoffID = existing.handoffID
            consultationCondition.unlock()
            return waitForAskResponse(scope: scope, handoffID: handoffID, targetName: target.displayName)
        }
        if consultationRecords.values.contains(where: {
            $0.consultation.targetPaneID == target.id && $0.completion == nil
        }) {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "\(target.displayName) already has a consultation awaiting an answer."
            )
        }
        if delegationRecords.keys.contains(where: { handoffRecords[$0]?.targetPaneID == target.id }) {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "\(target.displayName) already has tracked work awaiting a result."
            )
        }

        let handoff = makeHandoff(
            idempotencyKey: idempotencyKey,
            kind: .ask,
            sender: sender,
            target: target,
            text: cleaned,
            submitted: true,
            origin: humanInitiated ? .human : nil
        )
        let consultation = RelayConsultation(
            id: handoff.id,
            sourcePaneID: sender.id,
            sourceName: sender.displayName,
            targetPaneID: target.id,
            targetName: target.displayName,
            question: cleaned,
            state: .awaitingAnswer,
            createdAt: Date()
        )
        handoffRecords[handoff.id] = handoff
        handoffJournal?.record(handoff)
        idempotencyRecords[scope] = IdempotencyRecord(
            signature: signature,
            handoffID: handoff.id,
            response: nil
        )
        consultationRecords[consultation.id] = ConsultationRecord(
            consultation: consultation,
            completion: nil,
            idempotencyScope: scope,
            sourceCredential: token,
            targetCredential: targetCredential
        )
        consultationCondition.broadcast()
        consultationCondition.unlock()

        do {
            let writer = preserveFormatting ? contextSubmit : submit
            try writer(target.id, consultationPrompt(for: consultation))
            consultationCondition.lock()
            transitionHandoffLocked(handoff.id, to: .delivered, origin: humanInitiated ? .human : nil)
            transitionHandoffLocked(handoff.id, to: .waiting, origin: humanInitiated ? .human : nil)
            onSubmitted?()
            consultationCondition.broadcast()
            consultationCondition.unlock()
        } catch {
            let response = RelayTextResponse(
                status: 409,
                text: "Parley could not submit the question: \(error.localizedDescription)"
            )
            consultationCondition.lock()
            transitionHandoffLocked(
                handoff.id,
                to: .failed,
                detail: response.text,
                failure: failureAssessment(kind: .ask, error: error),
                origin: humanInitiated ? .human : nil
            )
            idempotencyRecords[scope]?.response = .ask(response)
            consultationRecords.removeValue(forKey: consultation.id)
            pruneHandoffsLocked()
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return response
        }

        return waitForAskResponse(scope: scope, handoffID: handoff.id, targetName: target.displayName)
    }

    /// Asks an explicit comma-separated set of distinct agent panes the same
    /// question concurrently. Every target receives only the human-authored
    /// question; answers are collected by the caller and never relayed between
    /// respondents. Static routing is validated for the entire set before the
    /// first consultation is dispatched.
    public func handleAskMany(
        token: String,
        targets requestedTargets: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil
    ) -> RelayTextResponse {
        handleAskMany(
            token: token,
            targets: requestedTargets,
            text: text,
            idempotencyKey: suppliedIdempotencyKey,
            humanInitiated: false,
            preserveFormatting: false
        )
    }

    private func handleAskMany(
        token: String,
        targets requestedTargets: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String?,
        humanInitiated: Bool,
        preserveFormatting: Bool
    ) -> RelayTextResponse {
        let cleaned = preserveFormatting
            ? ContextPackText.normalize(text)
            : RelayText.clean(text)
        guard !cleaned.isEmpty else { return RelayTextResponse(status: 400, text: "nothing to ask") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: "question too long")
        }

        let targets = requestedTargets
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard targets.count >= 2 else {
            return RelayTextResponse(status: 400, text: "ask-many needs at least two comma-separated targets")
        }
        guard targets.count <= 8 else {
            return RelayTextResponse(status: 400, text: "ask-many accepts at most eight targets")
        }
        guard targets.allSatisfy({ !$0.isEmpty }) else {
            return RelayTextResponse(status: 400, text: "ask-many contains an empty target")
        }

        let rootKey: String
        var routes: [(requested: String, pane: WorkbenchPane)] = []
        var sourcePaneID: String?
        do {
            rootKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            for requested in targets {
                let (sender, target) = try route(token: token, requestedTarget: requested)
                sourcePaneID = sourcePaneID ?? sender.id
                if !humanInitiated {
                    try authorize(.ask, for: sender)
                }
                _ = try credentials.token(for: target.id)
                if routes.contains(where: { $0.pane.id == target.id }) {
                    throw BrokerFailure(status: 400, message: "ask-many names \(target.displayName) more than once")
                }
                routes.append((requested, target))
            }
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        guard let sourcePaneID else {
            return RelayTextResponse(status: 400, text: "ask-many could not resolve its source pane")
        }
        let accumulator = AskManyAccumulator(count: routes.count)
        let group = DispatchGroup()
        for (index, route) in routes.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                let childKey = askManyChildKey(root: rootKey, targetPaneID: route.pane.id)
                let response = handleAsk(
                    token: token,
                    target: route.pane.id,
                    text: cleaned,
                    idempotencyKey: childKey,
                    humanInitiated: humanInitiated,
                    preserveFormatting: preserveFormatting
                )
                consultationCondition.lock()
                let handoffID = idempotencyRecords[
                    IdempotencyScope(senderPaneID: sourcePaneID, key: childKey)
                ]?.handoffID
                consultationCondition.unlock()
                let succeeded = (200..<300).contains(response.status)
                accumulator.set(
                    RelayAskManyAnswer(
                        requestedTarget: route.requested,
                        targetPaneID: route.pane.id,
                        targetName: route.pane.displayName,
                        handoffID: handoffID,
                        status: response.status,
                        answer: succeeded ? response.text : nil,
                        error: succeeded ? nil : response.text
                    ),
                    at: index
                )
            }
        }
        group.wait()

        let answers = accumulator.values
        let bundle = RelayAskManyBundle(
            ok: answers.count == routes.count && answers.allSatisfy { (200..<300).contains($0.status) },
            answers: answers
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(bundle) else {
            return RelayTextResponse(status: 500, text: "could not encode ask-many response")
        }
        return RelayTextResponse(
            status: bundle.ok ? 200 : 409,
            text: String(decoding: data, as: UTF8.self)
        )
    }

    /// The native UI owns the core-control capability, not a pane credential.
    /// Resolve the chosen live source to its existing credential internally so
    /// the ordinary Ask-many authorization, liveness and journal path remains
    /// the only implementation. The credential never leaves the core.
    public func handleAskManyFromUI(
        sourcePaneID: String,
        targetPaneIDs: [String],
        text: String,
        idempotencyKey: String? = nil,
        preserveFormatting: Bool = false
    ) -> RelayTextResponse {
        let livePanes: [WorkbenchPane]
        do {
            livePanes = try panes()
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
        guard let source = livePanes.first(where: { $0.id == sourcePaneID }), source.kind.isAgent else {
            return RelayTextResponse(status: 400, text: "unknown source agent pane")
        }
        guard targetPaneIDs.count >= 2 else {
            return RelayTextResponse(status: 400, text: "native comparison needs at least two selected panes")
        }
        let sourceToken: String
        do {
            sourceToken = try credentials.token(for: source.id)
        } catch {
            return RelayTextResponse(status: 409, text: "could not resolve the source pane credential: \(error.localizedDescription)")
        }
        return handleAskMany(
            token: sourceToken,
            targets: targetPaneIDs.joined(separator: ","),
            text: text,
            idempotencyKey: idempotencyKey,
            humanInitiated: true,
            preserveFormatting: preserveFormatting
        )
    }

    /// The native UI may repeat one historical Ask only through the same
    /// authenticated, journalled broker path as an agent Ask. The fresh
    /// idempotency key creates a new handoff identity; no historical record is
    /// mutated and the source pane's credential never leaves the core.
    public func handleAskFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false
    ) -> RelayTextResponse {
        let livePanes: [WorkbenchPane]
        do {
            livePanes = try panes()
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
        guard let source = livePanes.first(where: { $0.id == sourcePaneID }), source.kind.isAgent else {
            return RelayTextResponse(status: 400, text: "unknown source agent pane")
        }
        let sourceToken: String
        do {
            sourceToken = try credentials.token(for: source.id)
        } catch {
            return RelayTextResponse(status: 409, text: "could not resolve the source pane credential: \(error.localizedDescription)")
        }
        return handleAsk(
            token: sourceToken,
            target: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            humanInitiated: true,
            preserveFormatting: preserveFormatting
        )
    }

    /// Returns the exact durable reviewed drafts. Merely reading this list—or
    /// observing that a target is now idle—has no dispatch side effect.
    public func reviewedBusyDrafts() -> [ReviewedBusyDraft] {
        busyDraftStore?.drafts() ?? []
    }

    /// Holds a person-reviewed Ask only while the exact target has active
    /// tracked work. This core-control path never writes to a terminal.
    public func enqueueReviewedBusyAskFromUI(
        _ request: ReviewedBusyDraftCreateRequest
    ) -> RelayTextResponse {
        guard let busyDraftStore else {
            return RelayTextResponse(status: 503, text: "reviewed busy-queue storage is unavailable")
        }
        let source: WorkbenchPane
        let target: WorkbenchPane
        do {
            let sourceToken = try credentials.token(for: request.sourcePaneID)
            (source, target) = try route(token: sourceToken, requestedTarget: request.targetPaneID)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        let normalized = request.preserveFormatting
            ? ContextPackText.normalize(request.text)
            : RelayText.clean(request.text)
        guard !normalized.isEmpty else {
            return RelayTextResponse(status: 400, text: "nothing to queue")
        }
        guard normalized.utf8.count <= ContextPackBuilder.defaultMaximumRenderedBytes else {
            return RelayTextResponse(status: 413, text: "reviewed draft is too large to queue")
        }

        consultationCondition.lock()
        let targetIsBusy = targetHasTrackedWorkLocked(target.id)
        consultationCondition.unlock()
        guard targetIsBusy else {
            return RelayTextResponse(
                status: 409,
                text: "\(target.displayName) is no longer busy. Review and send this Ask directly instead of queueing it."
            )
        }

        let now = Date()
        let draft = ReviewedBusyDraft(
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceKind: source.kind,
            sourceWorkspaceID: source.workspaceID,
            sourceWorkspaceName: source.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.workspaceID,
            targetWorkspaceName: target.workspaceName,
            text: normalized,
            preserveFormatting: request.preserveFormatting,
            createdAt: now,
            updatedAt: now,
            detail: "Held because \(target.displayName) already had tracked work. Becoming idle will not send it."
        )
        do {
            try busyDraftStore.record(draft)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return RelayTextResponse(
                status: 201,
                text: String(decoding: try encoder.encode(draft), as: UTF8.self)
            )
        } catch let error as ReviewedBusyDraftStoreError {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        } catch {
            return RelayTextResponse(status: 500, text: error.localizedDescription)
        }
    }

    /// Dispatches only after a fresh native Review and Send action. The draft
    /// is removed at the exact point terminal submission succeeds; before that
    /// point any busy-route race restores it to the visible unsent queue.
    public func sendReviewedBusyAskFromUI(
        _ request: ReviewedBusyDraftSendRequest
    ) -> RelayTextResponse {
        guard let busyDraftStore,
              let existing = busyDraftStore.draft(id: request.draftID) else {
            return RelayTextResponse(status: 404, text: "unknown reviewed busy-queue draft")
        }
        let sourceToken: String
        do {
            sourceToken = try credentials.token(for: existing.sourcePaneID)
            let (source, target) = try route(token: sourceToken, requestedTarget: existing.targetPaneID)
            guard source.id == existing.sourcePaneID, target.id == existing.targetPaneID else {
                throw BrokerFailure(status: 409, message: "the queued draft's original route is no longer available")
            }
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        let normalized = request.preserveFormatting
            ? ContextPackText.normalize(request.text)
            : RelayText.clean(request.text)
        let dispatching: ReviewedBusyDraft
        consultationCondition.lock()
        if targetHasTrackedWorkLocked(existing.targetPaneID) {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "\(existing.targetName) still has tracked work. The reviewed draft remains queued and unsent."
            )
        }
        if busyDraftDispatches.contains(existing.id) {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this reviewed draft already has an explicit send in progress")
        }
        do {
            dispatching = try busyDraftStore.beginExplicitSend(
                id: request.draftID,
                expectedUpdatedAt: request.expectedUpdatedAt,
                text: normalized,
                preserveFormatting: request.preserveFormatting
            )
            busyDraftDispatches.insert(dispatching.id)
            consultationCondition.unlock()
        } catch let error as ReviewedBusyDraftStoreError {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(status: 500, text: error.localizedDescription)
        }
        defer {
            consultationCondition.lock()
            busyDraftDispatches.remove(dispatching.id)
            consultationCondition.unlock()
        }

        var submitted = false
        let response = handleAsk(
            token: sourceToken,
            target: dispatching.targetPaneID,
            text: dispatching.text,
            idempotencyKey: "busy-draft-\(dispatching.id)-\(UUID().uuidString.lowercased())",
            humanInitiated: true,
            preserveFormatting: dispatching.preserveFormatting,
            onSubmitted: {
                submitted = true
                try? busyDraftStore.remove(id: dispatching.id)
            }
        )
        if !submitted {
            try? busyDraftStore.restoreQueued(
                id: dispatching.id,
                detail: "The explicit send did not reach terminal submission: \(response.text)"
            )
        }
        return response
    }

    public func cancelReviewedBusyDraftFromUI(_ draftID: String) -> RelayTextResponse {
        guard let busyDraftStore else {
            return RelayTextResponse(status: 404, text: "unknown reviewed busy-queue draft")
        }
        consultationCondition.lock()
        if busyDraftDispatches.contains(draftID) {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "this reviewed draft has an explicit send in progress and cannot be discarded"
            )
        }
        guard let draft = busyDraftStore.draft(id: draftID) else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown reviewed busy-queue draft")
        }
        do {
            try busyDraftStore.remove(id: draftID)
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 200,
                text: draft.state == .queued
                    ? "Reviewed draft discarded without sending."
                    : "Uncertain send record dismissed. This does not cancel or reverse any terminal input that may already have occurred."
            )
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(status: 500, text: error.localizedDescription)
        }
    }

    public func handleAnswer(token: String, consultationID: String, text: String) -> RelayTextResponse {
        guard let senderID = credentials.paneID(for: token) else {
            return RelayTextResponse(status: 401, text: "bad token")
        }
        let resolvedID: String
        if consultationID.caseInsensitiveCompare("current") == .orderedSame {
            consultationCondition.lock()
            let matches = consultationRecords.values.filter {
                $0.consultation.targetPaneID == senderID && $0.completion == nil
            }
            consultationCondition.unlock()
            guard matches.count == 1, let match = matches.first else {
                return RelayTextResponse(
                    status: matches.isEmpty ? 404 : 409,
                    text: matches.isEmpty
                        ? "this pane has no consultation awaiting an answer"
                        : "this pane has more than one waiting consultation"
                )
            }
            resolvedID = match.consultation.id
        } else {
            resolvedID = consultationID
        }
        return acceptAnswer(
            from: senderID,
            presentedCredential: token,
            consultationID: resolvedID,
            text: text
        )
    }

    /// Human fallback for an agent that printed its answer but failed to invoke
    /// `parley answer`. Completing the waiting command is safe: this writes no
    /// terminal input and starts no command in another pane.
    public func answerFromUI(consultationID: String, text: String) -> RelayTextResponse {
        consultationCondition.lock()
        let targetID = consultationRecords[consultationID]?.consultation.targetPaneID
        consultationCondition.unlock()
        guard let targetID else { return RelayTextResponse(status: 404, text: "unknown consultation") }
        return acceptAnswer(
            from: targetID,
            presentedCredential: nil,
            consultationID: consultationID,
            text: text,
            origin: .human
        )
    }

    public func consultations() -> [RelayConsultation] {
        consultationCondition.lock()
        let values = consultationRecords.values
            .filter { $0.completion == nil }
            .map(\.consultation)
            .sorted { $0.createdAt < $1.createdAt }
        consultationCondition.unlock()
        return values
    }

    public func handoffs(limit: Int? = nil) -> [RelayHandoff] {
        reconcileDelegations()
        consultationCondition.lock()
        let values = handoffRecords.values.sorted { $0.updatedAt > $1.updatedAt }
        consultationCondition.unlock()
        guard let limit else { return values }
        return Array(values.prefix(max(0, limit)))
    }

    public func unreadHandoffs() -> [RelayHandoff] {
        reconcileDelegations()
        consultationCondition.lock()
        let values = handoffRecords.values
            .filter(\.hasUnreadResult)
            .sorted { $0.updatedAt > $1.updatedAt }
        consultationCondition.unlock()
        return values
    }

    public func activityEvents(limit: Int? = nil) -> [RelayActivityEvent] {
        consultationCondition.lock()
        let values = activityRecords.values.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt > $1.occurredAt
        }
        consultationCondition.unlock()
        guard let limit else { return values }
        return Array(values.prefix(max(0, limit)))
    }

    @discardableResult
    public func recordActivity(_ request: RelayActivityEventRequest) throws -> RelayActivityEvent {
        let workspaceID = request.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceName = request.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty, !workspaceName.isEmpty else { throw RelayActivityError.invalidEvent }
        let event = RelayActivityEvent(
            kind: request.kind,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            paneID: request.paneID,
            paneName: request.paneName,
            paneKind: request.paneKind,
            detail: request.detail
        )
        try activityJournal?.record(event)
        consultationCondition.lock()
        activityRecords[event.id] = event
        if let retainedIDs = activityJournal.map({ Set($0.events().map(\.id)) }) {
            activityRecords = activityRecords.filter { retainedIDs.contains($0.key) }
        } else {
            pruneActivityRecordsLocked()
        }
        consultationCondition.unlock()
        return event
    }

    public func collaborationHistoryRetentionPolicy() -> CollaborationHistoryRetentionPolicy {
        consultationCondition.lock()
        let policy = historyRetentionPolicy
        consultationCondition.unlock()
        return policy
    }

    /// Saves the core-owned policy, compacts both owner-only journals, then
    /// reconciles the live projections. Active handoffs remain even when they
    /// temporarily put the projection above the selected bound.
    public func updateCollaborationHistoryRetention(
        maximumRecords: Int
    ) throws -> CollaborationHistoryRetentionChange {
        let policy = try CollaborationHistoryRetentionPolicy(maximumRecords: maximumRecords)
        try historyRetentionStore?.save(policy)
        let durableHandoffRemoval = try handoffJournal?.updateMaximumHandoffs(maximumRecords)
        let durableActivityRemoval = try activityJournal?.updateMaximumEvents(maximumRecords)

        consultationCondition.lock()
        let handoffCountBefore = handoffRecords.count
        let activityCountBefore = activityRecords.count
        historyRetentionPolicy = policy
        if let retainedIDs = handoffJournal.map({ Set($0.handoffs().map(\.id)) }) {
            handoffRecords = handoffRecords.filter { retainedIDs.contains($0.key) }
        } else {
            pruneHandoffsLocked()
        }
        if let retainedIDs = activityJournal.map({ Set($0.events().map(\.id)) }) {
            activityRecords = activityRecords.filter { retainedIDs.contains($0.key) }
        } else {
            pruneActivityRecordsLocked()
        }
        let removedHandoffIDs = Set(idempotencyRecords.values.compactMap { record in
            handoffRecords[record.handoffID] == nil ? record.handoffID : nil
        })
        idempotencyRecords = idempotencyRecords.filter { !removedHandoffIDs.contains($0.value.handoffID) }
        delegationResponses = delegationResponses.filter { handoffRecords[$0.key] != nil }
        let inMemoryHandoffRemoval = handoffCountBefore - handoffRecords.count
        let inMemoryActivityRemoval = activityCountBefore - activityRecords.count
        consultationCondition.broadcast()
        consultationCondition.unlock()

        return CollaborationHistoryRetentionChange(
            policy: policy,
            removedHandoffs: durableHandoffRemoval ?? inMemoryHandoffRemoval,
            removedActivityEvents: durableActivityRemoval ?? inMemoryActivityRemoval
        )
    }

    /// Records that a person viewed a returned Ask or Delegate result. This is
    /// exposed only through the UI control-token route; pane credentials cannot
    /// clear another pane's badge. Repeated acknowledgement is intentionally
    /// idempotent and does not reorder the handoff's operational timeline.
    public func markHandoffRead(_ handoffID: String) -> RelayTextResponse {
        consultationCondition.lock()
        guard var handoff = handoffRecords[handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        guard handoff.hasReturnedResult else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this handoff has no returned result")
        }
        if handoff.readAt == nil {
            handoff.readAt = Date()
            handoffRecords[handoffID] = handoff
            handoffJournal?.record(handoff)
        }
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Result marked read.")
    }

    /// Deletes only terminal collaboration history involving one workspace.
    /// Active Ask and Delegate records remain authoritative and are never
    /// removed by history maintenance.
    public func deleteWorkspaceHistory(
        workspaceID: String,
        workspaceName: String? = nil
    ) -> RelayTextResponse {
        let requestedID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestedID.isEmpty || !requestedName.isEmpty else {
            return RelayTextResponse(status: 400, text: "workspace id or name is required")
        }

        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        consultationCondition.lock()
        let removalIDs = Set(handoffRecords.values.lazy.filter { handoff in
            guard terminalStates.contains(handoff.state) else { return false }
            let idMatches = !requestedID.isEmpty
                && (handoff.sourceWorkspaceID == requestedID || handoff.targetWorkspaceID == requestedID)
            let nameMatches = requestedID.isEmpty
                && !requestedName.isEmpty
                && [handoff.sourceWorkspaceName, handoff.targetWorkspaceName]
                .compactMap { $0 }
                .contains { $0.caseInsensitiveCompare(requestedName) == .orderedSame }
            return idMatches || nameMatches
        }.map(\.id))

        let activityRemovalIDs = Set(activityRecords.values.lazy.filter { event in
            let idMatches = !requestedID.isEmpty && event.workspaceID == requestedID
            let nameMatches = requestedID.isEmpty
                && !requestedName.isEmpty
                && event.workspaceName.caseInsensitiveCompare(requestedName) == .orderedSame
            return idMatches || nameMatches
        }.map(\.id))

        do {
            try handoffJournal?.removeHandoffs(ids: removalIDs)
            try activityJournal?.removeEvents(ids: activityRemovalIDs)
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 500,
                text: "Parley could not delete workspace history: \(error.localizedDescription)"
            )
        }
        handoffRecords = handoffRecords.filter { !removalIDs.contains($0.key) }
        idempotencyRecords = idempotencyRecords.filter { !removalIDs.contains($0.value.handoffID) }
        delegationResponses = delegationResponses.filter { !removalIDs.contains($0.key) }
        activityRecords = activityRecords.filter { !activityRemovalIDs.contains($0.key) }
        consultationCondition.unlock()

        let removedCount = removalIDs.count + activityRemovalIDs.count
        let noun = removedCount == 1 ? "record" : "records"
        return RelayTextResponse(status: 200, text: "Deleted \(removedCount) workspace history \(noun).")
    }

    /// Human control-token cancellation. This ends Parley's tracking only; the
    /// UI separately owns any explicit choice to interrupt the target process.
    public func cancelHandoff(
        _ handoffID: String,
        reason: String = "Cancelled by the person using Parley."
    ) -> RelayTextResponse {
        cancelHandoff(handoffID, reason: reason, origin: .human)
    }

    /// Pane-scoped cancellation for work initiated by that exact pane. It can
    /// never interrupt the target CLI and cannot cancel another pane's work.
    public func cancelHandoff(token: String, handoffID requestedHandoffID: String) -> RelayTextResponse {
        guard let sourceID = credentials.paneID(for: token) else {
            return RelayTextResponse(status: 401, text: "bad token")
        }
        consultationCondition.lock()
        let active = handoffRecords.values.filter {
            $0.sourcePaneID == sourceID
                && ($0.kind == .ask || $0.kind == .delegate)
                && [.created, .delivered, .waiting, .answered].contains($0.state)
        }
        let handoffID: String
        if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
            guard active.count == 1, let match = active.first else {
                consultationCondition.unlock()
                return RelayTextResponse(
                    status: active.isEmpty ? 404 : 409,
                    text: active.isEmpty
                        ? "this pane has no active tracked work"
                        : "this pane has more than one active item; name its id"
                )
            }
            handoffID = match.id
        } else {
            handoffID = requestedHandoffID
        }
        guard let handoff = handoffRecords[handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        guard handoff.sourcePaneID == sourceID else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the initiating pane can cancel this work")
        }
        consultationCondition.unlock()
        return cancelHandoff(
            handoffID,
            reason: "Cancelled by \(handoff.sourceName) through Parley's pane-scoped protocol.",
            origin: nil
        )
    }

    private func cancelHandoff(
        _ handoffID: String,
        reason: String,
        origin: RelayTransitionOrigin?
    ) -> RelayTextResponse {
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? "Cancelled by the person using Parley." : detail
        consultationCondition.lock()
        guard let handoff = handoffRecords[handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        switch handoff.kind {
        case .ask:
            guard consultationRecords[handoffID] != nil else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "this Ask is no longer waiting")
            }
            finishAskLocked(
                handoffID: handoffID,
                state: .cancelled,
                response: RelayTextResponse(status: 409, text: message),
                origin: origin
            )
        case .delegate:
            guard delegationRecords[handoffID] != nil else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "this delegation is no longer active")
            }
            transitionHandoffLocked(handoffID, to: .cancelled, detail: message, origin: origin)
            delegationRecords.removeValue(forKey: handoffID)
            delegationResponses[handoffID] = RelayTextResponse(status: 409, text: message)
            pruneHandoffsLocked()
            consultationCondition.broadcast()
        case .relay, .paste:
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "completed message delivery cannot be cancelled")
        }
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Tracking cancelled. The target pane was not interrupted.")
    }

    /// Reuses the original handoff id and idempotency scope. This is available
    /// only when the recorded writer error proves no terminal input began.
    /// Unknown and post-paste failures are deliberately not retryable.
    public func retryHandoff(_ handoffID: String) -> RelayTextResponse {
        let livePanes: [WorkbenchPane]
        do {
            livePanes = try panes()
        } catch {
            return RelayTextResponse(status: 409, text: "Parley could not inspect the live panes: \(error.localizedDescription)")
        }

        consultationCondition.lock()
        guard let handoff = handoffRecords[handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        guard handoff.state == .failed else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this handoff is not awaiting a retry")
        }
        guard handoff.canRetrySafely else {
            consultationCondition.unlock()
            let reason = switch handoff.kind {
            case .ask:
                "Ask cannot be retried from activity because its requesting command already returned."
            case .delegate:
                "Delegated work cannot be retried as a delivery after the target may have started it."
            case .relay, .paste:
                "Parley cannot safely retry this delivery because terminal input may already have started."
            }
            return RelayTextResponse(status: 409, text: reason)
        }
        guard let source = livePanes.first(where: { $0.id == handoff.sourcePaneID && $0.kind == handoff.sourceKind }),
              let target = livePanes.first(where: { $0.id == handoff.targetPaneID && $0.kind == handoff.targetKind }) else {
            transitionHandoffLocked(
                handoffID,
                to: .failed,
                detail: "The original source or target pane is no longer available.",
                failure: RelayFailureAssessment(retryDisposition: .unsupported, attention: .targetUnavailable),
                origin: .human
            )
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "The original source or target pane is no longer available.")
        }

        let scope = IdempotencyScope(senderPaneID: source.id, key: handoff.idempotencyKey)
        let signature = [handoff.kind.rawValue, target.id, handoff.text].joined(separator: "\u{1f}")
        if let existing = idempotencyRecords[scope], existing.handoffID != handoffID {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this retry conflicts with another handoff")
        }
        idempotencyRecords[scope] = IdempotencyRecord(
            signature: signature,
            handoffID: handoffID,
            response: nil
        )
        transitionHandoffLocked(
            handoffID,
            to: .created,
            detail: "Retry requested by the person using Parley.",
            origin: .human
        )
        consultationCondition.broadcast()
        consultationCondition.unlock()

        let writer = handoff.submitted ? submit : paste
        do {
            try writer(target.id, "\(handoff.sourceName) said:\n\n\(handoff.text)")
            consultationCondition.lock()
            transitionHandoffLocked(
                handoffID,
                to: .delivered,
                detail: "Safe retry delivered the original text.",
                origin: .human
            )
            transitionHandoffLocked(handoffID, to: .completed, origin: .human)
            let response = RelayResponse(
                status: 200,
                body: RelayResponseBody(
                    ok: true,
                    delivered: target.displayName,
                    submitted: handoff.submitted,
                    note: handoff.submitted
                        ? "Submitted to \(target.displayName)."
                        : "Pasted into the prompt and NOT sent. The person there presses Enter.",
                    error: nil,
                    handoffID: handoffID,
                    state: .completed
                )
            )
            idempotencyRecords[scope]?.response = .delivery(response)
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 200,
                text: "Retried the original delivery to \(target.displayName) without creating a new handoff."
            )
        } catch {
            let assessment = failureAssessment(kind: handoff.kind, error: error)
            consultationCondition.lock()
            transitionHandoffLocked(
                handoffID,
                to: .failed,
                detail: error.localizedDescription,
                failure: assessment,
                origin: .human
            )
            let response = failure(
                409,
                error.localizedDescription,
                handoffID: handoffID,
                state: .failed
            )
            idempotencyRecords[scope]?.response = .delivery(response)
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "Retry failed: \(error.localizedDescription)")
        }
    }

    public func cancelAll(reason: String = "Parley stopped before the consultation completed.") {
        consultationCondition.lock()
        let response = RelayTextResponse(status: 409, text: reason)
        for id in Array(consultationRecords.keys) {
            finishAskLocked(handoffID: id, state: .interrupted, response: response)
        }
        for id in Array(delegationRecords.keys) {
            finishDelegationLocked(handoffID: id, state: .interrupted, detail: reason)
        }
        consultationCondition.unlock()
    }

    private func targetHasTrackedWorkLocked(_ targetPaneID: String) -> Bool {
        consultationRecords.values.contains {
            $0.consultation.targetPaneID == targetPaneID && $0.completion == nil
        } || delegationRecords.keys.contains {
            handoffRecords[$0]?.targetPaneID == targetPaneID
        }
    }

    private func resolve(_ requested: String, panes: [WorkbenchPane], sender: WorkbenchPane) -> [WorkbenchPane] {
        let available = panes.filter { $0.id != sender.id }
        if let exact = available.first(where: { $0.id == requested }) { return [exact] }

        let parts = requested.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let requestedWorkspace = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedPane = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestedWorkspace.isEmpty, !requestedPane.isEmpty else { return [] }
            return available.filter { pane in
                let workspaceMatches = requestedWorkspace.caseInsensitiveCompare(pane.workspaceName ?? "") == .orderedSame
                    || requestedWorkspace.caseInsensitiveCompare(pane.workspaceID) == .orderedSame
                return workspaceMatches && paneMatches(requestedPane, pane: pane)
            }
        }

        let local = available.filter { $0.workspaceID == sender.workspaceID && paneMatches(requested, pane: $0) }
        if !local.isEmpty { return local }
        return available.filter { paneMatches(requested, pane: $0) }
    }

    private func paneMatches(_ requested: String, pane: WorkbenchPane) -> Bool {
        if requested.hasPrefix("@") {
            let role = String(requested.dropFirst())
            guard PaneRoleRules.validationError(role) == nil else { return false }
            return role.caseInsensitiveCompare(pane.role ?? "") == .orderedSame
        }
        return requested.caseInsensitiveCompare(pane.displayName) == .orderedSame
            || requested.caseInsensitiveCompare(pane.kind.rawValue) == .orderedSame
            || requested.caseInsensitiveCompare(pane.kind.label) == .orderedSame
            || (requested.caseInsensitiveCompare("lead") == .orderedSame && pane.isWorkspaceLead)
    }

    private func authorize(_ kind: RelayHandoffKind, for sender: WorkbenchPane) throws {
        guard sender.automationPolicy.allows(kind) else {
            let operation = switch kind {
            case .relay: "automatic relay"
            case .paste: "paste"
            case .ask: "Ask/Answer"
            case .delegate: "tracked delegation"
            }
            throw BrokerFailure(
                status: 403,
                message: "The \(sender.workspaceName ?? "workspace") automation policy does not allow \(operation). Change it from Parley's workspace menu."
            )
        }
    }

    private func route(token: String, requestedTarget: String) throws -> (WorkbenchPane, WorkbenchPane) {
        guard let senderID = credentials.paneID(for: token) else {
            throw BrokerFailure(status: 401, message: "bad token")
        }
        let livePanes = try panes()
        guard let sender = livePanes.first(where: { $0.id == senderID }), sender.kind.isAgent else {
            throw BrokerFailure(status: 400, message: "unknown sender pane")
        }
        let requested = requestedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { throw BrokerFailure(status: 400, message: "name a target pane") }
        let candidates = resolve(requested, panes: livePanes, sender: sender)
        guard candidates.count == 1, let target = candidates.first else {
            if candidates.isEmpty { throw BrokerFailure(status: 400, message: "no pane named \(requested)") }
            let names = candidates.map { pane in
                let qualified = pane.workspaceName.map { "\($0)/\(pane.displayName)" } ?? pane.displayName
                return "\(qualified) (\(pane.id))"
            }.joined(separator: ", ")
            throw BrokerFailure(status: 400, message: "ambiguous target; choose \(names)")
        }
        guard target.kind.isAgent else {
            throw BrokerFailure(status: 400, message: "relay target must be an agent pane")
        }
        return (sender, target)
    }

    private func acceptAnswer(
        from senderID: String,
        presentedCredential: String?,
        consultationID: String,
        text: String,
        origin: RelayTransitionOrigin? = nil
    ) -> RelayTextResponse {
        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else { return RelayTextResponse(status: 400, text: "nothing to return") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: "answer too long")
        }

        consultationCondition.lock()
        guard var record = consultationRecords[consultationID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown consultation")
        }
        guard record.consultation.targetPaneID == senderID else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the requested pane can answer this consultation")
        }
        if let presentedCredential, presentedCredential != record.targetCredential {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this consultation belongs to an earlier run of the target pane")
        }
        guard record.consultation.state == .awaitingAnswer, record.completion == nil else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "the consultation is not awaiting an answer")
        }
        let answer = RelayTextResponse(status: 200, text: cleaned)
        record.completion = answer
        if var handoff = handoffRecords[consultationID] {
            handoff.resultText = cleaned
            handoffRecords[consultationID] = handoff
        }
        transitionHandoffLocked(consultationID, to: .answered, origin: origin)
        idempotencyRecords[record.idempotencyScope]?.response = .ask(answer)
        transitionHandoffLocked(consultationID, to: .completed, origin: origin)
        consultationRecords.removeValue(forKey: consultationID)
        pruneHandoffsLocked()
        consultationCondition.broadcast()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Answer returned to \(record.consultation.sourceName).")
    }

    private func waitForAskResponse(
        scope: IdempotencyScope,
        handoffID: String,
        targetName: String
    ) -> RelayTextResponse {
        consultationCondition.lock()
        let createdAt = handoffRecords[handoffID]?.transitions.first?.occurredAt ?? Date()
        consultationCondition.unlock()
        let deadline = createdAt.addingTimeInterval(consultationTimeout)

        while true {
            consultationCondition.lock()
            if let response = askResponseLocked(for: scope) {
                consultationCondition.unlock()
                return response
            }

            let now = Date()
            if now >= deadline {
                let response = RelayTextResponse(
                    status: 408,
                    text: "The consultation timed out before \(targetName) returned an answer."
                )
                finishAskLocked(handoffID: handoffID, state: .failed, response: response)
                let finished = askResponseLocked(for: scope) ?? response
                consultationCondition.unlock()
                return finished
            }

            let pollDeadline = min(deadline, now.addingTimeInterval(livenessPollInterval))
            _ = consultationCondition.wait(until: pollDeadline)
            if let response = askResponseLocked(for: scope) {
                consultationCondition.unlock()
                return response
            }
            let record = consultationRecords[handoffID]
            consultationCondition.unlock()

            guard let record else {
                consultationCondition.lock()
                let response = askResponseLocked(for: scope)
                    ?? RelayTextResponse(status: 409, text: "The consultation stopped without an answer.")
                consultationCondition.unlock()
                return response
            }
            guard let failure = livenessFailure(for: record) else { continue }

            consultationCondition.lock()
            if askResponseLocked(for: scope) == nil, consultationRecords[handoffID] != nil {
                finishAskLocked(
                    handoffID: handoffID,
                    state: failure.state,
                    response: RelayTextResponse(status: failure.status, text: failure.message)
                )
            }
            let response = askResponseLocked(for: scope)
                ?? RelayTextResponse(status: failure.status, text: failure.message)
            consultationCondition.unlock()
            return response
        }
    }

    private func livenessFailure(for record: ConsultationRecord) -> AskLivenessFailure? {
        guard let livePanes = try? panes() else {
            // A transient workbench inspection failure is not evidence that a pane
            // died. The next bounded poll gets another chance.
            return nil
        }
        let consultation = record.consultation
        guard livePanes.contains(where: { $0.id == consultation.sourcePaneID }) else {
            return AskLivenessFailure(
                state: .interrupted,
                status: 409,
                message: "The consultation stopped because the requesting pane closed."
            )
        }
        guard livePanes.contains(where: { $0.id == consultation.targetPaneID }) else {
            return AskLivenessFailure(
                state: .failed,
                status: 410,
                message: "The consultation failed because \(consultation.targetName)'s pane closed."
            )
        }
        guard credentials.paneID(for: record.sourceCredential) == consultation.sourcePaneID else {
            return AskLivenessFailure(
                state: .interrupted,
                status: 409,
                message: "The consultation stopped because the requesting pane restarted."
            )
        }
        guard !record.targetCredential.isEmpty,
              credentials.paneID(for: record.targetCredential) == consultation.targetPaneID else {
            return AskLivenessFailure(
                state: .failed,
                status: 409,
                message: "The consultation failed because \(consultation.targetName)'s pane restarted before returning an answer."
            )
        }
        return nil
    }

    private func finishAskLocked(
        handoffID: String,
        state: RelayHandoffState,
        response: RelayTextResponse,
        origin: RelayTransitionOrigin? = nil
    ) {
        guard let record = consultationRecords[handoffID], record.completion == nil else { return }
        transitionHandoffLocked(handoffID, to: state, detail: response.text, origin: origin)
        idempotencyRecords[record.idempotencyScope]?.response = .ask(response)
        consultationRecords.removeValue(forKey: handoffID)
        pruneHandoffsLocked()
        consultationCondition.broadcast()
    }

    private func askResponseLocked(for scope: IdempotencyScope) -> RelayTextResponse? {
        if case let .ask(response)? = idempotencyRecords[scope]?.response { return response }
        return nil
    }

    private func consultationPrompt(for consultation: RelayConsultation) -> String {
        """
        \(consultation.sourceName) asked:

        \(consultation.question)

        Return the answer to the waiting \(consultation.sourceName) turn by running:
        parley answer current "your answer"

        For a multiline answer, pipe the text to `parley answer current`. Parley identifies the waiting question from this pane's credential, so do not copy or invent an id. Do not only print the answer in this pane; the requester is blocked waiting for that command.
        """
    }

    private func delegationPrompt(for handoff: RelayHandoff) -> String {
        """
        \(handoff.sourceName) delegated work:

        \(handoff.text)

        When the work is complete, return a concise completion report to \(handoff.sourceName) by running:
        parley done current "your completion report"

        If the work cannot be completed, return the blocking reason by running:
        parley fail current "why the work failed"

        For a multiline report, pipe the text to `parley done current` or `parley fail current`. Parley identifies this tracked item from the pane credential. Do not only print the result in this pane; the initiating agent may use `parley wait` for the structured outcome.
        """
    }

    private func reconcileDelegations() {
        guard let livePanes = try? panes() else { return }
        consultationCondition.lock()
        let ids = Array(delegationRecords.keys)
        consultationCondition.unlock()
        for id in ids { reconcileDelegation(id, livePanes: livePanes) }
    }

    private func reconcileDelegation(_ handoffID: String) {
        guard let livePanes = try? panes() else { return }
        reconcileDelegation(handoffID, livePanes: livePanes)
    }

    private func reconcileDelegation(_ handoffID: String, livePanes: [WorkbenchPane]) {
        consultationCondition.lock()
        let record = delegationRecords[handoffID]
        let handoff = handoffRecords[handoffID]
        consultationCondition.unlock()
        guard let record, let handoff else { return }
        guard let failure = delegationLivenessFailure(
            for: record,
            handoff: handoff,
            livePanes: livePanes
        ) else { return }

        consultationCondition.lock()
        if delegationRecords[handoffID] != nil {
            finishDelegationLocked(
                handoffID: handoffID,
                state: failure.state,
                detail: failure.message,
                status: failure.status
            )
        }
        consultationCondition.unlock()
    }

    private func delegationLivenessFailure(
        for record: DelegationRecord,
        handoff: RelayHandoff,
        livePanes: [WorkbenchPane]
    ) -> AskLivenessFailure? {
        guard livePanes.contains(where: { $0.id == handoff.sourcePaneID }) else {
            return AskLivenessFailure(
                state: .interrupted,
                status: 409,
                message: "The delegation stopped because the initiating pane closed."
            )
        }
        guard livePanes.contains(where: { $0.id == handoff.targetPaneID }) else {
            return AskLivenessFailure(
                state: .failed,
                status: 410,
                message: "The delegation failed because \(handoff.targetName)'s pane closed."
            )
        }
        guard credentials.paneID(for: record.sourceCredential) == handoff.sourcePaneID else {
            return AskLivenessFailure(
                state: .interrupted,
                status: 409,
                message: "The delegation stopped because the initiating pane restarted."
            )
        }
        guard credentials.paneID(for: record.targetCredential) == handoff.targetPaneID else {
            return AskLivenessFailure(
                state: .failed,
                status: 409,
                message: "The delegation failed because \(handoff.targetName)'s pane restarted before reporting a result."
            )
        }
        return nil
    }

    private func finishDelegationLocked(
        handoffID: String,
        state: RelayHandoffState,
        detail: String,
        status: Int = 409
    ) {
        guard delegationRecords[handoffID] != nil else { return }
        let failure = state == .failed
            ? RelayFailureAssessment(retryDisposition: .unsupported, attention: .targetUnavailable)
            : nil
        transitionHandoffLocked(handoffID, to: state, detail: detail, failure: failure)
        delegationResponses[handoffID] = RelayTextResponse(status: status, text: detail)
        delegationRecords.removeValue(forKey: handoffID)
        pruneHandoffsLocked()
        consultationCondition.broadcast()
    }

    private func delegationWaitResponse(for handoff: RelayHandoff) -> RelayTextResponse? {
        switch handoff.state {
        case .completed:
            return RelayTextResponse(status: 200, text: handoff.resultText ?? "Delegated work completed.")
        case .cancelled, .failed, .interrupted:
            return RelayTextResponse(
                status: 409,
                text: handoff.resultText ?? handoff.transitions.last?.detail ?? "Delegated work ended without a completion report."
            )
        case .created, .delivered, .waiting, .answered:
            return nil
        }
    }

    private func normalizeIdempotencyKey(_ supplied: String?) throws -> String {
        let key = supplied?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? UUID().uuidString.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:")
        guard (8...128).contains(key.count), key.unicodeScalars.allSatisfy(allowed.contains) else {
            throw BrokerFailure(status: 400, message: "invalid idempotency key")
        }
        return key
    }

    private func askManyChildKey(root: String, targetPaneID: String) -> String {
        func hash(_ value: String) -> String {
            var result: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                result ^= UInt64(byte)
                result &*= 1_099_511_628_211
            }
            return String(format: "%016llx", result)
        }
        let targetHash = hash(targetPaneID)
        if root.count <= 100 { return "\(root):many:\(targetHash)" }
        return "\(root.prefix(80)):\(hash(root)):many:\(targetHash)"
    }

    private func makeHandoff(
        idempotencyKey: String,
        kind: RelayHandoffKind,
        sender: WorkbenchPane,
        target: WorkbenchPane,
        text: String,
        submitted: Bool,
        origin: RelayTransitionOrigin? = nil
    ) -> RelayHandoff {
        let now = Date()
        return RelayHandoff(
            id: UUID().uuidString.lowercased(),
            idempotencyKey: idempotencyKey,
            kind: kind,
            sourcePaneID: sender.id,
            sourceName: sender.displayName,
            sourceKind: sender.kind,
            sourceWorkspaceID: sender.workspaceID,
            sourceWorkspaceName: sender.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.workspaceID,
            targetWorkspaceName: target.workspaceName,
            text: text,
            submitted: submitted,
            resultText: nil,
            state: .created,
            updatedAt: now,
            transitions: [RelayHandoffTransition(state: .created, occurredAt: now, detail: nil, origin: origin)]
        )
    }

    private func transitionHandoffLocked(
        _ handoffID: String,
        to state: RelayHandoffState,
        detail: String? = nil,
        failure: RelayFailureAssessment? = nil,
        origin: RelayTransitionOrigin? = nil
    ) {
        guard var handoff = handoffRecords[handoffID] else { return }
        let now = Date()
        handoff.state = state
        handoff.updatedAt = now
        if state == .failed {
            handoff.retryDisposition = failure?.retryDisposition
            handoff.attention = failure?.attention
        } else {
            handoff.retryDisposition = nil
            handoff.attention = nil
        }
        handoff.transitions.append(RelayHandoffTransition(
            state: state,
            occurredAt: now,
            detail: detail,
            origin: origin
        ))
        handoffRecords[handoffID] = handoff
        handoffJournal?.record(handoff)
    }

    private func failureAssessment(kind: RelayHandoffKind, error: Error) -> RelayFailureAssessment {
        let attention: RelayAttention?
        let deliveryWasNotStarted: Bool
        switch error as? ParleyWorkbenchError {
        case .copilotTrustRequired:
            attention = .permissionRequired
            deliveryWasNotStarted = true
        case .unsafeRelayTarget:
            attention = .targetNotReady
            deliveryWasNotStarted = true
        case .paneNotFound:
            attention = .targetUnavailable
            deliveryWasNotStarted = true
        case .noRelayText:
            attention = nil
            deliveryWasNotStarted = true
        default:
            attention = nil
            deliveryWasNotStarted = false
        }
        let retryDisposition: RelayRetryDisposition = switch kind {
        case .relay, .paste:
            deliveryWasNotStarted ? .safe : .uncertain
        case .ask, .delegate:
            .unsupported
        }
        return RelayFailureAssessment(retryDisposition: retryDisposition, attention: attention)
    }

    private func pruneHandoffsLocked() {
        let excess = handoffRecords.count - historyRetentionPolicy.maximumRecords
        guard excess > 0 else { return }
        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        let removalIDs = Set(
            handoffRecords.values
                .filter { terminalStates.contains($0.state) }
                .sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                    return $0.updatedAt < $1.updatedAt
                }
                .prefix(excess)
                .map(\.id)
        )
        guard !removalIDs.isEmpty else { return }
        handoffRecords = handoffRecords.filter { !removalIDs.contains($0.key) }
        idempotencyRecords = idempotencyRecords.filter { !removalIDs.contains($0.value.handoffID) }
        delegationResponses = delegationResponses.filter { !removalIDs.contains($0.key) }
    }

    private func pruneActivityRecordsLocked() {
        let excess = activityRecords.count - historyRetentionPolicy.maximumRecords
        guard excess > 0 else { return }
        let removalIDs = Set(activityRecords.values.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt < $1.occurredAt
        }.prefix(excess).map(\.id))
        activityRecords = activityRecords.filter { !removalIDs.contains($0.key) }
    }

    private func failure(
        _ status: Int,
        _ message: String,
        handoffID: String? = nil,
        state: RelayHandoffState? = nil
    ) -> RelayResponse {
        RelayResponse(
            status: status,
            body: RelayResponseBody(
                ok: false,
                delivered: nil,
                submitted: nil,
                note: nil,
                error: message,
                handoffID: handoffID,
                state: state
            )
        )
    }
}

private struct RelayFailureAssessment {
    let retryDisposition: RelayRetryDisposition
    let attention: RelayAttention?
}

private struct ConsultationRecord {
    var consultation: RelayConsultation
    var completion: RelayTextResponse?
    let idempotencyScope: IdempotencyScope
    let sourceCredential: String
    let targetCredential: String
}

private struct DelegationRecord {
    let sourceCredential: String
    let targetCredential: String
}

private struct AskLivenessFailure {
    let state: RelayHandoffState
    let status: Int
    let message: String
}

private final class AskManyAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RelayAskManyAnswer?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    var values: [RelayAskManyAnswer] {
        lock.withLock { storage.compactMap { $0 } }
    }

    func set(_ answer: RelayAskManyAnswer, at index: Int) {
        lock.withLock { storage[index] = answer }
    }
}

private struct IdempotencyScope: Hashable {
    let senderPaneID: String
    let key: String
}

private enum IdempotentResponse {
    case delivery(RelayResponse)
    case ask(RelayTextResponse)
}

private struct IdempotencyRecord {
    let signature: String
    let handoffID: String
    var response: IdempotentResponse?
}

private struct BrokerFailure: Error {
    let status: Int
    let message: String
}

public enum RelayShimError: LocalizedError, Equatable {
    case commandCollision

    public var errorDescription: String? {
        switch self {
        case .commandCollision:
            "A different `parley` command already exists in the stable command directory. Parley left it unchanged."
        }
    }
}

public enum RelayShim {
    public static func install(
        in applicationDirectory: URL,
        transportDirectory: URL? = nil,
        runtimeMarker: String? = nil,
        openExecutable: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) throws -> URL {
        let bin = applicationDirectory.appendingPathComponent("bin", isDirectory: true)
        let transport = transportDirectory ?? RelayFileTransport.runtimeDirectory(applicationDirectory: applicationDirectory)
        _ = try installCommand(
            in: bin,
            transportDirectory: transport,
            runtimeMarker: runtimeMarker,
            openExecutable: openExecutable
        )
        return bin
    }

    @discardableResult
    public static func installCommand(
        in bin: URL,
        transportDirectory: URL? = nil,
        runtimeMarker: String? = nil,
        openExecutable: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) throws -> URL {
        let transport = transportDirectory
            ?? RelayFileTransport.runtimeDirectory(applicationDirectory: bin.deletingLastPathComponent())
        return try writeManagedCommand(
            script(
                transportDirectory: transport,
                runtimeMarker: runtimeMarker,
                openExecutable: openExecutable
            ),
            in: bin
        )
    }

    /// Installs the one command expected to survive vendor PATH rewriting.
    /// It contains no credential and owns no runtime; the pane's injected,
    /// non-secret runtime marker selects the isolated runtime-local shim.
    @discardableResult
    public static func installStableRouter(
        in bin: URL,
        productionCommand: URL,
        developmentCommand: URL
    ) throws -> URL {
        let source = """
        #!/bin/sh
        # Parley Native managed relay router
        set -eu
        case "${PARLEY_RUNTIME:-}" in
          DEV) command=\(shellLiteral(developmentCommand.path)) ;;
          *) command=\(shellLiteral(productionCommand.path)) ;;
        esac
        if [ ! -x "$command" ]; then
          echo "the selected Parley relay command is not prepared" >&2
          exit 2
        fi
        exec "$command" "$@"
        """
        return try writeManagedCommand(source, in: bin)
    }

    private static func writeManagedCommand(_ source: String, in bin: URL) throws -> URL {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("parley")
        if FileManager.default.fileExists(atPath: executable.path) {
            let existing = try String(contentsOf: executable, encoding: .utf8)
            let isManaged = existing.contains("Parley Native managed relay shim")
                || existing.contains("Parley Native managed relay router")
                || (existing.contains("PARLEY_RELAY_INFO") && existing.contains("parley relay <pane>"))
            guard isManaged else {
                throw RelayShimError.commandCollision
            }
        }
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private static func script(
        transportDirectory: URL,
        runtimeMarker: String?,
        openExecutable: URL
    ) -> String {
        scriptTemplate.replacingOccurrences(
            of: "__PARLEY_TRANSPORT_ROOT__",
            // Keep the exact spelling granted by AgentProcessBoundary. On
            // macOS, standardizedFileURL rewrites /private/tmp to /tmp; those
            // aliases are equivalent to the filesystem but not to Seatbelt's
            // literal subpath rules.
            with: shellLiteral(transportDirectory.path)
        ).replacingOccurrences(
            of: "__PARLEY_RUNTIME_MARKER__",
            with: shellLiteral(runtimeMarker ?? "")
        ).replacingOccurrences(
            of: "__PARLEY_OPEN_EXECUTABLE__",
            with: shellLiteral(openExecutable.path)
        ).replacingOccurrences(
            of: "__PARLEY_BUNDLE_IDENTIFIER__",
            with: shellLiteral(ParleyRuntime.productionBundleIdentifier)
        )
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static let scriptTemplate = """
    #!/bin/sh
    # Parley Native managed relay shim
    # Parley Native managed filesystem relay
    set -eu
    umask 077
    runtime_marker=__PARLEY_RUNTIME_MARKER__

    command="${1:-}"
    target=""
    item=""
    if [ "$command" = "open" ]; then
      if [ -n "${PARLEY_RELAY_TOKEN:-}" ]; then
        echo "parley open is a person-only external entry point; agent panes cannot invoke it" >&2
        exit 2
      fi
      if [ "$#" -ne 2 ]; then
        echo "usage: parley open <folder>" >&2
        exit 2
      fi
      folder="$2"
      case "$folder" in
        /*) ;;
        *) folder="$PWD/$folder" ;;
      esac
      if [ ! -d "$folder" ]; then
        echo "Parley can open only an existing folder: $folder" >&2
        exit 2
      fi
      folder="$(cd "$folder" 2>/dev/null && /bin/pwd -P)" || {
        echo "Parley could not resolve that folder" >&2
        exit 2
      }
      open_executable=__PARLEY_OPEN_EXECUTABLE__
      bundle_identifier=__PARLEY_BUNDLE_IDENTIFIER__
      "$open_executable" -b "$bundle_identifier" "$folder"
      echo "Asked the installed Parley app to open $folder"
      exit 0
    fi
    case "$command" in
      context)
        subcommand="${2:-}"
        case "$subcommand" in
          list)
            command="context-list"
            shift 2
            ;;
          show)
            item="${3:-}"
            if [ -z "$item" ]; then
              echo "context show needs a draft id" >&2
              exit 2
            fi
            command="context-show"
            shift 3
            ;;
          discard)
            item="${3:-}"
            if [ -z "$item" ]; then
              echo "context discard needs a draft id" >&2
              exit 2
            fi
            command="context-discard"
            shift 3
            ;;
          draft)
            shift 2
            context_name=""
            context_file=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --name)
                  [ "$#" -ge 2 ] || { echo "--name needs a value" >&2; exit 2; }
                  context_name="$2"
                  shift 2
                  ;;
                --file)
                  [ "$#" -ge 2 ] || { echo "--file needs a path" >&2; exit 2; }
                  context_file="$2"
                  shift 2
                  ;;
                *)
                  echo "unknown context draft option: $1" >&2
                  exit 2
                  ;;
              esac
            done
            [ -n "$context_file" ] || { echo "context draft needs --file <path>" >&2; exit 2; }
            command="context-draft"
            target="$context_file"
            item="$context_name"
            ;;
          add)
            item="${3:-}"
            [ -n "$item" ] || { echo "context add needs a draft id" >&2; exit 2; }
            shift 3
            [ "${1:-}" = "--file" ] && [ "$#" -eq 2 ] || {
              echo "usage: parley context add <draft> --file <path>" >&2
              exit 2
            }
            target="$2"
            shift 2
            command="context-add"
            ;;
          *)
            echo "usage:" >&2
            echo "  parley context list" >&2
            echo "  parley context show <draft>" >&2
            echo "  parley context discard <draft>" >&2
            echo "  parley context draft [--name <name>] --file <path>" >&2
            echo "  parley context add <draft> --file <path>" >&2
            exit 2
            ;;
        esac
        ;;
      relay|paste|ask|ask-many|delegate)
        target="${2:-}"
        if [ -z "$target" ]; then
          echo "name a pane, for example: parley $command agy \"your question\"" >&2
          exit 2
        fi
        shift 2
        if [ "$command" = "ask" ] && [ "${1:-}" = "--context" ]; then
          item="${2:-}"
          [ -n "$item" ] || { echo "--context needs a draft id" >&2; exit 2; }
          command="context-ask"
          shift 2
        fi
        ;;
      answer|done|fail|wait|cancel)
        item="${2:-}"
        case "$item" in
          "")
            echo "$command needs 'current' or a tracked item id" >&2
            exit 2
            ;;
          current) ;;
          *[!a-f0-9-]*)
            echo "$command needs 'current' or a tracked item id" >&2
            exit 2
            ;;
        esac
        shift 2
        ;;
      status)
        shift
        ;;
      *)
        if [ -n "$runtime_marker" ]; then
          echo "Parley relay [$runtime_marker]" >&2
        fi
        echo "usage:" >&2
        echo "  parley open <folder>             open or focus a workspace in the installed app" >&2
        echo "  parley relay <pane> [text...]   submit an attributed message" >&2
        echo "  parley paste <pane> [text...]   paste without sending" >&2
        echo "  parley ask <pane> [question...] wait for its correlated answer" >&2
        echo "  parley ask-many <a,b> [question...] ask explicit panes independently" >&2
        echo "  parley context draft --file <path> stage explicit context for review" >&2
        echo "  parley context discard <draft>     discard your staged context" >&2
        echo "  parley ask <pane> --context <draft> [question...] wait for reviewed Ask" >&2
        echo "  parley answer current [text...] answer this pane's waiting question" >&2
        echo "  parley delegate <pane> [task...] start tracked asynchronous work" >&2
        echo "  parley status                    list work initiated by this pane as JSON" >&2
        echo "  parley wait <id|current>         wait for one delegated result" >&2
        echo "  parley done current [report...]  complete this pane's delegated work" >&2
        echo "  parley fail current [reason...]  fail this pane's delegated work" >&2
        echo "  parley cancel <id|current>       cancel tracking for work this pane initiated" >&2
        echo "text may also come on stdin" >&2
        exit 2
        ;;
    esac

    case "$command" in
      status|wait|cancel|context-list|context-show|context-discard|context-draft|context-add) ;;
      *)
        if [ "$#" -eq 0 ] && [ -t 0 ]; then
          echo "nothing to $command: give the text as arguments or pipe it in" >&2
          exit 2
        fi
        ;;
    esac
    idempotency_key="${PARLEY_IDEMPOTENCY_KEY:-}"
    if [ -z "$idempotency_key" ]; then
      idempotency_key="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
    fi

    transport_root=__PARLEY_TRANSPORT_ROOT__
    pane_token="${PARLEY_RELAY_TOKEN:-}"
    case "$pane_token" in
      *[!a-f0-9]*|"")
        echo "the Parley pane capability is invalid" >&2
        exit 2
        ;;
    esac
    if [ "${#pane_token}" -ne 48 ]; then
      echo "the Parley pane capability is invalid" >&2
      exit 2
    fi
    endpoint="$transport_root/$pane_token"
    inbox="$endpoint/inbox"
    outbox="$endpoint/outbox"
    expected_owner="$(/usr/bin/id -u)"

    protected_directory() {
      directory="$1"
      [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
      [ "$(/usr/bin/stat -f '%u' "$directory" 2>/dev/null)" = "$expected_owner" ] || return 1
      [ "$(/usr/bin/stat -f '%Lp' "$directory" 2>/dev/null)" = "700" ] || return 1
    }

    heartbeat_is_fresh() {
      heartbeat="$endpoint/heartbeat"
      [ -f "$heartbeat" ] && [ ! -L "$heartbeat" ] || return 1
      modified="$(/usr/bin/stat -f '%m' "$heartbeat" 2>/dev/null || printf '0')"
      now="$(/bin/date '+%s')"
      [ "$modified" -gt 0 ] 2>/dev/null || return 1
      [ $((now - modified)) -le 3 ]
    }

    cleanup_directory() {
      directory="$1"
      [ -n "$directory" ] || return 0
      case "$directory" in
        "$inbox"/*|"$outbox"/*) ;;
        *) return 0 ;;
      esac
      for field in command target item idempotency-key token body status ready; do
        /bin/rm -f "$directory/$field" 2>/dev/null || true
      done
      /bin/rmdir "$directory" 2>/dev/null || true
    }

    request_dir=""
    response_dir=""
    cleanup() {
      cleanup_directory "$request_dir"
      cleanup_directory "$response_dir"
    }
    trap cleanup EXIT

    post() {
      if ! protected_directory "$endpoint" || ! protected_directory "$inbox" || ! protected_directory "$outbox" || ! heartbeat_is_fresh; then
        echo "the Parley relay broker is not running" >&2
        return 2
      fi

      request_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
      request_dir="$inbox/$request_id"
      response_dir="$outbox/$request_id"
      /bin/mkdir "$request_dir"
      /usr/bin/printf '%s' "$command" > "$request_dir/command"
      /usr/bin/printf '%s' "$target" > "$request_dir/target"
      /usr/bin/printf '%s' "$item" > "$request_dir/item"
      /usr/bin/printf '%s' "$idempotency_key" > "$request_dir/idempotency-key"
      /usr/bin/printf '%s' "$pane_token" > "$request_dir/token"
      /bin/cat > "$request_dir/body"
      /usr/bin/printf '%s' ready > "$request_dir/ready"

      checks=0
      while :; do
        if [ -f "$response_dir/ready" ] && [ ! -L "$response_dir" ] && [ ! -L "$response_dir/ready" ] \
          && [ -f "$response_dir/status" ] && [ ! -L "$response_dir/status" ] \
          && [ -f "$response_dir/body" ] && [ ! -L "$response_dir/body" ]; then
          status="$(/bin/cat "$response_dir/status")"
          /bin/cat "$response_dir/body"
          cleanup
          trap - EXIT
          case "$status" in
            2??) return 0 ;;
            *) return 22 ;;
          esac
        fi
        checks=$((checks + 1))
        if [ $((checks % 20)) -eq 0 ] && ! heartbeat_is_fresh; then
          echo "the Parley relay broker stopped before replying" >&2
          return 2
        fi
        /bin/sleep 0.05
      done
    }

    case "$command" in
      relay|paste|ask|ask-many|delegate|context-ask)
        if [ "$#" -gt 0 ]; then
          printf '%s' "$*"
        else
          /bin/cat
        fi | post
        ;;
      answer)
        if [ "$#" -gt 0 ]; then
          printf '%s' "$*"
        else
          /bin/cat
        fi | post
        ;;
      done|fail)
        if [ "$#" -gt 0 ]; then
          printf '%s' "$*"
        else
          /bin/cat
        fi | post
        ;;
      status)
        printf '' | post
        ;;
      wait)
        printf '' | post
        ;;
      cancel)
        printf '' | post
        ;;
      context-list|context-show|context-discard)
        printf '' | post
        ;;
      context-draft|context-add)
        /bin/cat -- "$target" | post
        ;;
    esac
    """
}
