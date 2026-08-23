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

/// One durable credential per persistent tmux pane. The credential is the
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
    public let credentials: RelayCredentials

    public init(infoFile: URL, shimDirectory: URL, credentials: RelayCredentials) {
        self.infoFile = infoFile
        self.shimDirectory = shimDirectory
        self.credentials = credentials
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
    public let status: Int
    public let answer: String?
    public let error: String?
}

public struct RelayAskManyBundle: Codable, Equatable, Sendable {
    public let ok: Bool
    public let answers: [RelayAskManyAnswer]
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

public struct RelayHandoffTransition: Codable, Equatable, Sendable {
    public let state: RelayHandoffState
    public let occurredAt: Date
    public let detail: String?
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
/// intentionally owned by the persistent core's memory: a UI may detach, but
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
/// only work initiated by the authenticated pane; credentials and tmux control
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
    public typealias Panes = () throws -> [TmuxPane]
    public typealias Paste = (_ paneID: String, _ text: String) throws -> Void
    public typealias Submit = (_ paneID: String, _ text: String) throws -> Void

    private static let maximumRetainedHandoffs = 500

    private let credentials: RelayCredentials
    private let panes: Panes
    private let paste: Paste
    private let submit: Submit
    private let consultationTimeout: TimeInterval
    private let livenessPollInterval: TimeInterval
    private let handoffJournal: RelayHandoffJournal?
    private let consultationCondition = NSCondition()
    private var consultationRecords: [String: ConsultationRecord] = [:]
    private var delegationRecords: [String: DelegationRecord] = [:]
    private var delegationResponses: [String: RelayTextResponse] = [:]
    private var handoffRecords: [String: RelayHandoff] = [:]
    private var idempotencyRecords: [IdempotencyScope: IdempotencyRecord] = [:]

    public init(
        credentials: RelayCredentials,
        panes: @escaping Panes,
        paste: @escaping Paste,
        submit: @escaping Submit,
        consultationTimeout: TimeInterval = 30 * 60,
        livenessPollInterval: TimeInterval = 0.5,
        handoffJournal: RelayHandoffJournal? = nil
    ) {
        self.credentials = credentials
        self.panes = panes
        self.paste = paste
        self.submit = submit
        self.consultationTimeout = consultationTimeout
        self.livenessPollInterval = max(0.01, livenessPollInterval)
        self.handoffJournal = handoffJournal

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
        pruneHandoffsLocked()
    }

    public func handle(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey: String? = nil
    ) -> RelayResponse {
        deliver(
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
        deliver(
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

    /// Starts cross-vendor work without blocking the initiating command. The
    /// exact target owns the terminal result, while status and wait remain
    /// scoped to the initiating pane's authenticated identity.
    public func handleDelegate(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil
    ) -> RelayResponse {
        let sender: TmuxPane
        let target: TmuxPane
        let idempotencyKey: String
        let targetCredential: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
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
        let sender: TmuxPane
        let target: TmuxPane
        let idempotencyKey: String
        let targetCredential: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            idempotencyKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            targetCredential = try credentials.token(for: target.id)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        let cleaned = RelayText.clean(text)
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
            submitted: true
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
            try submit(target.id, consultationPrompt(for: consultation))
            consultationCondition.lock()
            transitionHandoffLocked(handoff.id, to: .delivered)
            transitionHandoffLocked(handoff.id, to: .waiting)
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
                failure: failureAssessment(kind: .ask, error: error)
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

    /// Asks an explicit comma-separated set of cross-vendor panes the same
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
        let cleaned = RelayText.clean(text)
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
        var routes: [(requested: String, pane: TmuxPane)] = []
        do {
            rootKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            for requested in targets {
                let (_, target) = try route(token: token, requestedTarget: requested)
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

        let accumulator = AskManyAccumulator(count: routes.count)
        let group = DispatchGroup()
        for (index, route) in routes.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                let response = handleAsk(
                    token: token,
                    target: route.pane.id,
                    text: cleaned,
                    idempotencyKey: askManyChildKey(root: rootKey, targetPaneID: route.pane.id)
                )
                let succeeded = (200..<300).contains(response.status)
                accumulator.set(
                    RelayAskManyAnswer(
                        requestedTarget: route.requested,
                        targetPaneID: route.pane.id,
                        targetName: route.pane.displayName,
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
            text: text
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

    /// Cancels the wait owned by an Ask without sending input to either pane.
    /// The requesting command receives the same explicit terminal response as
    /// every idempotent retry, while the target CLI is left undisturbed.
    public func cancelHandoff(
        _ handoffID: String,
        reason: String = "Cancelled by the person using Parley."
    ) -> RelayTextResponse {
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? "Cancelled by the person using Parley." : detail
        consultationCondition.lock()
        guard handoffRecords[handoffID] != nil else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        guard consultationRecords[handoffID] != nil else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this Ask is no longer waiting")
        }
        finishAskLocked(
            handoffID: handoffID,
            state: .cancelled,
            response: RelayTextResponse(status: 409, text: message)
        )
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Ask cancelled. Neither pane was interrupted.")
    }

    /// Reuses the original handoff id and idempotency scope. This is available
    /// only when the recorded writer error proves no terminal input began.
    /// Unknown and post-paste failures are deliberately not retryable.
    public func retryHandoff(_ handoffID: String) -> RelayTextResponse {
        let livePanes: [TmuxPane]
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
                failure: RelayFailureAssessment(retryDisposition: .unsupported, attention: .targetUnavailable)
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
            detail: "Retry requested by the person using Parley."
        )
        consultationCondition.broadcast()
        consultationCondition.unlock()

        let writer = handoff.submitted ? submit : paste
        do {
            try writer(target.id, "\(handoff.sourceName) said:\n\n\(handoff.text)")
            consultationCondition.lock()
            transitionHandoffLocked(handoffID, to: .delivered, detail: "Safe retry delivered the original text.")
            transitionHandoffLocked(handoffID, to: .completed)
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
                failure: assessment
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

    private func resolve(_ requested: String, panes: [TmuxPane], sender: TmuxPane) -> [TmuxPane] {
        let available = panes.filter { $0.id != sender.id }
        if let exact = available.first(where: { $0.id == requested }) { return [exact] }

        let parts = requested.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let requestedWorkspace = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedPane = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestedWorkspace.isEmpty, !requestedPane.isEmpty else { return [] }
            return available.filter { pane in
                let workspaceMatches = requestedWorkspace.caseInsensitiveCompare(pane.workspaceName ?? "") == .orderedSame
                    || requestedWorkspace.caseInsensitiveCompare(pane.windowID) == .orderedSame
                return workspaceMatches && paneMatches(requestedPane, pane: pane)
            }
        }

        let local = available.filter { $0.windowID == sender.windowID && paneMatches(requested, pane: $0) }
        if !local.isEmpty { return local }
        return available.filter { paneMatches(requested, pane: $0) }
    }

    private func paneMatches(_ requested: String, pane: TmuxPane) -> Bool {
            requested.caseInsensitiveCompare(pane.displayName) == .orderedSame
                || requested.caseInsensitiveCompare(pane.kind.rawValue) == .orderedSame
                || requested.caseInsensitiveCompare(pane.kind.label) == .orderedSame
    }

    private func route(token: String, requestedTarget: String) throws -> (TmuxPane, TmuxPane) {
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
        guard target.kind != sender.kind else {
            throw BrokerFailure(
                status: 400,
                message: "relay is cross-vendor; use the CLI's own delegation for the same vendor"
            )
        }
        return (sender, target)
    }

    private func acceptAnswer(
        from senderID: String,
        presentedCredential: String?,
        consultationID: String,
        text: String
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
        transitionHandoffLocked(consultationID, to: .answered)
        idempotencyRecords[record.idempotencyScope]?.response = .ask(answer)
        transitionHandoffLocked(consultationID, to: .completed)
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
            // A transient tmux inspection failure is not evidence that a pane
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
        response: RelayTextResponse
    ) {
        guard let record = consultationRecords[handoffID], record.completion == nil else { return }
        transitionHandoffLocked(handoffID, to: state, detail: response.text)
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

    private func reconcileDelegation(_ handoffID: String, livePanes: [TmuxPane]) {
        consultationCondition.lock()
        let record = delegationRecords[handoffID]
        let handoff = handoffRecords[handoffID]
        consultationCondition.unlock()
        guard let record,
              let handoff,
              let failure = delegationLivenessFailure(for: record, handoff: handoff, livePanes: livePanes) else {
            return
        }

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
        livePanes: [TmuxPane]
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
        sender: TmuxPane,
        target: TmuxPane,
        text: String,
        submitted: Bool
    ) -> RelayHandoff {
        let now = Date()
        return RelayHandoff(
            id: UUID().uuidString.lowercased(),
            idempotencyKey: idempotencyKey,
            kind: kind,
            sourcePaneID: sender.id,
            sourceName: sender.displayName,
            sourceKind: sender.kind,
            sourceWorkspaceID: sender.windowID,
            sourceWorkspaceName: sender.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.windowID,
            targetWorkspaceName: target.workspaceName,
            text: text,
            submitted: submitted,
            resultText: nil,
            state: .created,
            updatedAt: now,
            transitions: [RelayHandoffTransition(state: .created, occurredAt: now, detail: nil)]
        )
    }

    private func transitionHandoffLocked(
        _ handoffID: String,
        to state: RelayHandoffState,
        detail: String? = nil,
        failure: RelayFailureAssessment? = nil
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
        handoff.transitions.append(RelayHandoffTransition(state: state, occurredAt: now, detail: detail))
        handoffRecords[handoffID] = handoff
        handoffJournal?.record(handoff)
    }

    private func failureAssessment(kind: RelayHandoffKind, error: Error) -> RelayFailureAssessment {
        let attention: RelayAttention?
        let deliveryWasNotStarted: Bool
        switch error as? ParleyTmuxError {
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
        let excess = handoffRecords.count - Self.maximumRetainedHandoffs
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
        transportDirectory: URL? = nil
    ) throws -> URL {
        let bin = applicationDirectory.appendingPathComponent("bin", isDirectory: true)
        let transport = transportDirectory ?? RelayFileTransport.runtimeDirectory(applicationDirectory: applicationDirectory)
        _ = try installCommand(in: bin, transportDirectory: transport)
        return bin
    }

    @discardableResult
    public static func installCommand(
        in bin: URL,
        transportDirectory: URL? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("parley")
        if FileManager.default.fileExists(atPath: executable.path) {
            let existing = try String(contentsOf: executable, encoding: .utf8)
            let isManaged = existing.contains("Parley Native managed relay shim")
                || (existing.contains("PARLEY_RELAY_INFO") && existing.contains("parley relay <pane>"))
            guard isManaged else {
                throw RelayShimError.commandCollision
            }
        }
        let transport = transportDirectory
            ?? RelayFileTransport.runtimeDirectory(applicationDirectory: bin.deletingLastPathComponent())
        try script(transportDirectory: transport).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private static func script(transportDirectory: URL) -> String {
        scriptTemplate.replacingOccurrences(
            of: "__PARLEY_TRANSPORT_ROOT__",
            with: shellLiteral(transportDirectory.standardizedFileURL.path)
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

    command="${1:-}"
    target=""
    item=""
    case "$command" in
      relay|paste|ask|ask-many|delegate)
        target="${2:-}"
        if [ -z "$target" ]; then
          echo "name a pane, for example: parley $command agy \"your question\"" >&2
          exit 2
        fi
        shift 2
        ;;
      answer|done|fail|wait)
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
        echo "usage:" >&2
        echo "  parley relay <pane> [text...]   submit an attributed message" >&2
        echo "  parley paste <pane> [text...]   paste without sending" >&2
        echo "  parley ask <pane> [question...] wait for its correlated answer" >&2
        echo "  parley ask-many <a,b> [question...] ask explicit panes independently" >&2
        echo "  parley answer current [text...] answer this pane's waiting question" >&2
        echo "  parley delegate <pane> [task...] start tracked asynchronous work" >&2
        echo "  parley status                    list work initiated by this pane as JSON" >&2
        echo "  parley wait <id|current>         wait for one delegated result" >&2
        echo "  parley done current [report...]  complete this pane's delegated work" >&2
        echo "  parley fail current [reason...]  fail this pane's delegated work" >&2
        echo "text may also come on stdin" >&2
        exit 2
        ;;
    esac

    case "$command" in
      status|wait) ;;
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
    inbox="$transport_root/inbox"
    outbox="$transport_root/outbox"
    expected_owner="$(/usr/bin/id -u)"

    protected_directory() {
      directory="$1"
      [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
      [ "$(/usr/bin/stat -f '%u' "$directory" 2>/dev/null)" = "$expected_owner" ] || return 1
      [ "$(/usr/bin/stat -f '%Lp' "$directory" 2>/dev/null)" = "700" ] || return 1
    }

    heartbeat_is_fresh() {
      heartbeat="$transport_root/heartbeat"
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
      if ! protected_directory "$transport_root" || ! protected_directory "$inbox" || ! protected_directory "$outbox" || ! heartbeat_is_fresh; then
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
      /usr/bin/printf '%s' "${PARLEY_RELAY_TOKEN:-}" > "$request_dir/token"
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
      relay|paste|ask|ask-many|delegate)
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
    esac
    """
}
