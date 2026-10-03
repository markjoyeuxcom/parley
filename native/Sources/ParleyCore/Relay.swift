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
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
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
        try OwnerOnlyFile.write(data, to: file)
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

/// What an agent staged with `--file`: UTF-8 text, as always, or the bytes
/// of an image, which Parley checks and keeps its own copy of.
public enum AgentStagedContent: Sendable {
    case text(String)
    case image(Data)
}

/// A reply whose body is bytes, such as a fetched image.
public struct RelayDataResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
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
    /// Bounded team-session correlation: identifiers only, never objectives,
    /// folders or commands. Absent on records written before protocol 21.
    public let teamSessionID: String?
    public let requesterPaneID: String?
    public let affectedPaneIDs: [String]?

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
        origin: RelayTransitionOrigin = .human,
        teamSessionID: String? = nil,
        requesterPaneID: String? = nil,
        affectedPaneIDs: [String]? = nil
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
        self.teamSessionID = teamSessionID
        self.requesterPaneID = requesterPaneID
        self.affectedPaneIDs = affectedPaneIDs
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


public struct RelayHandoffReviewUpdate: Codable, Equatable, Sendable {
    public let handoffID: String
    public let expectedReviewRevision: Int
    public let verdict: RelayHandoffVerdict?
    public let note: String

    public init(
        handoffID: String,
        expectedReviewRevision: Int,
        verdict: RelayHandoffVerdict?,
        note: String
    ) {
        self.handoffID = handoffID
        self.expectedReviewRevision = expectedReviewRevision
        self.verdict = verdict
        self.note = note
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
    public let progressNote: String?
    public let progressUpdatedAt: Date?
    public let resultText: String?
    public let resultContextReviewID: String?
    public let inReplyToHandoffID: String?
    public let relationship: RelayHandoffRelationship?
    /// Whether the target reported starting a turn since delivery: false
    /// for a minute or more means the text may not have arrived, so the
    /// person checks that pane; nil when the target reports no hooks.
    public let targetTurnStarted: Bool?
    public let createdAt: Date
    public let updatedAt: Date

    fileprivate init(handoff: RelayHandoff, target: WorkbenchPane?) {
        id = handoff.id
        sourcePaneID = handoff.sourcePaneID
        sourceName = handoff.sourceName
        targetPaneID = handoff.targetPaneID
        targetName = handoff.targetName
        task = handoff.text
        state = handoff.state
        progressNote = handoff.progressNote
        progressUpdatedAt = handoff.progressUpdatedAt
        resultText = handoff.resultText
        resultContextReviewID = handoff.resultContextReviewID
        inReplyToHandoffID = handoff.inReplyToHandoffID
        relationship = handoff.relationship
        targetTurnStarted = HandoffStartProjection.turnStarted(handoff, target: target)
        createdAt = handoff.transitions.first?.occurredAt ?? handoff.updatedAt
        updatedAt = handoff.updatedAt
    }
}

public final class RelayBroker: @unchecked Sendable {
    public typealias Panes = () throws -> [WorkbenchPane]
    public typealias Paste = (_ paneID: String, _ text: String) throws -> Void
    public typealias Submit = (_ paneID: String, _ text: String) throws -> Void
    public typealias SelectedText = (_ paneID: String) throws -> String
    public typealias VendorSignal = (_ paneID: String, _ signal: VendorHookSignal, _ occurredAt: Date) throws -> Void
    public typealias Clock = () -> Date
    /// Bounded Git facts for one working folder; nil when the folder is not a
    /// Git repository. Always invoked outside the coordination lock.
    public typealias GitFacts = (_ folder: String) -> DelegationGitSnapshot?

    private static let abandonedContextDraftLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumTransientVendorEvents = 512
    private let agentEventEpoch = UUID().uuidString.lowercased()

    private let credentials: RelayCredentials
    private let panes: Panes
    private let paste: Paste
    private let submit: Submit
    private let voiceSubmit: ((VoiceHandoffRequest, String) throws -> Void)?
    private let contextSubmit: Submit
    private let selectedText: SelectedText?
    private let vendorSignal: VendorSignal
    private let gitFacts: GitFacts?
    /// Target pane id to the credential of the run in which a delegation to
    /// it was cancelled. Cancel does not interrupt the target, so that run
    /// may still report the cancelled work; while it lasts, `current` could
    /// resolve to a later delegation and is refused (review of 22 Sep 2026,
    /// M4). A restart rotates the credential, which ends the refusal.
    private var cancelledDelegationRuns: [String: String] = [:]
    private let clock: Clock
    private let consultationTimeout: TimeInterval
    private let livenessPollInterval: TimeInterval
    private let handoffJournal: RelayHandoffJournal?
    private let activityJournal: RelayActivityJournal?
    private let historyRetentionStore: CollaborationHistoryRetentionStore?
    private let contextReviewStore: AgentContextReviewStore?
    private let contextImageStore: ContextImageStore?
    /// Digests being staged: pinned before their copy is written and released
    /// once the review holding them is in `contextReviewRecords` or staging
    /// failed, so a collection never takes a copy whose review is still being
    /// saved (Codex's review of MR !138, M5; a ten-minute age did this before
    /// and failed across a long sleep). Taken after the broker lock, never
    /// before it.
    private let imagePinLock = NSLock()
    private var pinnedImageDigests: [String: Int] = [:]
    /// Images in the person's open pack, which lives only in the app: the
    /// app replaces this set whenever the pack's images change, before it
    /// writes a new copy (`holdPersonImages`). Memory-only, like the pack.
    private var personImageHolds: Set<String> = []
    private var contextPersistenceErrors: [String: String] = [:]
    public var contextPersistenceError: String? {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        let errors = contextPersistenceErrors.values.sorted()
        return errors.isEmpty ? nil : "Context review persistence: " + errors.joined(separator: "; ")
    }

    /// Every save of a context review: the store keeps at most its bound, and
    /// the reviews it drops leave the broker's map too, or Status Center keeps
    /// listing reviews that are already gone (review of 22 September 2026,
    /// 4b656187).
    private func recordContextReviewLocked(_ review: AgentContextReview) throws {
        guard let contextReviewStore else { return }
        let pruned = try contextReviewStore.record(review)
        for id in pruned {
            contextReviewRecords.removeValue(forKey: id)
            contextPersistenceErrors.removeValue(forKey: id)
        }
        if !pruned.isEmpty { collectUnreferencedImagesLocked() }
    }

    private func imageDigests(of review: AgentContextReview) -> [String] {
        (review.pack.parts + [review.returnedPart].compactMap { $0 }).compactMap { $0.image?.sha256 }
    }

    /// Parley's copy of an image goes once no saved review holds it and no
    /// staging pins it. The pin lock is held across the listing too, so a
    /// digest pinned after the snapshot is stored only after this ends. Best
    /// effort: a copy left behind is collected the next time.
    private func collectUnreferencedImagesLocked() {
        guard let contextImageStore else { return }
        let referenced = Set(contextReviewRecords.values.flatMap(imageDigests))
            .union(handoffRecords.values.flatMap { ($0.deliveredImages ?? []).map(\.sha256) })
            .union((busyDraftStore?.drafts() ?? []).flatMap { ($0.images ?? []).map(\.sha256) })
        imagePinLock.withLock {
            _ = contextImageStore.removeAll(except: referenced.union(pinnedImageDigests.keys).union(personImageHolds))
        }
    }

    /// Only images the person's own pack holds, whose copy is intact, may be
    /// sent or queued as the person's, or added to an agent's draft: the
    /// native routes can then grant an agent's staged image to no one.
    private func personImagesRefusal(_ images: [ContextPackImage]) -> RelayTextResponse? {
        guard !images.isEmpty else { return nil }
        guard let contextImageStore else { return RelayTextResponse(status: 503, text: "image storage is unavailable") }
        let held = imagePinLock.withLock { personImageHolds }
        for image in images where !held.contains(image.sha256) || (try? contextImageStore.data(for: image)) == nil {
            return RelayTextResponse(status: 409, text: "an image in the pack is no longer kept, or is not the person's own; nothing was sent")
        }
        return nil
    }

    /// After handoffs leave memory: a copy only they held goes too.
    private func collectAfterRemovingHandoffsLocked(_ removed: [RelayHandoff]) {
        if removed.contains(where: { !($0.deliveredImages ?? []).isEmpty }) { collectUnreferencedImagesLocked() }
    }

    /// Native control only: the images in the person's open pack. The set
    /// replaces the last one, and a copy no longer held, sent or saved goes
    /// at once.
    public func holdPersonImages(_ digests: Set<String>) -> RelayTextResponse {
        guard digests.allSatisfy(ContextPackImage.isDigest) else {
            return RelayTextResponse(status: 400, text: "an image is named by its 64-character SHA-256")
        }
        consultationCondition.lock()
        imagePinLock.withLock { personImageHolds = digests }
        collectUnreferencedImagesLocked()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Holding \(digests.count) image\(digests.count == 1 ? "" : "s").")
    }

    private func pinImage(_ digest: String) {
        imagePinLock.withLock { pinnedImageDigests[digest, default: 0] += 1 }
    }

    /// A staging's end, whether its review was saved or not: the pin goes,
    /// and a copy nothing else holds goes with it, rather than waiting for the
    /// next collection (Codex's reviews of MR !138, M4, and !139). Callers run
    /// this from a `defer`, after every path has released the broker lock.
    private func releaseStagedImage(_ digest: String?) {
        guard let digest else { return }
        unpinImage(digest)
        consultationCondition.lock()
        if !contextReviewRecords.values.contains(where: { imageDigests(of: $0).contains(digest) }) {
            collectUnreferencedImagesLocked()
        }
        consultationCondition.unlock()
    }

    private func unpinImage(_ digest: String) {
        imagePinLock.withLock {
            let count = (pinnedImageDigests[digest] ?? 1) - 1
            pinnedImageDigests[digest] = count > 0 ? count : nil
        }
    }

    /// Terminal reality must remain visible even when saving it fails. Retain
    /// the error and retry the current record on the next native context read.
    @discardableResult
    private func persistContextRealityLocked(_ review: AgentContextReview) -> Error? {
        do {
            try recordContextReviewLocked(review)
            if contextPersistenceErrors.removeValue(forKey: review.id) != nil { noteChangeLocked() }
            return nil
        } catch {
            contextPersistenceErrors[review.id] = error.localizedDescription
            return error
        }
    }
    private let busyDraftStore: ReviewedBusyDraftStore?
    private let contextPackBuilder = ContextPackBuilder()
    private let consultationCondition = NSCondition()
    /// Advances on every mutation of the state the native relay tick reads
    /// (consultations, handoffs and their read marks, context reviews, busy
    /// drafts, activity, command runs, team sessions). The UI compares it in
    /// process before spending five control-socket round trips.
    private var changeRevision: UInt64 = 0
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
    private var transientVendorEventRecords: [String: RelayActivityEvent] = [:]
    private var agentEventSequenceByID: [String: UInt64] = [:]
    private var nextAgentEventSequence: UInt64 = 0
    private var historyRetentionPolicy: CollaborationHistoryRetentionPolicy
    private var contextReviewRecords: [String: AgentContextReview] = [:]
    private var idempotencyRecords: [IdempotencyScope: IdempotencyRecord] = [:]

    public init(
        credentials: RelayCredentials,
        panes: @escaping Panes,
        paste: @escaping Paste,
        submit: @escaping Submit,
        voiceSubmit: ((VoiceHandoffRequest, String) throws -> Void)? = nil,
        contextSubmit: Submit? = nil,
        selectedText: SelectedText? = nil,
        vendorSignal: VendorSignal? = nil,
        gitFacts: GitFacts? = nil,
        clock: @escaping Clock = Date.init,
        consultationTimeout: TimeInterval = 30 * 60,
        livenessPollInterval: TimeInterval = 0.5,
        handoffJournal: RelayHandoffJournal? = nil,
        activityJournal: RelayActivityJournal? = nil,
        historyRetentionPolicy: CollaborationHistoryRetentionPolicy = .defaultPolicy,
        historyRetentionStore: CollaborationHistoryRetentionStore? = nil,
        contextReviewStore: AgentContextReviewStore? = nil,
        busyDraftStore: ReviewedBusyDraftStore? = nil,
        contextImageStore: ContextImageStore? = nil,
        personImageHolds: Set<String> = []
    ) {
        self.credentials = credentials
        self.panes = panes
        self.paste = paste
        self.submit = submit
        self.voiceSubmit = voiceSubmit
        self.contextSubmit = contextSubmit ?? submit
        self.selectedText = selectedText
        self.vendorSignal = vendorSignal ?? { _, _, _ in }
        self.gitFacts = gitFacts
        self.clock = clock
        self.consultationTimeout = consultationTimeout
        self.livenessPollInterval = max(0.01, livenessPollInterval)
        self.handoffJournal = handoffJournal
        self.activityJournal = activityJournal
        self.historyRetentionPolicy = historyRetentionPolicy
        self.historyRetentionStore = historyRetentionStore
        self.contextReviewStore = contextReviewStore
        self.busyDraftStore = busyDraftStore
        self.contextImageStore = contextImageStore
        // The person's open pack outlives a core rebuilt by recovery, and this
        // start collects every copy no saved record holds (Codex's review of
        // MR !139): the app passes the pack's images before that happens.
        self.personImageHolds = personImageHolds

        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        var recovered = Dictionary(uniqueKeysWithValues: (handoffJournal?.handoffs() ?? []).map { ($0.id, $0) })
        for (id, var handoff) in recovered where !terminalStates.contains(handoff.state) {
            let now = Date()
            let reason = "Parley core restarted before this handoff reached a terminal state."
            handoff.state = .interrupted
            handoff.commandRun?.state = .interrupted
            handoff.commandRun?.workerStillRunning = false
            handoff.commandRun?.detail = reason
            handoff.commandRun?.updatedAt = now
            handoff.updatedAt = now
            handoff.transitions.append(RelayHandoffTransition(state: .interrupted, occurredAt: now, detail: reason))
            recovered[id] = handoff
            handoffJournal?.record(handoff)
        }
        handoffRecords = recovered
        let loadedActivities = activityJournal?.events() ?? []
        let obsoleteTransientIDs: Set<String> = Set(loadedActivities.compactMap { event in
            guard let signal = VendorHookSignal(activityKind: event.kind), !signal.isDurableActivity else {
                return nil
            }
            return event.id
        })
        if !obsoleteTransientIDs.isEmpty {
            _ = try? activityJournal?.removeEvents(ids: obsoleteTransientIDs)
        }
        activityRecords = Dictionary(uniqueKeysWithValues: loadedActivities.compactMap { event in
            obsoleteTransientIDs.contains(event.id) ? nil : (event.id, event)
        })
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
            _ = persistContextRealityLocked(review)
        }
        for (id, var review) in recoveredContext where review.state == .awaitingReview || review.state == .approved {
            review.state = .interrupted
            review.updatedAt = recoveredAt
            review.detail = "Parley core restarted before the reviewed context Ask completed."
            recoveredContext[id] = review
            _ = persistContextRealityLocked(review)
        }
        contextReviewRecords = recoveredContext
        // Copies left by reviews removed before a crash, or staged by a review
        // that never saved, go once the saved reviews are known.
        collectUnreferencedImagesLocked()
        pruneHandoffsLocked()
    }

    public func handleContextDraft(
        token: String,
        name suppliedName: String,
        path suppliedPath: String,
        text: String
    ) -> RelayTextResponse {
        handleContextDraft(token: token, name: suppliedName, path: suppliedPath, content: .text(text))
    }

    public func handleContextDraft(
        token: String,
        name suppliedName: String,
        path suppliedPath: String,
        content: AgentStagedContent
    ) -> RelayTextResponse {
        do {
            guard contextReviewStore != nil else {
                throw BrokerFailure(status: 503, message: "context review storage is unavailable")
            }
            let sender = try authenticatedSender(token: token)
            let name = suppliedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 80 else { throw BrokerFailure(status: 400, message: "context name is too long") }
            let staged = try agentFileDraftPart(sender: sender, suppliedPath: suppliedPath, content: content, holdingBrokerLock: false)
            defer { releaseStagedImage(staged.pinned) }
            let pack = ContextPack(
                name: name.isEmpty ? "\(sender.displayName) context" : name,
                parts: [staged.part],
                origin: .agentProposed
            )
            _ = try contextPackBuilder.render(pack)
            let review = AgentContextReview(
                sourcePaneID: sender.id,
                sourcePaneName: sender.displayName,
                sourcePaneKind: sender.kind,
                sourceFolder: sender.launchWorkingDirectory,
                pack: pack,
                sourceWorkspaceID: sender.workspaceID,
                sourceWorkspaceName: sender.workspaceName
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
        handleContextAdd(token: token, draftID: draftID, path: suppliedPath, content: .text(text))
    }

    public func handleContextAdd(
        token: String,
        draftID: String,
        path suppliedPath: String,
        content: AgentStagedContent
    ) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            // Checked before staging, so an add to a draft that is not this
            // pane's leaves no copy behind; checked again once staged.
            consultationCondition.lock()
            let editable = contextReviewRecords[draftID].map { $0.sourcePaneID == sender.id && $0.state == .draft } ?? false
            consultationCondition.unlock()
            guard editable else { throw BrokerFailure(status: 404, message: "no editable context draft named \(draftID)") }
            let staged = try agentFileDraftPart(sender: sender, suppliedPath: suppliedPath, content: content, holdingBrokerLock: false)
            defer { releaseStagedImage(staged.pinned) }
            consultationCondition.lock()
            guard var review = contextReviewRecords[draftID],
                  review.sourcePaneID == sender.id,
                  review.state == .draft else {
                consultationCondition.unlock()
                throw BrokerFailure(status: 404, message: "no editable context draft named \(draftID)")
            }
            review.pack.parts.append(staged.part)
            do {
                _ = try contextPackBuilder.render(review.pack)
                review.updatedAt = Date()
                try recordContextReviewLocked(review)
                contextReviewRecords[review.id] = review
                noteChangeLocked()
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

    /// `parley image <digest> --to <file>`. A pane may fetch an image it
    /// staged, or one in a pack the person approved sending to it. Naming the
    /// digest in a message grants nothing: until 2 October 2026 any handoff
    /// whose text or result held the digest did, so a returned file named by
    /// its digest reached the lead through Parley's own receipt before the
    /// person had seen it, and a digest learned that way could be passed on
    /// (Codex's review of MR !138, M1).
    public func handleImageFetch(token: String, digest: String) -> RelayDataResponse {
        func message(_ status: Int, _ text: String) -> RelayDataResponse { RelayDataResponse(status: status, body: Data(text.utf8)) }
        guard ContextPackImage.isDigest(digest) else {
            return message(400, "name an image by the 64-character SHA-256 Parley printed for it")
        }
        guard let contextImageStore else { return message(503, "image storage is unavailable") }
        let sender: WorkbenchPane
        do { sender = try authenticatedSender(token: token) }
        catch let error as BrokerFailure { return message(error.status, error.message) }
        catch { return message(409, error.localizedDescription) }
        consultationCondition.lock()
        let holding = contextReviewRecords.values.filter { imageDigests(of: $0).contains(digest) }
        let sentByPerson = handoffRecords.values.filter { ($0.deliveredImages ?? []).contains { $0.sha256 == digest } }
        let reviewed: [ContextPackImage] = holding.flatMap { ($0.pack.parts + [$0.returnedPart].compactMap { $0 }).compactMap(\.image) }
        let sent: [ContextPackImage] = sentByPerson.flatMap { $0.deliveredImages ?? [] }
        // A queued draft keeps its images but grants nothing until it is sent.
        let queued: [ContextPackImage] = (busyDraftStore?.drafts() ?? []).flatMap { $0.images ?? [] }
        let image = (reviewed + sent + queued).first { $0.sha256 == digest }
        // Staged: an image this pane put in its own draft, never the person's
        // capture added to that draft (`.windowCapture`).
        let staged = holding.contains { review in
            review.sourcePaneID == sender.id
                && (review.pack.parts + [review.returnedPart].compactMap { $0 })
                    .contains { $0.image?.sha256 == digest && $0.source.kind == .agentFileDraft }
        }
        // The person sent this pane a pack holding it: approval records the
        // target, and only a review approved or delivered counts.
        let delivered = holding.contains { review in
            review.requestedTargetPaneID == sender.id
                && (review.state == .approved || review.state == .completed)
                && review.pack.parts.contains { $0.image?.sha256 == digest }
        } || sentByPerson.contains { $0.targetPaneID == sender.id }
        consultationCondition.unlock()
        guard let image else { return message(404, "Parley no longer keeps image \(digest)") }
        guard staged || delivered else {
            return message(403, "this pane did not stage that image, and the person has not sent it a pack holding it")
        }
        do { return RelayDataResponse(status: 200, body: try contextImageStore.data(for: image)) }
        catch let error as ContextImageError { return message(error == .missing ? 404 : 409, error.localizedDescription) }
        catch { return message(409, error.localizedDescription) }
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
                try recordContextReviewLocked(review)
                contextReviewRecords[review.id] = review
            } catch {
                consultationCondition.unlock()
                throw error
            }
            noteChangeLocked()
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
            case .windowCapture:
                guard let image = request.image,
                      request.paths.isEmpty,
                      request.paneID == nil,
                      request.executablePath == nil,
                      request.arguments.isEmpty,
                      request.evidencePaneID == nil,
                      request.sourceURL == nil,
                      request.selectedText == nil else {
                    throw BrokerFailure(status: 400, message: "invalid window capture request")
                }
                if let refusal = personImagesRefusal([image]) { return refusal }
                captured = [.personWindowCapture(
                    image,
                    label: "Window capture",
                    detail: "Captured by the person with the macOS window picker · \(image.width) × \(image.height) pixels"
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
                try recordContextReviewLocked(review)
                contextReviewRecords[review.id] = review
                noteChangeLocked()
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
        idempotencyKey suppliedIdempotencyKey: String? = nil,
        onAccepted: ((String) -> Void)? = nil
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
                    try recordContextReviewLocked(review)
                    contextReviewRecords[review.id] = review
                } catch {
                    consultationCondition.unlock()
                    throw error
                }
                noteChangeLocked()
            }

            let deadline = Date().addingTimeInterval(consultationTimeout)
            while contextReviewRecords[draftID]?.state == .awaitingReview {
                if !consultationCondition.wait(until: deadline) {
                    if var expired = contextReviewRecords[draftID], expired.state == .awaitingReview {
                        expired.state = .failed
                        expired.updatedAt = Date()
                        expired.detail = "Context review timed out before approval."
                        contextReviewRecords[draftID] = expired
                        // Kept and retried if the save fails; a dropped save
                        // left a pending approval on disk after a restart.
                        _ = persistContextRealityLocked(expired)
                        noteChangeLocked()
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

            let refusedBeforeInput = LockedBox(false)
            let response = handleAsk(
                token: token,
                target: approvedTarget,
                text: rendered,
                idempotencyKey: idempotencyKey,
                humanInitiated: true,
                preserveFormatting: true,
                onAccepted: onAccepted,
                onWriterFailed: { refusedBeforeInput.set(ParleyWorkbenchError.refusedBeforeInput($0)) }
            )
            finishContextReview(draftID, response: response, idempotencyKey: idempotencyKey, sourcePaneID: sender.id,
                                refusedBeforeInput: refusedBeforeInput.value)
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
        for id in Array(contextPersistenceErrors.keys) {
            if let review = contextReviewRecords[id] { _ = persistContextRealityLocked(review) }
            else { contextPersistenceErrors.removeValue(forKey: id) }
        }
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
                try recordContextReviewLocked(review)
                contextReviewRecords[review.id] = review
            } catch {
                consultationCondition.unlock()
                throw error
            }
            noteChangeLocked()
            consultationCondition.unlock()
            return RelayTextResponse(status: 200, text: "Context Ask approved; the waiting pane will submit it now.")
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    /// A person's Ask One Pane on an agent-staged draft. The reviewed pack
    /// becomes one correlated Ask from the draft's source pane to the chosen
    /// target through the same engine as the toolbar Ask, so the target
    /// answers with `parley answer <id>` and Status Center records the
    /// question and the returned result. Until v0.1.41 this route pasted the
    /// pack directly and recorded no handoff, so the reply only ever appeared
    /// in the target's terminal. The review is approved before any terminal
    /// input, completed once the Ask is accepted, returned to draft when the
    /// Ask is refused before any input (no handoff, or a writer refusal
    /// `ParleyWorkbenchError.refusedBeforeInput` recognises), and failed
    /// whenever input may have begun, a cancellation mid-paste included.
    /// The call returns when the answer arrives or the consultation times out.
    public func completeContextDraft(_ approval: AgentContextReviewApproval) -> RelayTextResponse {
        let prepared: (source: WorkbenchPane, target: WorkbenchPane, rendered: String, key: String)
        do {
            let livePanes = try panes()
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
            let rendered: String
            let key: String
            do {
                pack = try reviewedContextPackLocked(approval, review: review)
                rendered = try contextPackBuilder.render(pack)
                key = try normalizeIdempotencyKey(approval.idempotencyKey ?? "context-\(review.id)")
            } catch {
                consultationCondition.unlock()
                throw error
            }
            review.pack = pack
            review.state = .approved
            review.requestedTargetPaneID = target.id
            review.requestedTargetName = target.displayName
            review.updatedAt = Date()
            review.detail = "Approved by the person using Parley; submitting as a correlated Ask."
            do {
                try recordContextReviewLocked(review)
                contextReviewRecords[review.id] = review
            } catch {
                consultationCondition.unlock()
                throw error
            }
            noteChangeLocked()
            consultationCondition.unlock()
            prepared = (source, target, rendered, key)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        let sourceToken: String
        do {
            sourceToken = try credentials.token(for: prepared.source.id)
        } catch {
            let detail = "Not sent: could not resolve the source pane credential: \(error.localizedDescription)"
            _ = updateContextReview(approval.reviewID, state: .draft, detail: detail)
            return RelayTextResponse(status: 409, text: detail)
        }

        let completionPersistence = LockedBox<Error?>(nil)
        let refusedBeforeInput = LockedBox(false)
        let response = handleAsk(
            token: sourceToken,
            target: prepared.target.id,
            text: prepared.rendered,
            idempotencyKey: prepared.key,
            humanInitiated: true,
            preserveFormatting: true,
            transitionOrigin: .human,
            onAccepted: { [weak self] handoffID in
                guard let self else { return }
                completionPersistence.set(self.updateContextReview(
                    approval.reviewID,
                    state: .completed,
                    detail: "Reviewed and sent by the person using Parley as correlated Ask \(handoffID)."
                ))
            },
            onWriterFailed: { refusedBeforeInput.set(ParleyWorkbenchError.refusedBeforeInput($0)) }
        )

        // onAccepted ran only if the Ask was created and delivered. Otherwise
        // decide, as the agent's own context Ask does (`finishContextReview`):
        // no handoff, or a writer that refused before any input (Copilot
        // trust, a pane not ready, another delivery in progress), leaves the
        // draft sendable. Any other handoff was handed to the writer and input
        // may have begun: it failed, or was cancelled or interrupted while
        // its text was being pasted. Reopening that draft would offer the
        // same text for a second send.
        consultationCondition.lock()
        let reviewState = contextReviewRecords[approval.reviewID]?.state
        let handoff = handoffRecords.values.first {
            $0.idempotencyKey == prepared.key && $0.kind == .ask && $0.sourcePaneID == prepared.source.id
        }
        consultationCondition.unlock()
        if reviewState == .approved {
            if let handoff, !refusedBeforeInput.value {
                _ = updateContextReview(
                    approval.reviewID,
                    state: .failed,
                    detail: handoff.state == .failed
                        ? "Context delivery failed: \(response.text). Check the target before retrying."
                        : "Context delivery ended \(handoff.state.rawValue) after it began: \(response.text). Part of it may already be in \(prepared.target.displayName)'s input; check that pane before sending it again."
                )
            } else {
                _ = updateContextReview(approval.reviewID, state: .draft, detail: "Not sent: \(response.text)")
            }
            return response
        }
        if response.status == 200, let persistence = completionPersistence.value {
            return RelayTextResponse(
                status: 202,
                text: "Context was delivered to \(prepared.target.displayName) and answered, but Parley could not persist the review's completion: \(persistence.localizedDescription). Do not resend it."
            )
        }
        return response
    }

    /// Moves one context review to a terminal or resendable state under the
    /// broker lock and records it. Returns the persistence error, if any; the
    /// in-memory record is updated either way so Status Center never shows a
    /// review as still approved once its Ask has been accepted or refused.
    private func updateContextReview(
        _ reviewID: String,
        state: AgentContextReviewState,
        detail: String
    ) -> Error? {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        guard var review = contextReviewRecords[reviewID] else { return nil }
        review.state = state
        review.updatedAt = Date()
        review.detail = detail
        contextReviewRecords[reviewID] = review
        noteChangeLocked()
        return persistContextRealityLocked(review)
    }

    public func rejectContextReview(reviewID: String, expectedUpdatedAt: Date) -> RelayTextResponse {
        consultationCondition.lock()
        guard var review = contextReviewRecords[reviewID], review.state == .awaitingReview else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "that context Ask is not awaiting review; discard plain drafts from their draft review")
        }
        guard review.updatedAt == expectedUpdatedAt else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "that context Ask changed since it was reviewed; read it again before declining")
        }
        review.state = .rejected
        review.updatedAt = Date()
        review.detail = "The person declined this context Ask."
        do {
            try recordContextReviewLocked(review)
            contextReviewRecords[review.id] = review
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
        noteChangeLocked()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: review.detail ?? "Context draft declined.")
    }

    /// Discards one editable draft from the native UI. Unlike
    /// `rejectContextReview` it refuses a draft that is now a waiting Ask or
    /// that changed since the person read it, under the same lock as every
    /// other review mutation, so a bulk discard can never decline an Ask.
    public func discardContextDraft(_ discard: AgentContextDraftDiscard) -> RelayTextResponse {
        consultationCondition.lock()
        guard var review = contextReviewRecords[discard.reviewID], review.state.needsHumanReview else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "that context draft is not awaiting review")
        }
        guard review.state == .draft else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "that draft is now waiting for approval as a context Ask; decline it from its review instead")
        }
        guard review.updatedAt == discard.expectedUpdatedAt else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "that draft changed since it was listed; read it again before discarding")
        }
        review.state = .discarded
        review.updatedAt = Date()
        review.detail = "The person discarded this context draft."
        do {
            try recordContextReviewLocked(review)
            contextReviewRecords[review.id] = review
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
        noteChangeLocked()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: review.detail ?? "Context draft discarded.")
    }

    /// Permanent removal is native-only, unlike the agent's retained discard.
    /// Validate every selected revision before removing any of the batch.
    public func deleteContextReviews(_ deletion: AgentContextDeletion) -> RelayTextResponse {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        let ids = Set(deletion.reviews.map(\.reviewID))
        guard !ids.isEmpty, ids.count == deletion.reviews.count else {
            return RelayTextResponse(status: 400, text: "select distinct saved context records to delete")
        }
        for selected in deletion.reviews {
            guard let review = contextReviewRecords[selected.reviewID],
                  review.updatedAt == selected.expectedUpdatedAt else {
                return RelayTextResponse(status: 409, text: "a selected context record changed or was removed; refresh before deleting")
            }
            guard review.state.canDelete else {
                return RelayTextResponse(status: 409, text: "a selected context record is waiting for approval or being delivered; resolve it before deleting")
            }
        }
        do { try deleteContextReviewsLocked(ids: ids) }
        catch { return RelayTextResponse(status: 500, text: "Parley could not delete saved context: \(error.localizedDescription)") }
        return RelayTextResponse(status: 200, text: "Deleted \(ids.count) saved context record\(ids.count == 1 ? "" : "s") and their stored returned files. Project files and messages already sent are unchanged.")
    }

    private func deleteContextReviewsLocked(ids: Set<String>) throws {
        try contextReviewStore?.remove(ids: ids)
        contextReviewRecords = contextReviewRecords.filter { !ids.contains($0.key) }
        if !ids.isEmpty {
            collectUnreferencedImagesLocked()
            noteChangeLocked()
        }
    }

    /// An Ask refused before any delivery (a busy target, which leaves no
    /// handoff, or a writer that refused before input) sent nothing, so the
    /// review goes back to a draft, as the person's own send does; only one
    /// whose input may have begun is failed.
    private func finishContextReview(_ reviewID: String, response: RelayTextResponse, idempotencyKey: String, sourcePaneID: String,
                                     refusedBeforeInput: Bool) {
        consultationCondition.lock()
        guard var review = contextReviewRecords[reviewID] else {
            consultationCondition.unlock()
            return
        }
        let asked = handoffRecords.values.contains {
            $0.idempotencyKey == idempotencyKey && $0.kind == .ask && $0.sourcePaneID == sourcePaneID
        }
        if (200..<300).contains(response.status) {
            review.state = .completed
            review.detail = response.text
        } else if asked && !refusedBeforeInput {
            review.state = .failed
            review.detail = response.text
        } else {
            review.state = .draft
            review.detail = "Not sent: \(response.text)"
        }
        review.updatedAt = Date()
        contextReviewRecords[review.id] = review
        _ = persistContextRealityLocked(review)
        noteChangeLocked()
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
            parts: parts,
            origin: .agentApproved
        )
    }

    private func recordContextReview(_ review: AgentContextReview) throws {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        try recordContextReviewLocked(review)
        contextReviewRecords[review.id] = review
        noteChangeLocked()
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
        guard sender.isStarted, !sender.isDead, sender.relayEnabled else {
            throw BrokerFailure(status: 403, message: "the source agent pane is not running or relay is disabled")
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

    /// An image's digest comes back pinned: the caller releases it with
    /// `unpinImage` once the review holding it is in `contextReviewRecords`,
    /// or staging failed.
    private func agentFileDraftPart(
        sender: WorkbenchPane,
        suppliedPath: String,
        content: AgentStagedContent,
        referenceID: String? = nil,
        holdingBrokerLock: Bool
    ) throws -> (path: String, part: ContextPackPart, pinned: String?) {
        let path = try normalizedAgentContextPath(suppliedPath, cwd: sender.launchWorkingDirectory)
        let text: String
        switch content {
        case let .text(value):
            text = value
        case let .image(data):
            guard let contextImageStore else {
                throw BrokerFailure(status: 503, message: "image storage is unavailable")
            }
            func failure(_ error: ContextImageError) -> BrokerFailure {
                switch error {
                case .tooLarge: BrokerFailure(status: 413, message: error.localizedDescription)
                case .storeFull: BrokerFailure(status: 507, message: error.localizedDescription)
                default: BrokerFailure(status: 400, message: error.localizedDescription)
                }
            }
            let inspected: ContextPackImage
            do { inspected = try ContextImageInspector.inspect(data) }
            catch let error as ContextImageError { throw failure(error) }
            pinImage(inspected.sha256)
            let image: ContextPackImage
            do {
                do { image = try contextImageStore.store(data) }
                catch ContextImageError.storeFull {
                    // Copies no review holds, such as one a crash or a refused
                    // add left, make way before the person is asked to.
                    if !holdingBrokerLock { consultationCondition.lock() }
                    collectUnreferencedImagesLocked()
                    if !holdingBrokerLock { consultationCondition.unlock() }
                    image = try contextImageStore.store(data)
                }
            } catch {
                unpinImage(inspected.sha256)
                if let error = error as? ContextImageError { throw failure(error) }
                throw error
            }
            let lineage = referenceID.map { " · returned from delegation \($0)" } ?? ""
            return (path, ContextPackPart.agentImage(
                image,
                label: URL(fileURLWithPath: path).lastPathComponent,
                detail: "\(path) · provided by \(sender.displayName)\(lineage); bytes checked by Parley as a \(image.format.label) image, path not read by Parley",
                referenceID: referenceID
            ), image.sha256)
        }
        let normalized = ContextPackText.normalize(text)
        guard !normalized.isEmpty else {
            throw BrokerFailure(status: 400, message: "the context file is empty")
        }
        guard normalized.utf8.count <= ContextPackBuilder.defaultMaximumPartBytes else {
            throw BrokerFailure(status: 413, message: "the context file is too large")
        }
        let lineage = referenceID.map { " · returned from delegation \($0)" } ?? ""
        return (
            path,
            ContextPackPart(
                source: ContextPackSource(
                    kind: .agentFileDraft,
                    label: URL(fileURLWithPath: path).lastPathComponent,
                    detail: "\(path) · provided by \(sender.displayName)\(lineage); not independently read by Parley",
                    referenceID: referenceID
                ),
                capturedText: normalized
            ),
            nil
        )
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
                return failure(400, RelayText.tooLong("text", count: cleaned.count))
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
            noteChangeLocked()
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
                noteChangeLocked()
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
                noteChangeLocked()
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
    ///
    /// With `inReplyToHandoffID` this is Request Changes: exactly one Delegate
    /// child linked to a returned Delegate result with relationship
    /// `requestChanges`. A pane credential may name only a parent it initiated
    /// or received; the native route arrives human-authorized. Target
    /// resolution and the busy rule are the ordinary ones, and nothing here
    /// records a verdict.
    public func handleDelegate(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil,
        inReplyToHandoffID: String? = nil,
        humanInitiated: Bool = false,
        preserveFormatting: Bool = false,
        reviewedVoice: VoiceHandoffRequest? = nil
    ) -> RelayResponse {
        let sender: WorkbenchPane
        let target: WorkbenchPane
        let idempotencyKey: String
        let targetCredential: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            if let reviewedVoice {
                _ = try reviewedVoice.source.resolve(in: [sender])
                _ = try reviewedVoice.target.resolve(in: [target])
            }
            if !humanInitiated {
                try authorize(.delegate, for: sender)
            }
            idempotencyKey = try normalizeIdempotencyKey(suppliedIdempotencyKey)
            targetCredential = try credentials.token(for: target.id)
        } catch let error as BrokerFailure {
            return failure(error.status, error.message)
        } catch {
            return failure(409, error.localizedDescription)
        }

        let cleaned = preserveFormatting ? ContextPackText.normalize(text) : RelayText.clean(text)
        guard !cleaned.isEmpty else { return failure(400, "nothing to delegate") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return failure(400, RelayText.tooLong("delegated task", count: cleaned.count))
        }

        let scope = IdempotencyScope(senderPaneID: sender.id, key: idempotencyKey)
        let signature = [RelayHandoffKind.delegate.rawValue, target.id, cleaned, inReplyToHandoffID ?? ""].joined(separator: "\u{1f}")

        consultationCondition.lock()
        if let parentID = inReplyToHandoffID {
            guard let parent = handoffRecords[parentID] else {
                consultationCondition.unlock()
                return failure(404, "unknown parent handoff")
            }
            guard parent.kind == .delegate else {
                consultationCondition.unlock()
                return failure(409, "Request Changes links only a Delegate parent")
            }
            guard (parent.kind == .ask || parent.kind == .delegate), parent.hasReturnedResult else {
                consultationCondition.unlock()
                return failure(409, "Request Changes requires a returned Delegate result")
            }
            guard humanInitiated || sender.id == parent.sourcePaneID || sender.id == parent.targetPaneID else {
                consultationCondition.unlock()
                return failure(403, "this pane neither initiated nor received that delegation")
            }
        }
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
            inReplyToHandoffID: inReplyToHandoffID,
            relationship: inReplyToHandoffID == nil ? nil : .requestChanges,
            text: cleaned,
            submitted: true,
            origin: humanInitiated ? .human : nil
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
        noteChangeLocked()
        consultationCondition.unlock()

        // Informational Git facts are read outside the coordination lock. They
        // never gate delivery, and terminal input is never driven while the
        // lock is held.
        let gitAtDelegation = gitFactsSnapshot(for: target)

        // Revalidate the same created, still-active delegation immediately
        // before delivery. A cancellation or any other terminal transition
        // during capture wins: nothing is submitted, the recorded history is
        // left untouched, and the idempotent response settles on that
        // terminal outcome so a replay can never deliver it later.
        consultationCondition.lock()
        guard delegationRecords[handoff.id] != nil,
              let current = handoffRecords[handoff.id],
              current.state == .created else {
            let terminal = handoffRecords[handoff.id]
            let response = failure(
                409,
                terminal.map { "the delegated task was \($0.state.rawValue) before delivery; nothing was submitted" }
                    ?? "the delegated task was removed before delivery; nothing was submitted",
                handoffID: handoff.id,
                state: terminal?.state
            )
            idempotencyRecords[scope]?.response = .delivery(response)
            noteChangeLocked()
            consultationCondition.unlock()
            return response
        }
        // Attach the delegation-time facts to the still-created record and
        // journal it now, so a target that reports before submit unwinds
        // completes a record that already carries them. Delivery below never
        // depends on this write.
        if let gitAtDelegation {
            var updated = current
            updated.gitFactsAtDelegation = gitAtDelegation
            handoffRecords[handoff.id] = updated
            handoffJournal?.record(updated)
            // A reader may have fetched the record during the capture.
            noteChangeLocked()
        }
        // From here the text is handed to the target: a turn that began
        // during the Git read above is not this delegation's (Codex's review
        // of MR !141).
        handoffRecords[handoff.id]?.submissionStartedAt = clock()
        consultationCondition.unlock()

        do {
            if let reviewedVoice {
                try submitVoice(reviewedVoice, text: delegationPrompt(for: handoff))
            } else {
                try submit(target.id, delegationPrompt(for: handoff))
            }
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
            noteChangeLocked()
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
            noteChangeLocked()
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
        let senderID: String
        do { senderID = try authenticatedSender(token: token).id }
        catch let error as BrokerFailure { return RelayTextResponse(status: error.status, text: error.message) }
        catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else {
            return RelayTextResponse(status: 400, text: succeeded ? "nothing to report as done" : "nothing to report as failed")
        }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: RelayText.tooLong("delegation result", count: cleaned.count,
                hint: "Put a long report in a file inside your working folder and return it with parley done <id> --file <path>, using this delegation's id"))
        }

        // Phase one, unlocked: informational Git facts for the reporting
        // pane's working folder, read only when it has tracked work. Phase
        // two revalidates the exact delegation under the lock; a failed or
        // absent capture never changes the outcome recorded there.
        let gitAtReturn = gitFactsForReportingPane(senderID)

        consultationCondition.lock()
        let handoffID: String
        if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
            if let refusal = ambiguousCurrentDelegationLocked(senderID: senderID, token: token) {
                consultationCondition.unlock()
                return refusal
            }
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
            let detail = retiredDelegationDetailLocked(handoffID, senderID: senderID)
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: detail ?? "unknown active delegation")
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
            if let gitAtReturn { updated.gitFactsAtReturn = gitAtReturn }
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
        noteChangeLocked()
        consultationCondition.unlock()
        return RelayTextResponse(
            status: 200,
            text: succeeded
                ? "Completion returned to \(handoff.sourceName)."
                : "Failure returned to \(handoff.sourceName)."
        )
    }

    /// Completes one tracked delegation with a substantial UTF-8 file while
    /// retaining its bytes as an agent-provided claim until a person reviews
    /// the editable Context Pack draft. No content is sent to another pane.
    public func handleDelegationFileResult(
        token: String,
        handoffID requestedHandoffID: String,
        path suppliedPath: String,
        text: String
    ) -> RelayTextResponse {
        handleDelegationFileResult(token: token, handoffID: requestedHandoffID, path: suppliedPath, content: .text(text))
    }

    public func handleDelegationFileResult(
        token: String,
        handoffID requestedHandoffID: String,
        path suppliedPath: String,
        content suppliedContent: AgentStagedContent
    ) -> RelayTextResponse {
        do {
            guard contextReviewStore != nil else {
                throw BrokerFailure(status: 503, message: "context review storage is unavailable")
            }
            let sender = try authenticatedSender(token: token)
            let content: AgentStagedContent
            if case let .text(text) = suppliedContent {
                let normalized = ContextPackText.normalize(text)
                guard !normalized.isEmpty else {
                    throw BrokerFailure(status: 400, message: "the completion file is empty")
                }
                guard normalized.utf8.count <= ContextPackBuilder.defaultMaximumPartBytes else {
                    throw BrokerFailure(status: 413, message: "the completion file is too large")
                }
                content = .text(normalized)
            } else {
                content = suppliedContent
            }
            let path = try normalizedAgentContextPath(suppliedPath, cwd: sender.launchWorkingDirectory)
            let gitAtReturn = gitFactsForReportingPane(sender.id)

            consultationCondition.lock()
            let handoffID: String
            if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
                if let refusal = ambiguousCurrentDelegationLocked(senderID: sender.id, token: token) {
                    consultationCondition.unlock()
                    return refusal
                }
                let matches = delegationRecords.keys.filter { handoffRecords[$0]?.targetPaneID == sender.id }
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
                let detail = retiredDelegationDetailLocked(handoffID, senderID: sender.id)
                consultationCondition.unlock()
                return RelayTextResponse(status: 404, text: detail ?? "unknown active delegation")
            }
            guard handoff.targetPaneID == sender.id else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 403, text: "only the delegated target pane can report this result")
            }
            guard record.targetCredential == token else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "this delegation belongs to an earlier run of the target pane")
            }

            let staged: (path: String, part: ContextPackPart, pinned: String?)
            do {
                staged = try agentFileDraftPart(
                    sender: sender,
                    suppliedPath: path,
                    content: content,
                    referenceID: handoffID,
                    holdingBrokerLock: true
                )
            } catch {
                consultationCondition.unlock()
                throw error
            }
            defer { releaseStagedImage(staged.pinned) }
            let review = AgentContextReview(
                sourcePaneID: sender.id,
                sourcePaneName: sender.displayName,
                sourcePaneKind: sender.kind,
                sourceFolder: sender.launchWorkingDirectory,
                pack: ContextPack(
                    name: "Delegation result from \(sender.displayName)",
                    parts: [staged.part],
                    origin: .agentProposed
                ),
                sourceWorkspaceID: sender.workspaceID,
                sourceWorkspaceName: sender.workspaceName,
                returnedPart: staged.part,
                detail: "Returned from tracked delegation \(handoffID); awaiting explicit human review."
            )
            do {
                _ = try contextPackBuilder.render(review.pack)
                try recordContextReviewLocked(review)
            } catch {
                consultationCondition.unlock()
                throw error
            }
            contextReviewRecords[review.id] = review

            let filename = URL(fileURLWithPath: staged.path).lastPathComponent
            // The receipt never adds Parley's digest, though the agent's own
            // filename may hold one; naming a digest grants nothing
            // (`handleImageFetch`), so the lead reaches the image only once
            // the person sends it.
            let measure = staged.part.image.map { "\($0.format.label) image, \($0.width) × \($0.height) pixels, \($0.byteCount) bytes" }
                ?? "\(staged.part.capturedByteCount) UTF-8 bytes"
            let receipt = "\(sender.displayName) returned \(filename) (\(measure)) for explicit review. Context review ID: \(review.id)."
            if var updated = handoffRecords[handoffID] {
                updated.resultText = receipt
                updated.resultContextReviewID = review.id
                if let gitAtReturn { updated.gitFactsAtReturn = gitAtReturn }
                handoffRecords[handoffID] = updated
            }
            transitionHandoffLocked(handoffID, to: .completed, detail: receipt)
            delegationResponses[handoffID] = RelayTextResponse(status: 200, text: receipt)
            delegationRecords.removeValue(forKey: handoffID)
            pruneHandoffsLocked()
            noteChangeLocked()
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 200,
                text: "Completion file staged for explicit review and returned to \(handoff.sourceName)."
            )
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    /// Replaces the one compact, target-authored note attached to an active
    /// delegation. This is deliberately not a state transition: it neither
    /// proves activity nor changes the meaning of waiting, done, or failed.
    public func handleDelegationProgress(
        token: String,
        handoffID requestedHandoffID: String,
        text: String
    ) -> RelayTextResponse {
        let senderID: String
        do { senderID = try authenticatedSender(token: token).id }
        catch let error as BrokerFailure { return RelayTextResponse(status: error.status, text: error.message) }
        catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
        let cleaned = DelegationProgressText.normalize(text)
        guard !cleaned.isEmpty else {
            return RelayTextResponse(status: 400, text: "nothing to report as progress")
        }
        guard cleaned.utf8.count <= DelegationProgressText.maximumBytes else {
            return RelayTextResponse(
                status: 400,
                text: "delegation progress note exceeds \(DelegationProgressText.maximumBytes) UTF-8 bytes"
            )
        }

        consultationCondition.lock()
        let handoffID: String
        if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
            if let refusal = ambiguousCurrentDelegationLocked(senderID: senderID, token: token) {
                consultationCondition.unlock()
                return refusal
            }
            let matches = delegationRecords.keys.filter { handoffRecords[$0]?.targetPaneID == senderID }
            guard matches.count == 1, let match = matches.first else {
                consultationCondition.unlock()
                return RelayTextResponse(
                    status: matches.isEmpty ? 404 : 409,
                    text: matches.isEmpty
                        ? "this pane has no delegated work awaiting progress"
                        : "this pane has more than one delegated item awaiting progress"
                )
            }
            handoffID = match
        } else {
            handoffID = requestedHandoffID
        }
        guard let record = delegationRecords[handoffID], var handoff = handoffRecords[handoffID] else {
            let detail = retiredDelegationDetailLocked(handoffID, senderID: senderID)
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: detail ?? "unknown active delegation")
        }
        guard handoff.targetPaneID == senderID else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the delegated target pane can report progress")
        }
        guard record.targetCredential == token else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this delegation belongs to an earlier run of the target pane")
        }

        handoff.progressNote = cleaned
        handoff.progressUpdatedAt = clock()
        handoffRecords[handoffID] = handoff
        handoffJournal?.record(handoff)
        noteChangeLocked()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Progress recorded for \(handoff.sourceName).")
    }

    /// Accepts only one allowlisted, content-free lifecycle fact from the
    /// authenticated pane capability. The generated vendor adapters own this
    /// ingress; no request field can select or impersonate another pane.
    public func handleVendorSignal(token: String, signal suppliedSignal: String) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            guard sender.isStarted, !sender.isDead, sender.relayEnabled, sender.hasCurrentProtocol else {
                throw BrokerFailure(status: 409, message: "vendor lifecycle signal came from an inactive pane")
            }
            guard let signal = VendorHookSignal(rawValue: suppliedSignal) else {
                throw BrokerFailure(status: 400, message: "unknown vendor lifecycle signal")
            }
            guard VendorHookAdapter.supportedSignals(for: sender.kind).contains(signal) else {
                throw BrokerFailure(
                    status: 409,
                    message: "\(sender.kind.label) has no supported Parley hook for \(signal.rawValue)"
                )
            }

            let occurredAt = clock()
            try vendorSignal(sender.id, signal, occurredAt)
            let event = RelayActivityEvent(
                kind: signal.activityKind,
                occurredAt: occurredAt,
                workspaceID: sender.workspaceID,
                workspaceName: sender.workspaceName ?? sender.workspaceID,
                paneID: sender.id,
                paneName: sender.displayName,
                paneKind: sender.kind,
                detail: nil,
                origin: .automation
            )
            if signal.isDurableActivity {
                try activityJournal?.record(event)
            }
            consultationCondition.lock()
            if signal.isDurableActivity {
                activityRecords[event.id] = event
                if let retainedIDs = activityJournal.map({ Set($0.events().map(\.id)) }) {
                    activityRecords = activityRecords.filter { retainedIDs.contains($0.key) }
                } else {
                    pruneActivityRecordsLocked()
                }
            } else {
                transientVendorEventRecords[event.id] = event
                pruneTransientVendorEventsLocked()
            }
            if signal == .turnStarted { stampTargetTurnStartedLocked(paneID: sender.id, at: occurredAt) }
            noteChangeLocked()
            consultationCondition.unlock()
            return RelayTextResponse(status: 200, text: "")
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(
                status: 500,
                text: "Parley could not record the vendor lifecycle signal: \(error.localizedDescription)"
            )
        }
    }

    /// The target's turn began: every active Ask or Delegate to it whose text
    /// Parley had begun handing over by that moment, and not yet stamped,
    /// records it. The bound is the start of submission, not delivery,
    /// because the vendor's hook can arrive before Parley records the
    /// delivered transition; nor creation, because a turn during a
    /// delegation's Git read is not that delegation's (Codex's review of MR
    /// !141, M1).
    private func stampTargetTurnStartedLocked(paneID: String, at occurredAt: Date) {
        let active: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        for (id, var handoff) in handoffRecords
        where handoff.targetPaneID == paneID && (handoff.kind == .ask || handoff.kind == .delegate)
            && active.contains(handoff.state) && handoff.targetTurnStartedAt == nil
            && (handoff.submissionStartedAt ?? .distantFuture) <= occurredAt {
            handoff.targetTurnStartedAt = occurredAt
            handoffRecords[id] = handoff
            handoffJournal?.record(handoff)
        }
    }

    /// Whether this generation's launch profile allows network; nil before
    /// launch or when unknown. Set by the core, never read from edited settings.
    public var hostNetworkAllowed: ((WorkbenchPane) -> Bool?)?
    public var hostClaudeSandbox: ((WorkbenchPane) -> ClaudeSandboxFact?)?

    /// The ticket policy of the pane a capability belongs to, or nil for a
    /// capability nobody holds. The transport asks before it reads a request.
    public func ticketPolicy(token: String, socketListening: Bool) -> RelayTicketPolicy? {
        guard let sender = try? authenticatedSender(token: token) else { return nil }
        return RelayTicketPolicy.policy(for: sender, socketListening: socketListening,
            networkAllowed: hostNetworkAllowed?(sender), claudeSandbox: hostClaudeSandbox?(sender))
    }

    public func agentIdentity(token: String, attestation: RelayAttestation? = nil, ticketPolicy: RelayTicketPolicy? = nil) -> RelayTextResponse {
        do {
            return encodeAgentValue(RelayAgentIdentity(pane: try authenticatedSender(token: token), attestation: attestation, ticketPolicy: ticketPolicy))
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func agentPanes(token: String) -> RelayTextResponse {
        do {
            let sender = try authenticatedSender(token: token)
            reconcileDelegations()
            let candidates = try panes()
                .filter { $0.kind.isAgent && $0.id != sender.id }
                .sorted {
                    let leftLocal = $0.workspaceID == sender.workspaceID
                    let rightLocal = $1.workspaceID == sender.workspaceID
                    if leftLocal != rightLocal { return leftLocal }
                    let leftWorkspace = ($0.workspaceName ?? $0.workspaceID).lowercased()
                    let rightWorkspace = ($1.workspaceName ?? $1.workspaceID).lowercased()
                    if leftWorkspace != rightWorkspace { return leftWorkspace < rightWorkspace }
                    let leftName = $0.displayName.lowercased()
                    let rightName = $1.displayName.lowercased()
                    if leftName != rightName { return leftName < rightName }
                    return $0.id < $1.id
                }
            consultationCondition.lock()
            let busy = Set(candidates.filter { targetHasTrackedWorkLocked($0.id) }.map(\.id))
            consultationCondition.unlock()
            let visible = candidates.prefix(RelayAgentPaneList.maximumPanes).map {
                RelayAgentPane(pane: $0, hasActiveHandoff: busy.contains($0.id))
            }
            return encodeAgentValue(RelayAgentPaneList(
                panes: Array(visible),
                truncated: candidates.count > RelayAgentPaneList.maximumPanes
            ))
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func agentEvents(token: String, since suppliedCursor: String) -> RelayTextResponse {
        do {
            _ = try authenticatedSender(token: token)
            let cursor = suppliedCursor.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:.")
            guard !cursor.isEmpty,
                  cursor.utf8.count <= 128,
                  cursor.unicodeScalars.allSatisfy(allowed.contains) else {
                throw BrokerFailure(status: 400, message: "events needs a valid cursor from an earlier response, 'beginning', or 'now'")
            }

            reconcileDelegations()
            consultationCondition.lock()
            let handoffs = Array(handoffRecords.values)
            let activities = Array(activityRecords.values) + Array(transientVendorEventRecords.values)
            let events = orderedAgentEventsLocked(handoffs: handoffs, activities: activities)
            consultationCondition.unlock()

            let start: Int
            switch cursor {
            case "beginning":
                start = 0
            case "now":
                start = events.count
            default:
                guard let index = events.firstIndex(where: { $0.cursor == cursor }) else {
                    throw BrokerFailure(
                        status: 410,
                        message: "that event cursor is no longer retained; restart from 'beginning' or 'now'"
                    )
                }
                start = events.index(after: index)
            }

            let end = min(events.count, start + RelayAgentEventPage.maximumEvents)
            let pageEvents = start < end ? Array(events[start..<end]) : []
            let nextCursor = pageEvents.last?.cursor
                ?? (cursor == "now" ? events.last?.cursor ?? "beginning" : cursor)
            return encodeAgentValue(RelayAgentEventPage(
                events: pageEvents,
                nextCursor: nextCursor,
                hasMore: end < events.count
            ))
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    private func encodeAgentValue<T: Encodable>(_ value: T) -> RelayTextResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return RelayTextResponse(status: 500, text: "could not encode agent discovery response")
        }
        return RelayTextResponse(status: 200, text: String(decoding: data, as: UTF8.self))
    }

    public func delegationStatus(token: String) -> RelayTextResponse {
        let sourceID: String
        do { sourceID = try authenticatedSender(token: token).id }
        catch let error as BrokerFailure { return RelayTextResponse(status: error.status, text: error.message) }
        catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
        reconcileDelegations()
        let livePanes = (try? panes()) ?? []
        consultationCondition.lock()
        let statuses = handoffRecords.values
            .filter { $0.kind == .delegate && $0.sourcePaneID == sourceID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { handoff in RelayDelegationStatus(handoff: handoff, target: livePanes.first { $0.id == handoff.targetPaneID }) }
        consultationCondition.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(statuses) else {
            return RelayTextResponse(status: 500, text: "could not encode delegation status")
        }
        return RelayTextResponse(status: 200, text: String(decoding: data, as: UTF8.self))
    }

    /// Compatibility entry point retained for native callers. Agent transport
    /// uses the broader tracked-work name because explicit ids may now name a
    /// Delegate or a recoverable Ask.
    public func waitForDelegation(token: String, handoffID requestedHandoffID: String) -> RelayTextResponse {
        waitForTrackedWork(token: token, handoffID: requestedHandoffID)
    }


    public private(set) var commandRuns: ReviewedCommandRunCoordinator?
    /// Native cleanup of finished worker artifacts, with a fresh lease check.
    /// Installed before transports start; never supplied by an agent request.
    public var deleteCommandRunArtifacts: ((Set<String>) throws -> Void)?
    /// Installed once by the native core before either transport starts.
    public func enableReviewedCommandRuns() {
        guard commandRuns == nil else { return }
        commandRuns = ReviewedCommandRunCoordinator(
            authenticate: { [credentials] in credentials.paneID(for: $0) },
            panes: panes,
            record: { [weak self] run in try self?.recordReviewedCommandRun(run) })
    }

    public private(set) var teamSessions: TeamSessionCoordinator?
    /// Installed once by the native core. Team authority never comes from the
    /// journal; sessions are recorded as native activity for visibility only.
    public func enableTeamSessions(profiles: @escaping () throws -> [PermissionProfileDefinition]) {
        guard teamSessions == nil else { return }
        teamSessions = TeamSessionCoordinator(
            authenticate: { [credentials] in credentials.paneID(for: $0) },
            panes: panes,
            profiles: profiles,
            record: { [weak self] session, transition, affected in try self?.recordTeamSessionEvent(session, transition: transition, affected: affected) })
    }

    /// Typed, app-owned transitions. The origin comes from the transition in
    /// trusted code; no transport payload can choose it. The durable detail
    /// deliberately carries labels and counts only: stop diagnostics can hold
    /// localized paths, so they stay in the session record and never enter
    /// activity records or the agent events feed (which omits detail anyway).
    private func recordTeamSessionEvent(_ session: TeamSession, transition: TeamSessionTransition, affected: [String]) throws {
        let kind: RelayActivityEventKind = switch transition {
        case .requested: .teamSessionRequested
        case .approved: .teamSessionApproved
        case .paneCreated: .teamPaneCreated
        case .stopAttempted: .teamPaneStopAttempted
        case .refused, .stopped, .expired, .interrupted: .teamSessionEnded
        }
        let created = session.members.count
        var detail = "\(transition.label). \(session.state.label); \(created) of \(session.paneLimit) pane\(session.paneLimit == 1 ? "" : "s") created."
        if transition == .stopAttempted, let attempt = session.stopAttempts.last { detail += " Outcomes: " + attempt.countsSummary + "." }
        _ = try recordActivity(RelayActivityEventRequest(
            kind: kind,
            workspaceID: session.source.workspaceID,
            workspaceName: session.source.workspaceName ?? session.source.workspaceID,
            paneID: session.source.id,
            paneName: session.source.displayName,
            paneKind: session.source.kind,
            detail: detail
        ), origin: transition.origin, teamSessionID: session.id, requesterPaneID: session.source.id, affectedPaneIDs: Array(affected.prefix(8)))
    }

    public func handleTeamRequest(token: String, body: String, idempotencyKey: String,
                                  onAccepted: (String) -> Void) -> RelayTextResponse {
        do {
            guard let teamSessions else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
            let proposal = try TeamSessionProposal.parse(arguments: try TeamSessionProposal.decodeArguments(body))
            let session = try teamSessions.request(token: token, proposal: proposal, idempotencyKey: idempotencyKey)
            onAccepted(session.id)
            return teamSessions.waitForDecision(token: token, id: session.id)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func handleTeamAdd(token: String, body: String, idempotencyKey: String,
                              onAccepted: (String) -> Void) -> RelayTextResponse {
        do {
            guard let teamSessions else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
            let parsed = try TeamPaneProvision.parse(arguments: try TeamSessionProposal.decodeArguments(body))
            let provision = try teamSessions.requestPane(token: token, kind: parsed.kind, name: parsed.name, role: parsed.role,
                idempotencyKey: idempotencyKey)
            onAccepted(provision.id)
            return teamSessions.waitForProvision(token: token, id: provision.id)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    public func handleTeamStatus(token: String) -> RelayTextResponse {
        guard let teamSessions else {
            return RelayTextResponse(status: 409, text: "The native team session service is unavailable.")
        }
        return teamSessions.status(token: token)
    }

    private func recordReviewedCommandRun(_ run: ReviewedCommandRun) throws {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        let state: RelayHandoffState = switch run.state {
        case .pending, .approved: .created
        case .running: .waiting
        case .completed: .completed
        case .rejected, .cancelled: .cancelled
        case .interrupted: .interrupted
        case .failed: .failed
        }
        let previous = handoffRecords[run.id]
        // Every launched run was recorded before execution. A missing record
        // now was cleared or pruned; a late capture must not recreate history.
        // Retention may keep an owned recovery copy; explicit deletion removes
        // that copy too and retains only a hash that refuses request replay.
        guard previous != nil || run.launchedAt == nil else { return }
        // A run the person proposed has no requesting pane: its source is
        // the person, recorded with an empty pane id and the Shell kind the
        // command runs as, so nothing ever attributes it to an agent.
        var handoff = RelayHandoff(id: run.id, idempotencyKey: run.idempotencyKey,
            kind: .commandRun, sourcePaneID: run.source?.id ?? "", sourceName: run.requesterName,
            sourceLaunchGeneration: run.source?.launchGeneration ?? 0, sourceKind: run.source?.kind ?? .shell,
            sourceWorkspaceID: run.workspaceID, sourceWorkspaceName: run.workspaceName,
            targetPaneID: run.shellPaneID, targetName: "New Shell for approved run", targetKind: .shell,
            targetWorkspaceID: run.workspaceID, targetWorkspaceName: run.workspaceName,
            text: "\(run.origin == .person ? "COMMAND RUN PROPOSED BY THE PERSON" : "REQUESTED COMMAND RUN")\nArgv: \(run.command.display)\nFolder: \(run.command.folder)\n\(ReviewedCommandRunCoordinator.trustDisclosure)",
            submitted: run.launchedAt != nil,
            resultText: run.result?.text, state: state, updatedAt: run.updatedAt,
            transitions: previous?.transitions ?? [])
        handoff.commandRun = run
        handoff.attention = run.state == .pending ? .permissionRequired : nil
        handoff.readAt = previous?.readAt
        handoff.transitions.append(RelayHandoffTransition(state: state, occurredAt: run.updatedAt, detail: run.detail))
        try handoffJournal?.recordDurably(handoff)
        handoffRecords[run.id] = handoff
        pruneHandoffsLocked()
        noteChangeLocked()

    }


    public func handleCommandRun(token: String, folder: String, body: String, idempotencyKey: String,
                                 onAccepted: (String) -> Void) -> RelayTextResponse {
        do {
            guard let commandRuns else { throw ReviewedCommandRunError.invalid("The native command-run service is unavailable.") }
            let sender = try authenticatedSender(token: token)
            consultationCondition.lock()
            let previous = handoffRecords.values.first {
                $0.kind == .commandRun && $0.sourcePaneID == sender.id
                    && $0.sourceLaunchGeneration == sender.launchGeneration && $0.idempotencyKey == idempotencyKey
            }
            consultationCondition.unlock()
            if let previous, !commandRuns.owns(id: previous.id) {
                return RelayTextResponse(status: 409, text: "This request already exists in history. It will not be executed again; inspect its recorded result.")
            }
            let run = try commandRuns.request(token: token, argv: ReviewedCommand.decodeArguments(body),
                folder: folder, idempotencyKey: idempotencyKey)
            onAccepted(run.id)
            return commandRuns.wait(token: token, id: run.id)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }
    }

    /// `parley wait`'s status when its window passes with the work still
    /// open. The shim hides it and asks again; it is never a result.
    public static let stillWaitingStatus = 102
    public static let stillWaiting = RelayTextResponse(status: stillWaitingStatus, text: "still waiting")

    /// Waits for one tracked item. With a window it is a bounded long-poll:
    /// when the window passes first it returns `stillWaiting`, so a waiter
    /// whose caller has gone holds its thread for one window at most. Nothing
    /// about the tracked work changes. Without a window it waits until the
    /// work ends, as native callers expect.
    public func waitForTrackedWork(token: String, handoffID requestedHandoffID: String, within window: TimeInterval? = nil) -> RelayTextResponse {
        let deadline = window.map { DispatchTime.now() + $0 }
        let source: WorkbenchPane
        do { source = try authenticatedSender(token: token) }
        catch let error as BrokerFailure { return RelayTextResponse(status: error.status, text: error.message) }
        catch { return RelayTextResponse(status: 403, text: error.localizedDescription) }
        if let commandRuns, commandRuns.owns(id: requestedHandoffID) { return commandRuns.wait(token: token, id: requestedHandoffID, until: deadline) }
        if let teamSessions, teamSessions.owns(id: requestedHandoffID) { return teamSessions.wait(token: token, id: requestedHandoffID, until: deadline) }
        consultationCondition.lock()
        let handoffID: String
        if requestedHandoffID.caseInsensitiveCompare("current") == .orderedSame {
            let matches = delegationRecords.keys.filter {
                handoffRecords[$0]?.sourcePaneID == source.id
                    && handoffRecords[$0]?.sourceLaunchGeneration == source.launchGeneration
            }
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
        guard let original = handoffRecords[handoffID],
              original.kind == .ask || original.kind == .delegate else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown tracked Ask or delegation")
        }
        guard original.sourcePaneID == source.id else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the initiating pane can wait for this tracked work")
        }
        guard let originalGeneration = original.sourceLaunchGeneration else {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "this tracked item predates generation-bound recovery and cannot be recovered by an agent"
            )
        }
        guard originalGeneration == source.launchGeneration else {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "this tracked item belongs to an earlier run of the initiating pane"
            )
        }
        consultationCondition.unlock()

        // Every broker change wakes every waiter; the pane read behind a
        // liveness check runs at most once per poll interval however often
        // this one is woken (review of 22 September 2026, 4b656187).
        var nextLivenessCheck = DispatchTime.now()
        while true {
            if original.kind == .delegate, DispatchTime.now() >= nextLivenessCheck {
                reconcileDelegation(handoffID)
                nextLivenessCheck = DispatchTime.now() + livenessPollInterval
            }
            consultationCondition.lock()
            guard let handoff = handoffRecords[handoffID] else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 404, text: "unknown tracked Ask or delegation")
            }
            let liveDelegationResponse = handoff.kind == .delegate ? delegationResponses[handoffID] : nil
            if let response = liveDelegationResponse ?? trackedWaitResponse(for: handoff) {
                consultationCondition.unlock()
                return response
            }
            if let deadline, DispatchTime.now() >= deadline {
                consultationCondition.unlock()
                return Self.stillWaiting
            }
            let untilCheck = original.kind == .delegate && DispatchTime.now() < nextLivenessCheck
                ? Double(nextLivenessCheck.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                : livenessPollInterval
            _ = consultationCondition.wait(until: Date().addingTimeInterval(max(0.001, min(livenessPollInterval, untilCheck))))
            consultationCondition.unlock()
        }
    }

    /// Submits one attributed question, then waits until its exact target
    /// returns an answer. Unlike relay, Ask also owns the response route.
    public func handleAsk(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String? = nil,
        onAccepted: ((String) -> Void)? = nil
    ) -> RelayTextResponse {
        handleAsk(
            token: token,
            target: requestedTarget,
            text: text,
            idempotencyKey: suppliedIdempotencyKey,
            humanInitiated: false,
            preserveFormatting: false,
            transitionOrigin: nil,
            onAccepted: onAccepted
        )
    }

    private func handleAsk(
        token: String,
        target requestedTarget: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String?,
        humanInitiated: Bool,
        preserveFormatting: Bool,
        transitionOrigin: RelayTransitionOrigin? = nil,
        inReplyToHandoffID: String? = nil,
        relationship: RelayHandoffRelationship? = nil,
        onSubmitted: (() -> Void)? = nil,
        onAccepted: ((String) -> Void)? = nil,
        reviewedVoice: VoiceHandoffRequest? = nil,
        onWriterFailed: ((Error) -> Void)? = nil,
        deliveredImages: [ContextPackImage] = []
    ) -> RelayTextResponse {
        let recordedOrigin = transitionOrigin ?? (humanInitiated ? .human : nil)
        let sender: WorkbenchPane
        let target: WorkbenchPane
        let idempotencyKey: String
        let targetCredential: String
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
            if let reviewedVoice {
                _ = try reviewedVoice.source.resolve(in: [sender])
                _ = try reviewedVoice.target.resolve(in: [target])
            }
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
            return RelayTextResponse(status: 400, text: RelayText.tooLong("question", count: cleaned.count))
        }

        let scope = IdempotencyScope(senderPaneID: sender.id, key: idempotencyKey)
        let signature = [RelayHandoffKind.ask.rawValue, target.id, cleaned, inReplyToHandoffID ?? "", relationship?.rawValue ?? ""].joined(separator: "\u{1f}")

        consultationCondition.lock()
        if inReplyToHandoffID != nil || relationship != nil {
            guard humanInitiated,
                  let parentID = inReplyToHandoffID,
                  relationship != nil else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 400, text: "review lineage requires one human-authorized parent and purpose")
            }
            guard let parent = handoffRecords[parentID] else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 404, text: "unknown parent handoff")
            }
            guard (parent.kind == .ask || parent.kind == .delegate), parent.hasReturnedResult else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "Challenge and Verify require a returned Ask or Delegate result")
            }
        }
        if let existing = idempotencyRecords[scope] {
            guard existing.signature == signature else {
                consultationCondition.unlock()
                return RelayTextResponse(status: 409, text: "that idempotency key belongs to a different handoff")
            }
            let handoffID = existing.handoffID
            consultationCondition.unlock()
            onAccepted?(handoffID)
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

        var handoff = makeHandoff(
            idempotencyKey: idempotencyKey,
            kind: .ask,
            sender: sender,
            target: target,
            inReplyToHandoffID: inReplyToHandoffID,
            relationship: relationship,
            text: cleaned,
            submitted: true,
            origin: recordedOrigin
        )
        if !deliveredImages.isEmpty { handoff.deliveredImages = deliveredImages }
        handoff.submissionStartedAt = clock()
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
        noteChangeLocked()
        consultationCondition.unlock()

        do {
            let writer = preserveFormatting ? contextSubmit : submit
            if let reviewedVoice {
                try submitVoice(reviewedVoice, text: consultationPrompt(for: consultation))
            } else {
                try writer(target.id, consultationPrompt(for: consultation))
            }
            consultationCondition.lock()
            if let active = consultationRecords[handoff.id], active.completion == nil {
                transitionHandoffLocked(handoff.id, to: .delivered, origin: recordedOrigin)
                transitionHandoffLocked(handoff.id, to: .waiting, origin: recordedOrigin)
            }
            onSubmitted?()
            noteChangeLocked()
            consultationCondition.unlock()
            onAccepted?(handoff.id)
        } catch {
            // Whether input began is the writer's to say
            // (`ParleyWorkbenchError.refusedBeforeInput`); a context send
            // decides from it whether its draft may be sent again.
            onWriterFailed?(error)
            let response = RelayTextResponse(
                status: 409,
                text: "Parley could not submit the question: \(error.localizedDescription)"
            )
            consultationCondition.lock()
            if case let .ask(completed)? = idempotencyRecords[scope]?.response {
                consultationCondition.unlock()
                return completed
            }
            transitionHandoffLocked(
                handoff.id,
                to: .failed,
                detail: response.text,
                failure: failureAssessment(kind: .ask, error: error),
                origin: recordedOrigin
            )
            idempotencyRecords[scope]?.response = .ask(response)
            consultationRecords.removeValue(forKey: consultation.id)
            pruneHandoffsLocked()
            noteChangeLocked()
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
            preserveFormatting: false,
            transitionOrigin: nil
        )
    }

    private func handleAskMany(
        token: String,
        targets requestedTargets: String,
        text: String,
        idempotencyKey suppliedIdempotencyKey: String?,
        humanInitiated: Bool,
        preserveFormatting: Bool,
        transitionOrigin: RelayTransitionOrigin?,
        images: [ContextPackImage] = []
    ) -> RelayTextResponse {
        let cleaned = preserveFormatting
            ? ContextPackText.normalize(text)
            : RelayText.clean(text)
        guard !cleaned.isEmpty else { return RelayTextResponse(status: 400, text: "nothing to ask") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: RelayText.tooLong("question", count: cleaned.count))
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
            // Each child blocks until its target answers, so it gets a thread
            // of its own rather than one from the shared pool (RelayWorkerThread).
            RelayWorkerThread.start(name: "parley.relay.ask-many") { [self] in
                defer { group.leave() }
                let childKey = askManyChildKey(root: rootKey, targetPaneID: route.pane.id)
                let response = handleAsk(
                    token: token,
                    target: route.pane.id,
                    text: cleaned,
                    idempotencyKey: childKey,
                    humanInitiated: humanInitiated,
                    preserveFormatting: preserveFormatting,
                    transitionOrigin: transitionOrigin,
                    deliveredImages: images
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
        preserveFormatting: Bool = false,
        origin: RelayTransitionOrigin = .human,
        images: [ContextPackImage] = []
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
        if let refusal = personImagesRefusal(images) { return refusal }
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
            preserveFormatting: preserveFormatting,
            transitionOrigin: origin,
            images: images
        )
    }

    /// Creates one Delegate child linked to a returned Delegate result from the
    /// native Request Changes action. It is native-control-only and
    /// human-authorized, uses the source pane's own credential through the
    /// ordinary delegate path, and is subject to the same parent, target and
    /// busy rules. It never records a verdict.
    public func handleRequestChangesFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        inReplyToHandoffID: String
    ) -> RelayResponse {
        let livePanes: [WorkbenchPane]
        do {
            livePanes = try panes()
        } catch {
            return failure(409, error.localizedDescription)
        }
        guard let source = livePanes.first(where: { $0.id == sourcePaneID }), source.kind.isAgent else {
            return failure(400, "unknown source agent pane")
        }
        let sourceToken: String
        do {
            sourceToken = try credentials.token(for: source.id)
        } catch {
            return failure(409, "could not resolve the source pane credential: \(error.localizedDescription)")
        }
        return handleDelegate(
            token: sourceToken,
            target: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            inReplyToHandoffID: inReplyToHandoffID,
            humanInitiated: true,
            preserveFormatting: true
        )
    }

    /// Creates one normal correlated Ask linked to one completed result. This
    /// route is native-control-only; pane credentials cannot manufacture review
    /// lineage or choose a parent on their own.
    public func handleReviewAskFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        inReplyToHandoffID: String,
        relationship: RelayHandoffRelationship
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
            return RelayTextResponse(
                status: 409,
                text: "could not resolve the source pane credential: \(error.localizedDescription)"
            )
        }
        return handleAsk(
            token: sourceToken,
            target: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            humanInitiated: true,
            preserveFormatting: true,
            transitionOrigin: .human,
            inReplyToHandoffID: inReplyToHandoffID,
            relationship: relationship
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
        preserveFormatting: Bool = false,
        origin: RelayTransitionOrigin = .human,
        images: [ContextPackImage] = []
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
        if let refusal = personImagesRefusal(images) { return refusal }
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
            preserveFormatting: preserveFormatting,
            transitionOrigin: origin,
            deliveredImages: images
        )
    }

    /// Native-control-only entry to the existing Ask/Delegate paths. Snapshots
    /// are checked against the panes resolved for this actual handoff.
    public func handleVoiceHandoffFromUI(_ request: VoiceHandoffRequest) -> RelayTextResponse {
        do {
            let live = try panes()
            _ = try request.source.resolve(in: live)
            _ = try request.target.resolve(in: live)
            let token = try credentials.token(for: request.source.paneID)
            switch request.kind {
            case .ask:
                return handleAsk(token: token, target: request.target.paneID, text: request.text,
                    idempotencyKey: request.idempotencyKey, humanInitiated: true, preserveFormatting: false,
                    reviewedVoice: request)
            case .delegate:
                let response = handleDelegate(token: token, target: request.target.paneID, text: request.text,
                    idempotencyKey: request.idempotencyKey, humanInitiated: true, reviewedVoice: request)
                return RelayTextResponse(status: response.status, text: String(decoding: try JSONEncoder().encode(response.body), as: UTF8.self))
            }
        } catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
    }

    private func submitVoice(_ request: VoiceHandoffRequest, text: String) throws {
        guard let voiceSubmit else { throw VoiceError.unavailable("Reviewed voice delivery is unavailable.") }
        try voiceSubmit(request, text)
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
        let images = request.images ?? []
        if let refusal = personImagesRefusal(images) { return refusal }

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
        var draft = ReviewedBusyDraft(
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
        if !images.isEmpty { draft.images = images }
        do {
            try busyDraftStore.record(draft)
            noteChange()
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

        // The queued draft has kept its images; each copy must still be intact.
        // Checked before the draft leaves the queue, so a refusal changes
        // nothing (Codex's review of MR !142: checked after, a failed restore
        // left it dispatching while the reply said queued).
        if let images = existing.images, images.contains(where: { image in (try? contextImageStore?.data(for: image)) == nil }) {
            return RelayTextResponse(status: 409, text: "an image in the queued draft is no longer kept, so nothing was sent; the draft remains queued")
        }

        let normalized = request.preserveFormatting
            ? ContextPackText.normalize(request.text)
            : RelayText.clean(request.text)
        // Refused before the edited text is stored, so the queued draft keeps
        // what the person last saved.
        guard normalized.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: RelayText.tooLong("reviewed draft", count: normalized.count))
        }
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
            noteChangeLocked() // the draft is now dispatching
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

        let images = dispatching.images ?? []
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
            },
            deliveredImages: images
        )
        if !submitted {
            try? busyDraftStore.restoreQueued(
                id: dispatching.id,
                detail: "The explicit send did not reach terminal submission: \(response.text)"
            )
        }
        // Either the draft was removed on submission or restored to queued;
        // both are visible to the relay tick. The lock is not held here.
        noteChange()
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
            if !(draft.images ?? []).isEmpty { collectUnreferencedImagesLocked() }
            noteChangeLocked()
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
        let senderID: String
        do { senderID = try authenticatedSender(token: token).id }
        catch let error as BrokerFailure { return RelayTextResponse(status: error.status, text: error.message) }
        catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
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

    public func stateRevision() -> UInt64 {
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        return changeRevision
    }

    /// Call with `consultationCondition` held: records a state change and
    /// wakes waiters, which is what every broadcast site already meant.
    private func noteChangeLocked() {
        changeRevision &+= 1
        consultationCondition.broadcast()
    }

    /// For the few mutations that happen outside the condition lock.
    private func noteChange() {
        consultationCondition.lock()
        noteChangeLocked()
        consultationCondition.unlock()
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

    /// Every handoff not yet in a terminal state, however much history there
    /// is: the active-work checks must not depend on the history window.
    public func activeHandoffs() -> [RelayHandoff] {
        reconcileDelegations()
        consultationCondition.lock()
        let values = handoffRecords.values
            .filter(\.state.isActive)
            .sorted { $0.updatedAt > $1.updatedAt }
        consultationCondition.unlock()
        return values
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
    /// The native control route: every event it records is a human action.
    public func recordActivity(_ request: RelayActivityEventRequest) throws -> RelayActivityEvent {
        try recordActivity(request, origin: .human, teamSessionID: nil, requesterPaneID: nil, affectedPaneIDs: nil)
    }

    /// Trusted in-process callers only; the origin is never a request field.
    private func recordActivity(_ request: RelayActivityEventRequest, origin: RelayTransitionOrigin, teamSessionID: String?,
                                requesterPaneID: String?, affectedPaneIDs: [String]?) throws -> RelayActivityEvent {
        let workspaceID = request.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceName = request.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty, !workspaceName.isEmpty else { throw RelayActivityError.invalidEvent }
        let event = RelayActivityEvent(
            kind: request.kind,
            occurredAt: clock(),
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            paneID: request.paneID,
            paneName: request.paneName,
            paneKind: request.paneKind,
            detail: request.detail,
            origin: origin,
            teamSessionID: teamSessionID,
            requesterPaneID: requesterPaneID,
            affectedPaneIDs: affectedPaneIDs
        )
        try activityJournal?.record(event)
        consultationCondition.lock()
        activityRecords[event.id] = event
        if let retainedIDs = activityJournal.map({ Set($0.events().map(\.id)) }) {
            activityRecords = activityRecords.filter { retainedIDs.contains($0.key) }
        } else {
            pruneActivityRecordsLocked()
        }
        noteChangeLocked()
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
        // Serialize policy changes and broker projections; each journal also
        // serializes its own appends. Publish the committed preference even
        // if one journal cannot be compacted;
        // every successful partial mutation must be reconciled and disclosed.
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        try historyRetentionStore?.save(policy)
        var failures: [String] = []
        var durableHandoffRemoval: Int?
        var durableActivityRemoval: Int?
        do { durableHandoffRemoval = try handoffJournal?.updateMaximumHandoffs(maximumRecords) }
        catch { failures.append("handoffs: \(error.localizedDescription)") }
        do { durableActivityRemoval = try activityJournal?.updateMaximumEvents(maximumRecords) }
        catch { failures.append("activity: \(error.localizedDescription)") }
        let handoffCountBefore = handoffRecords.count
        let activityCountBefore = activityRecords.count
        historyRetentionPolicy = policy
        if let retainedIDs = handoffJournal.map({ Set($0.handoffs().map(\.id)) }) {
            let removedHandoffs = handoffRecords.values.filter { !retainedIDs.contains($0.id) }
            handoffRecords = handoffRecords.filter { retainedIDs.contains($0.key) }
            collectAfterRemovingHandoffsLocked(removedHandoffs)
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
        noteChangeLocked()
        let change = CollaborationHistoryRetentionChange(
            policy: policy,
            removedHandoffs: durableHandoffRemoval ?? inMemoryHandoffRemoval,
            removedActivityEvents: durableActivityRemoval ?? inMemoryActivityRemoval
        )
        if !failures.isEmpty {
            throw CollaborationHistoryRetentionPartialFailure(change: change, failures: failures)
        }
        return change
    }

    /// Saves a person's review of one returned result. The core-control route
    /// supplies the exact revision shown in Status Center so an older inspector
    /// cannot overwrite a newer verdict or note.
    public func updateHandoffReview(_ request: RelayHandoffReviewUpdate) -> RelayTextResponse {
        let note = ContextPackText.normalize(request.note)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= 4_000 else {
            return RelayTextResponse(status: 400, text: "human review note is too long")
        }

        consultationCondition.lock()
        guard var handoff = handoffRecords[request.handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        guard (handoff.kind == .ask || handoff.kind == .delegate), handoff.hasReturnedResult else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "only a returned Ask or Delegate result can be reviewed")
        }
        guard (handoff.reviewRevision ?? 0) == request.expectedReviewRevision else {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "this handoff changed after the review editor opened; review the current record and try again"
            )
        }

        handoff.humanVerdict = request.verdict
        handoff.humanReviewNote = note.isEmpty ? nil : note
        let hasReview = handoff.humanVerdict != nil || handoff.humanReviewNote != nil
        let now = Date()
        handoff.reviewedAt = hasReview ? now : nil
        handoff.reviewRevision = (handoff.reviewRevision ?? 0) + 1
        do {
            try handoffJournal?.recordDurably(handoff)
        } catch {
            consultationCondition.unlock()
            return RelayTextResponse(status: 500, text: "Human review could not be saved: \(error.localizedDescription)")
        }
        handoffRecords[handoff.id] = handoff
        noteChangeLocked()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: hasReview ? "Human review saved." : "Human review cleared.")
    }

    /// Records that a person viewed a returned result, or saw a failed,
    /// interrupted or waiting handoff (`canBeAcknowledged`), so it stops
    /// counting as needing them. This is exposed only through the UI
    /// control-token route; pane credentials cannot clear another pane's
    /// badge. Repeated acknowledgement is intentionally idempotent and does
    /// not reorder the handoff's operational timeline.
    public func markHandoffRead(_ handoffID: String) -> RelayTextResponse {
        consultationCondition.lock()
        guard var handoff = handoffRecords[handoffID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown handoff")
        }
        guard handoff.canBeAcknowledged else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "this handoff has no result, failure or request to acknowledge")
        }
        if handoff.readAt == nil {
            handoff.readAt = Date()
            handoffRecords[handoffID] = handoff
            handoffJournal?.record(handoff)
            noteChangeLocked()
        }
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: handoff.hasReturnedResult ? "Result marked read." : "Marked seen.")
    }

    /// Explicit native control action; an empty workspace identifier never
    /// means All Workspaces on the separate workspace-scoped route.
    public func deleteAllHistory() -> RelayTextResponse {
        deleteHistory(workspaceID: nil, workspaceName: nil)
    }

    /// Clears terminal history involving one exact workspace. Active work is
    /// preserved, and a supplied stable id takes precedence over display names.
    public func deleteWorkspaceHistory(
        workspaceID: String,
        workspaceName: String? = nil
    ) -> RelayTextResponse {
        let requestedID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestedID.isEmpty || !requestedName.isEmpty else {
            return RelayTextResponse(status: 400, text: "workspace id or name is required")
        }
        return deleteHistory(workspaceID: requestedID, workspaceName: requestedName)
    }

    private func deleteHistory(workspaceID: String?, workspaceName: String?) -> RelayTextResponse {
        var response = RelayTextResponse(status: 500, text: "history deletion did not complete")
        func clear(_ runs: [ReviewedCommandRun]) -> Set<String> {
            let active = Set(runs.filter { !$0.state.isTerminal || $0.workerStillRunning }.map(\.id))
            var removed: Set<String> = []
            response = deleteHistoryRecords(workspaceID: workspaceID, workspaceName: workspaceName,
                activeCommandRunIDs: active, finishedCommandRuns: runs.filter { $0.state.isTerminal && !$0.workerStillRunning },
                removedHandoffIDs: &removed)
            return removed
        }
        if let commandRuns { commandRuns.withHistoryDeletion(clear) }
        else { _ = clear([]) }
        return response
    }

    private func deleteHistoryRecords(workspaceID: String?, workspaceName: String?,
                                      activeCommandRunIDs: Set<String>, finishedCommandRuns: [ReviewedCommandRun],
                                      removedHandoffIDs: inout Set<String>) -> RelayTextResponse {
        func matches(_ id: String, _ name: String?) -> Bool {
            guard let workspaceID else { return true }
            if !workspaceID.isEmpty { return id == workspaceID }
            return name?.caseInsensitiveCompare(workspaceName ?? "") == .orderedSame
        }
        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        consultationCondition.lock()
        defer { consultationCondition.unlock() }
        let protectedReviews = contextReviewRecords.values.filter { !$0.state.canDelete }
        var removalIDs = Set(handoffRecords.values.lazy.filter { handoff in
            terminalStates.contains(handoff.state)
                && !protectedReviews.contains(where: { $0.isLinked(to: handoff) })
                && !activeCommandRunIDs.contains(handoff.id)
                && (matches(handoff.sourceWorkspaceID, handoff.sourceWorkspaceName)
                    || matches(handoff.targetWorkspaceID, handoff.targetWorkspaceName))
        }.map(\.id))
        // The recovery cache can outlive journal retention. Include finished
        // cached runs whose history is already absent, without widening scope.
        let orphanedRunIDs = Set(finishedCommandRuns.filter {
            handoffRecords[$0.id] == nil && matches($0.workspaceID, $0.workspaceName)
        }.map(\.id))
        removalIDs.formUnion(orphanedRunIDs)
        let activityRemovalIDs = Set(activityRecords.values.lazy.filter {
            matches($0.workspaceID, $0.workspaceName)
        }.map(\.id))

        let removedHandoffs = handoffRecords.values.filter { removalIDs.contains($0.id) }
        let reviewRemovalIDs = Set(contextReviewRecords.values.filter { review in
            guard review.state.canDelete else { return false }
            if workspaceID == nil { return true }
            if let id = review.sourceWorkspaceID, matches(id, review.sourceWorkspaceName) { return true }
            // Older reviews did not record a workspace. Use a durable handoff
            // link, never today's mutable pane folder or display name.
            return removedHandoffs.contains { review.isLinked(to: $0) }
        }.map(\.id))
        do {
            let runIDs = Set(removedHandoffs.filter { $0.kind == .commandRun }.map(\.id)).union(orphanedRunIDs)
            if !runIDs.isEmpty { try deleteCommandRunArtifacts?(runIDs) }
        } catch {
            return RelayTextResponse(status: 500, text: "Command worker files could not be cleared; history was kept: \(error.localizedDescription)")
        }
        do { try deleteContextReviewsLocked(ids: reviewRemovalIDs) }
        catch { return RelayTextResponse(status: 500, text: "Parley could not clear stored context; history was kept: \(error.localizedDescription)") }
        do {
            try handoffJournal?.removeHandoffs(ids: removalIDs)
        } catch {
            return RelayTextResponse(status: 500, text: "Deleted \(reviewRemovalIDs.count) saved context records, but collaboration history could not be cleared: \(error.localizedDescription)")
        }
        // Reflect each successful journal compaction immediately. If clearing
        // activity fails next, the already-cleared handoffs must not reappear.
        handoffRecords = handoffRecords.filter { !removalIDs.contains($0.key) }
        collectAfterRemovingHandoffsLocked(Array(removedHandoffs))
        removedHandoffIDs = removalIDs
        if !removalIDs.isEmpty { noteChangeLocked() }
        idempotencyRecords = idempotencyRecords.filter { !removalIDs.contains($0.value.handoffID) }
        delegationResponses = delegationResponses.filter { !removalIDs.contains($0.key) }
        do {
            try activityJournal?.removeEvents(ids: activityRemovalIDs)
        } catch {
            return RelayTextResponse(status: 500,
                text: "Cleared \(removalIDs.count) collaboration records, but activity history could not be cleared: \(error.localizedDescription). Active work was preserved.")
        }
        activityRecords = activityRecords.filter { !activityRemovalIDs.contains($0.key) }
        transientVendorEventRecords = transientVendorEventRecords.filter { _, event in
            !matches(event.workspaceID, event.workspaceName)
        }
        let removedCount = removalIDs.count + activityRemovalIDs.count
        if removedCount > 0 { noteChangeLocked() }
        return RelayTextResponse(status: 200,
            text: "Cleared \(removedCount) history records and \(reviewRemovalIDs.count) saved context records. Waiting approvals and deliveries in progress were preserved. Project files were unchanged.")
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
        let sourceID: String
        do { sourceID = try authenticatedSender(token: token).id }
        catch let error as BrokerFailure { return RelayTextResponse(status: error.status, text: error.message) }
        catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
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
        case .commandRun:
            consultationCondition.unlock()
            guard origin != nil else { return RelayTextResponse(status: 403, text: "Command runs can be cancelled by the person in Parley.") }
            do { try commandRuns?.cancel(id: handoffID, reason: message); return RelayTextResponse(status: 200, text: "Cancellation requested for the owned command.") }
            catch { return RelayTextResponse(status: 409, text: error.localizedDescription) }
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
            if let record = delegationRecords[handoffID] {
                cancelledDelegationRuns[handoff.targetPaneID] = record.targetCredential
            }
            transitionHandoffLocked(handoffID, to: .cancelled, detail: message, origin: origin)
            delegationRecords.removeValue(forKey: handoffID)
            delegationResponses[handoffID] = RelayTextResponse(status: 409, text: message)
            pruneHandoffsLocked()
            noteChangeLocked()
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
            case .commandRun:
                "An approved command cannot be replayed from history. Submit a new request for approval."
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
                origin: .human,
                allowsSafeRetry: true
            )
            noteChangeLocked()
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
            origin: .human,
            allowsSafeRetry: true
        )
        noteChangeLocked()
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
            noteChangeLocked()
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
            noteChangeLocked()
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "Retry failed: \(error.localizedDescription)")
        }
    }

    public func cancelAll(reason: String = "Parley stopped before the consultation completed.") {
        commandRuns?.stop(reason: reason, permanently: false)
        consultationCondition.lock()
        let response = RelayTextResponse(status: 409, text: reason)
        for id in Array(consultationRecords.keys) {
            finishAskLocked(handoffID: id, state: .interrupted, response: response)
        }
        for id in Array(delegationRecords.keys) {
            finishDelegationLocked(handoffID: id, state: .interrupted, detail: reason)
        }
        for (id, var review) in contextReviewRecords where review.state == .awaitingReview {
            review.state = .interrupted
            review.updatedAt = Date()
            review.detail = reason
            contextReviewRecords[id] = review
            _ = persistContextRealityLocked(review)
            noteChangeLocked()
        }
        consultationCondition.broadcast()
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
            case .commandRun: "reviewed command requests"
            }
            throw BrokerFailure(
                status: 403,
                message: "The \(sender.workspaceName ?? "workspace") automation policy does not allow \(operation). Change it from Parley's workspace menu."
            )
        }
    }

    private func route(token: String, requestedTarget: String) throws -> (WorkbenchPane, WorkbenchPane) {
        let sender = try authenticatedSender(token: token)
        let livePanes = try panes()
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

    /// Explains a consultation that no longer exists to the pane that was its
    /// target. A target that finished slow work and answered deserves to know
    /// the question closed, rather than a bare "unknown consultation" that
    /// reads like a fault and invites a retry that can never be accepted.
    ///
    /// Only the pane that was asked learns anything. Any other caller keeps the
    /// bare refusal, and a handoff Parley no longer retains is not guessed at.
    private func retiredConsultationDetailLocked(_ consultationID: String, senderID: String) -> String? {
        guard let handoff = handoffRecords[consultationID],
              handoff.kind == .ask,
              handoff.targetPaneID == senderID else { return nil }
        let closedAt = handoff.transitions.last { $0.state == handoff.state }?.occurredAt ?? handoff.updatedAt
        let formatter = ISO8601DateFormatter()
        // An Ask fails for more than a timeout (its target's pane closed or
        // restarted); the transition that closed it says which.
        let closing = handoff.transitions.last { $0.state == handoff.state }?.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String = switch handoff.state {
        case .failed, .interrupted:
            if let closing, !closing.isEmpty {
                "ended without an answer (\(closing.hasSuffix(".") ? String(closing.dropLast()) : closing))"
            } else {
                handoff.state == .failed ? "ended without an answer" : "was interrupted"
            }
        case .cancelled: "was cancelled"
        case .completed: "already has an answer"
        default: "is no longer awaiting an answer"
        }
        return "This consultation \(reason) at \(formatter.string(from: closedAt)). "
            + "Your answer was not accepted or delivered, and retrying will not reopen it."
    }

    /// `current` is refused for a pane whose run had a delegation cancelled:
    /// the report may be for that one, and `current` would give it to a later
    /// delegation. The id always works.
    private func ambiguousCurrentDelegationLocked(senderID: String, token: String) -> RelayTextResponse? {
        guard cancelledDelegationRuns[senderID] == token else { return nil }
        return RelayTextResponse(
            status: 409,
            text: "A delegation to this pane was cancelled while this run may still have been working on it, so `current` could name the wrong one. Name the delegation's id instead: parley done <id>, parley fail <id> or parley progress <id>, with the id its prompt gave."
        )
    }

    /// Why a report naming this delegation is refused, told only to the pane
    /// it was delegated to: a closed delegation never reopens, and a report
    /// for it must never land on a later one (review of 22 Sep 2026, M4).
    private func retiredDelegationDetailLocked(_ handoffID: String, senderID: String) -> String? {
        guard let handoff = handoffRecords[handoffID],
              handoff.kind == .delegate,
              handoff.targetPaneID == senderID else { return nil }
        let closedAt = handoff.transitions.last { $0.state == handoff.state }?.occurredAt ?? handoff.updatedAt
        let reason = switch handoff.state {
        case .completed: "already has a result"
        case .cancelled: "was cancelled"
        case .failed: "already ended as failed"
        case .interrupted: "was interrupted"
        default: "is no longer awaiting a result"
        }
        return "This delegation \(reason) at \(ISO8601DateFormatter().string(from: closedAt)). "
            + "Your report was not accepted or returned, and retrying will not reopen it."
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
            return RelayTextResponse(status: 400, text: RelayText.tooLong("answer", count: cleaned.count))
        }

        consultationCondition.lock()
        guard var record = consultationRecords[consultationID] else {
            let detail = retiredConsultationDetailLocked(consultationID, senderID: senderID)
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: detail ?? "unknown consultation")
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
        noteChangeLocked()
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
        // See waitForTrackedWork: at most one liveness check per interval.
        var nextLivenessCheck = DispatchTime.now()

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

            // Sleep only until the next liveness check is due, so a failure is
            // noticed within one poll interval, not two.
            let untilCheck = DispatchTime.now() < nextLivenessCheck
                ? Double(nextLivenessCheck.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                : 0
            let pollDeadline = min(deadline, now.addingTimeInterval(max(0.001, min(livenessPollInterval, untilCheck))))
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
            guard DispatchTime.now() >= nextLivenessCheck else { continue }
            nextLivenessCheck = DispatchTime.now() + livenessPollInterval
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
        guard livePanes.contains(where: { $0.id == consultation.sourcePaneID && $0.isStarted && !$0.isDead }) else {
            return AskLivenessFailure(
                state: .interrupted,
                status: 409,
                message: "The consultation stopped because the requesting pane closed."
            )
        }
        guard livePanes.contains(where: { $0.id == consultation.targetPaneID && $0.isStarted && !$0.isDead }) else {
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
        noteChangeLocked()
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
        parley answer \(consultation.id) "your answer"

        If Parley's instructions are missing, run `parley protocol` (or `"$PARLEY_COMMAND" protocol` when PATH changed). Vendor tool approval still applies.

        For a multiline answer, pipe the text to `parley answer \(consultation.id)`. That id names this exact question; use it verbatim. Do not substitute `current`, which resolves to whichever question this pane holds when the command runs and may by then be a later one. Do not only print the answer in this pane; the requester is blocked waiting for that command.
        """
    }

    private func delegationPrompt(for handoff: RelayHandoff) -> String {
        let heading = if let parentID = handoff.inReplyToHandoffID, handoff.relationship == .requestChanges {
            "\(handoff.sourceName) requested changes on an earlier delegation (Parley handoff \(parentID)):"
        } else {
            "\(handoff.sourceName) delegated work:"
        }
        let id = handoff.id
        return """
        \(heading)

        \(handoff.text)

        When the work is complete, return a concise completion report to \(handoff.sourceName) by running:
        parley done \(id) "your completion report"

        For a substantial result file of at most \(ContextPackBuilder.defaultMaximumPartBytes) UTF-8 bytes inside this pane's working folder, stage it for explicit human review by running:
        parley done \(id) --file <path>
        In that file, plain Markdown headings ## Implemented, ## Tested (each command and its outcome) and ## Unable to test (with the reason) are shown to the person as agent-declared completion evidence; nothing in it is checked by Parley.

        At each milestone, replace the one agent-declared progress note of at most \(DelegationProgressText.maximumBytes) UTF-8 bytes visible to \(handoff.sourceName) by running:
        parley progress \(id) "what changed"

        If the work cannot be completed, return the blocking reason by running:
        parley fail \(id) "why the work failed"

        If Parley's instructions are missing, run `parley protocol` (or `"$PARLEY_COMMAND" protocol` when PATH changed). Vendor tool approval still applies.

        For a multiline report, pipe the text to `parley done \(id)` or `parley fail \(id)`. That id names this exact delegation; use it verbatim. Do not substitute `current`, which resolves to whichever delegation this pane holds when the command runs and may by then be a later one. A returned file is not forwarded automatically. Do not only print the result in this pane; the initiating agent may use `parley wait` for the structured outcome.
        """
    }

    private func reconcileDelegations() {
        // Read what there is to reconcile before asking for panes. This runs on
        // ordinary history reads, and `panes()` takes the workbench controller's
        // lock across the whole document model, so with no delegations in flight
        // — the usual state — it was contending for a lock to iterate nothing.
        consultationCondition.lock()
        let ids = Array(delegationRecords.keys)
        consultationCondition.unlock()
        guard !ids.isEmpty else { return }
        guard let livePanes = try? panes() else { return }
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
        guard livePanes.contains(where: { $0.id == handoff.sourcePaneID && $0.isStarted && !$0.isDead }) else {
            return AskLivenessFailure(
                state: .interrupted,
                status: 409,
                message: "The delegation stopped because the initiating pane closed."
            )
        }
        guard livePanes.contains(where: { $0.id == handoff.targetPaneID && $0.isStarted && !$0.isDead }) else {
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

    /// Reads Git facts for the pane reporting a result. Called without the
    /// coordination lock; it takes the lock only briefly to learn whether the
    /// pane has tracked work, so a bogus report never runs Git.
    private func gitFactsForReportingPane(_ paneID: String) -> DelegationGitSnapshot? {
        guard gitFacts != nil else { return nil }
        consultationCondition.lock()
        let hasTrackedWork = delegationRecords.keys.contains { handoffRecords[$0]?.targetPaneID == paneID }
        consultationCondition.unlock()
        guard hasTrackedWork,
              let pane = (try? panes())?.first(where: { $0.id == paneID }) else { return nil }
        return gitFactsSnapshot(for: pane)
    }

    /// Informational Git facts for the delegated pane's reviewed folder. A
    /// container pane gets an explicit not-captured record and no Git at
    /// all: its container can rewrite that checkout's Git configuration, and
    /// a delegation to it or its own report must not be what makes Parley
    /// run Git over that configuration on this Mac.
    private func gitFactsSnapshot(for pane: WorkbenchPane) -> DelegationGitSnapshot? {
        guard let gitFacts else { return nil }
        if pane.containerConfiguration != nil {
            return .notCaptured(folder: pane.launchWorkingDirectory, capturedAt: clock(), reason: DelegationGitSnapshot.containerPaneReason)
        }
        return gitFacts(pane.launchWorkingDirectory)
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
        noteChangeLocked()
    }

    private func trackedWaitResponse(for handoff: RelayHandoff) -> RelayTextResponse? {
        switch handoff.state {
        case .completed:
            let fallback = handoff.kind == .ask
                ? "The Ask completed without a retained answer."
                : "Delegated work completed."
            return RelayTextResponse(status: 200, text: handoff.resultText ?? fallback)
        case .cancelled, .failed, .interrupted:
            let fallback = handoff.kind == .ask
                ? "The Ask ended without an answer."
                : "Delegated work ended without a completion report."
            return RelayTextResponse(
                status: 409,
                text: handoff.resultText ?? handoff.transitions.last?.detail ?? fallback
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
        inReplyToHandoffID: String? = nil,
        relationship: RelayHandoffRelationship? = nil,
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
            sourceLaunchGeneration: sender.launchGeneration,
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
            inReplyToHandoffID: inReplyToHandoffID,
            relationship: relationship,
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
        origin: RelayTransitionOrigin? = nil,
        allowsSafeRetry: Bool = false
    ) {
        guard var handoff = handoffRecords[handoffID] else { return }
        let explicitRetry = allowsSafeRetry && handoff.canRetrySafely
            && handoff.state == .failed && [.created, .failed].contains(state)
        guard explicitRetry || ![.completed, .cancelled, .failed, .interrupted].contains(handoff.state) else { return }
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
        let attention: RelayAttention? = switch error as? ParleyWorkbenchError {
        case .copilotTrustRequired: .permissionRequired
        case .unsafeRelayTarget: .targetNotReady
        case .paneNotFound: .targetUnavailable
        default: nil
        }
        let deliveryWasNotStarted = ParleyWorkbenchError.refusedBeforeInput(error)
        let retryDisposition: RelayRetryDisposition = switch kind {
        case .relay, .paste:
            deliveryWasNotStarted ? .safe : .uncertain
        case .ask, .delegate, .commandRun:
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
        let removed = removalIDs.compactMap { handoffRecords[$0] }
        handoffRecords = handoffRecords.filter { !removalIDs.contains($0.key) }
        idempotencyRecords = idempotencyRecords.filter { !removalIDs.contains($0.value.handoffID) }
        delegationResponses = delegationResponses.filter { !removalIDs.contains($0.key) }
        collectAfterRemovingHandoffsLocked(removed)
    }

    private func orderedAgentEventsLocked(
        handoffs: [RelayHandoff],
        activities: [RelayActivityEvent]
    ) -> [RelayAgentEvent] {
        var events = RelayAgentEvent.project(handoffs: handoffs, activities: activities)
        let retainedIDs = Set(events.map(\.id))
        agentEventSequenceByID = agentEventSequenceByID.filter { retainedIDs.contains($0.key) }
        for event in events where agentEventSequenceByID[event.id] == nil {
            nextAgentEventSequence &+= 1
            agentEventSequenceByID[event.id] = nextAgentEventSequence
        }
        events.sort {
            let left = agentEventSequenceByID[$0.id] ?? 0
            let right = agentEventSequenceByID[$1.id] ?? 0
            if left == right { return $0.id < $1.id }
            return left < right
        }
        for index in events.indices {
            let sequence = agentEventSequenceByID[events[index].id] ?? 0
            events[index].cursor = "v2:\(agentEventEpoch):\(sequence)"
        }
        return events
    }

    private func pruneTransientVendorEventsLocked() {
        let excess = transientVendorEventRecords.count - Self.maximumTransientVendorEvents
        guard excess > 0 else { return }
        let removalIDs = transientVendorEventRecords.values.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt < $1.occurredAt
        }.prefix(excess).map(\.id)
        for id in removalIDs { transientVendorEventRecords.removeValue(forKey: id) }
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

public enum RelayShimPlatform: Sendable { case macOS, linux }

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
        openExecutable: URL = URL(fileURLWithPath: "/usr/bin/open"),
        platform: RelayShimPlatform = .macOS
    ) throws -> URL {
        let transport = transportDirectory
            ?? RelayFileTransport.runtimeDirectory(applicationDirectory: bin.deletingLastPathComponent())
        return try writeManagedCommand(
            script(
                transportDirectory: transport,
                runtimeMarker: runtimeMarker,
                openExecutable: openExecutable,
                platform: platform
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
        openExecutable: URL,
        platform: RelayShimPlatform = .macOS
    ) -> String {
        var source = scriptTemplate
        if platform == .linux {
            source = source.replacingOccurrences(of: "/usr/bin/stat -f '%u'", with: "/usr/bin/stat -c '%u'")
                .replacingOccurrences(of: "/usr/bin/stat -f '%Lp'", with: "/usr/bin/stat -c '%a'")
                .replacingOccurrences(of: "/usr/bin/stat -f '%m'", with: "/usr/bin/stat -c '%Y'")
                .replacingOccurrences(of: "/usr/bin/uuidgen", with: "parley_uuid")
                .replacingOccurrences(of: "  if [ -n \"${PARLEY_RELAY_TOKEN:-}\" ]; then", with: "  echo 'parley open is unavailable inside a container' >&2; exit 2\n  if [ -n \"${PARLEY_RELAY_TOKEN:-}\" ]; then")
            source = source.replacingOccurrences(of: "set -eu", with: "set -eu\nparley_uuid() { if [ -r /proc/sys/kernel/random/uuid ]; then /bin/cat /proc/sys/kernel/random/uuid; else /usr/bin/uuidgen; fi; }")
        }
        return source.replacingOccurrences(
            of: "__PARLEY_TRANSPORT_ROOT__",
            // Keep the exact spelling granted by AgentProcessBoundary. On
            // macOS, standardizedFileURL rewrites /private/tmp to /tmp; those
            // aliases are equivalent to the filesystem but not to Seatbelt's
            // literal subpath rules.
            with: shellLiteral(transportDirectory.path)
        ).replacingOccurrences(
            of: "__PARLEY_TICKET_SOCKET__",
            // The socket lives beside the endpoints; a container never has it
            // mounted, so its shim carries no path and asks for no ticket.
            with: shellLiteral(platform == .macOS ? RelayTicketServer.socketURL(transportDirectory: transportDirectory).path : "")
        ).replacingOccurrences(
            of: "__PARLEY_RUNTIME_MARKER__",
            with: shellLiteral(runtimeMarker ?? "")
        ).replacingOccurrences(
            of: "__PARLEY_OPEN_EXECUTABLE__",
            with: shellLiteral(openExecutable.path)
        ).replacingOccurrences(
            of: "__PARLEY_BUNDLE_IDENTIFIER__",
            with: shellLiteral(ParleyRuntime.productionBundleIdentifier)
        ).replacingOccurrences(
            of: "__PARLEY_COMMAND_HELP__",
            with: shellLiteral(AgentProtocol.commandHelp)
        ).replacingOccurrences(
            of: "__PARLEY_PROTOCOL_TEXT__",
            with: shellLiteral(AgentProtocol.text)
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

    show_help() {
      if [ -n "$runtime_marker" ]; then
        echo "Parley relay [$runtime_marker]"
      fi
      printf '%s\\n' __PARLEY_COMMAND_HELP__
    }

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
      help|--help|-h)
        if [ "$#" -ne 1 ]; then
          echo "usage: parley help" >&2
          exit 2
        fi
        show_help
        exit 0
        ;;
      protocol)
        if [ "$#" -ne 1 ]; then
          echo "usage: parley protocol" >&2
          exit 2
        fi
        printf '%s' __PARLEY_PROTOCOL_TEXT__
        exit 0
        ;;
      request-run)
        shift
        if [ "$#" -lt 4 ] || [ "${1:-}" != "--cwd" ] || [ "${3:-}" != "--" ]; then
          echo "usage: parley request-run --cwd <absolute-folder> -- <absolute-executable> [args...]" >&2
          exit 2
        fi
        target="$2"
        shift 3
        case "$target" in /*) ;; *) echo "--cwd must be absolute" >&2; exit 2 ;; esac
        case "$1" in /*) ;; *) echo "the executable must be absolute" >&2; exit 2 ;; esac
        ;;
      team)
        subcommand="${2:-}"
        case "$subcommand" in
          request)
            shift 2
            if [ "$#" -lt 3 ]; then
              echo "usage: parley team request --folder <absolute-folder> [--panes <n>] [--hours <n>] \\"<objective>\\"" >&2
              exit 2
            fi
            command="team-request"
            ;;
          add)
            shift 2
            if [ "$#" -lt 2 ]; then
              echo "usage: parley team add --vendor <claude|codex|agy|copilot> [--name <name>] [--role <role>]" >&2
              exit 2
            fi
            command="team-add"
            ;;
          status)
            if [ "$#" -ne 2 ]; then
              echo "usage: parley team status" >&2
              exit 2
            fi
            shift 2
            command="team-status"
            ;;
          *)
            echo "usage:" >&2
            echo "  parley team request --folder <absolute-folder> [--panes <n>] [--hours <n>] \\"<objective>\\"" >&2
            echo "  parley team add --vendor <claude|codex|agy|copilot> [--name <name>] [--role <role>]" >&2
            echo "  parley team status" >&2
            exit 2
            ;;
        esac
        ;;
      image)
        item="${2:-}"
        image_usage="usage: parley image <sha256> --to <file>"
        case "$item" in
          ""|*[!a-f0-9]*)
            echo "$image_usage" >&2
            exit 2
            ;;
        esac
        if [ "${#item}" -ne 64 ] || [ "$#" -ne 4 ] || [ "${3:-}" != "--to" ] || [ -z "${4:-}" ]; then
          echo "$image_usage" >&2
          exit 2
        fi
        image_to="$4"
        shift 4
        ;;
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
        if [ "$command" = "delegate" ] && [ "${1:-}" = "--parent" ]; then
          item="${2:-}"
          case "$item" in
            ""|*[!a-f0-9-]*)
              echo "usage: parley delegate <pane> --parent <id> [task...]" >&2
              exit 2
              ;;
          esac
          shift 2
        fi
        ;;
      done)
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
        if [ "${1:-}" = "--file" ]; then
          [ "$#" -eq 2 ] || {
            echo "usage: parley done <id|current> --file <path>" >&2
            exit 2
          }
          target="$2"
          [ -n "$target" ] || {
            echo "usage: parley done <id|current> --file <path>" >&2
            exit 2
          }
          command="done-file"
          shift 2
        fi
        ;;
      answer|progress|fail|wait|cancel)
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
      signal)
        item="${2:-}"
        case "$item" in
          session-started|turn-started|turn-ended|awaiting-permission|notification|session-ended) ;;
          *)
            echo "invalid Parley vendor lifecycle signal" >&2
            exit 2
            ;;
        esac
        shift 2
        if [ "$#" -ne 0 ]; then
          echo "parley signal accepts exactly one lifecycle event" >&2
          exit 2
        fi
        ;;
      whoami|panes)
        shift
        if [ "$#" -ne 0 ]; then
          echo "usage: parley $command" >&2
          exit 2
        fi
        ;;
      events)
        shift
        if [ "$#" -ne 2 ] || [ "${1:-}" != "--since" ]; then
          echo "usage: parley events --since <beginning|now|cursor>" >&2
          exit 2
        fi
        item="$2"
        case "$item" in
          *[!a-zA-Z0-9_:.-]*|"")
            echo "events needs a valid cursor" >&2
            exit 2
            ;;
        esac
        if [ "${#item}" -gt 128 ]; then
          echo "events cursor is too long" >&2
          exit 2
        fi
        shift 2
        ;;
      status)
        shift
        ;;
      *)
        show_help >&2
        exit 2
        ;;
    esac

    case "$command" in
      whoami|panes|events|signal|status|wait|cancel|context-list|context-show|context-discard|context-draft|context-add|done-file|image) ;;
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

    # The heartbeat's modification time, or 0 when there is none. The
    # transport rewrites it at least a second apart, so a live transport's
    # value changes between readings a second apart; a dead one's never does,
    # whatever date it carries. That holds when this clock and the Mac's
    # disagree (a container's VM) or one of them stepped back, where comparing
    # with `date` read a dead broker's future-dated heartbeat as fresh forever.
    heartbeat_time() {
      if [ -f "$endpoint/heartbeat" ] && [ ! -L "$endpoint/heartbeat" ]; then
        /usr/bin/stat -f '%m' "$endpoint/heartbeat" 2>/dev/null || printf '0'
      else
        printf '0'
      fi
    }

    # The transport instance that wrote the heartbeat, its content; empty
    # when there is none. A restart discards the request this shim waits on,
    # and nothing else says so: a request leaves the filesystem while it is
    # processed. A different instance while waiting is therefore final.
    heartbeat_instance() {
      if [ -f "$endpoint/heartbeat" ] && [ ! -L "$endpoint/heartbeat" ]; then
        /bin/cat "$endpoint/heartbeat" 2>/dev/null || true
      fi
    }

    # One stale reading is not a stopped broker. The Mac's wall clock moves on
    # through sleep before the transport's timer runs again, and App Nap can
    # hold that timer back, so stale readings are counted and wake the
    # transport (about once a second): an entry made and removed in the inbox
    # makes its watcher run a tick at once. The transport skips hidden
    # entries. mkdir and rmdir are in the container utility contract; `:` with
    # a redirection is a special builtin, whose failure would end the shell.
    wake_transport() {
      /bin/mkdir "$inbox/.wake-$$" 2>/dev/null || true
      /bin/rmdir "$inbox/.wake-$$" 2>/dev/null || true
    }

    # Before anything is written: a heartbeat that names its transport
    # instance and is fresh, or is seen to change, within about five seconds
    # of this command's own time. The instance becomes the baseline a restart
    # is noticed by, so a heartbeat without one is not yet a running broker.
    # A refusal therefore still means nothing was sent. An endpoint that
    # vanishes meanwhile (its pane restarted or closed) is final at once.
    broker_is_running() {
      stale_readings=0
      first_beat=""
      while :; do
        [ -d "$endpoint" ] && [ ! -L "$endpoint" ] || return 1
        sent_instance="$(heartbeat_instance)"
        if [ -n "$sent_instance" ]; then
          if heartbeat_is_fresh; then
            return 0
          fi
          beat="$(heartbeat_time)"
          if [ -z "$first_beat" ]; then
            first_beat="$beat"
          elif [ "$beat" != 0 ] && [ "$beat" != "$first_beat" ]; then
            return 0
          fi
        fi
        stale_readings=$((stale_readings + 1))
        [ "$stale_readings" -le 20 ] || return 1
        if [ $((stale_readings % 4)) -eq 1 ]; then
          wake_transport
        fi
        /bin/sleep 0.25
      done
    }

    cleanup_directory() {
      directory="$1"
      [ -n "$directory" ] || return 0
      case "$directory" in
        "$inbox"/*|"$outbox"/*) ;;
        *) return 0 ;;
      esac
      for field in command target item idempotency-key token ticket body handoff-id accepted status ready; do
        /bin/rm -f "$directory/$field" 2>/dev/null || true
      done
      /bin/rmdir "$directory" 2>/dev/null || true
    }

    # `post` always runs as a pipeline element, a subshell where no EXIT trap
    # fires (in macOS sh or dash), so it calls `cleanup` itself on every path
    # it controls. What a shim killed part-way leaves behind, the transport
    # removes: a request with no `ready` after 30 seconds of awake time, a
    # reply after ten minutes, and the whole endpoint when its pane restarts.
    request_dir=""
    response_dir=""
    staged_body=""
    cleanup() {
      cleanup_directory "$request_dir"
      cleanup_directory "$response_dir"
      case "$staged_body" in
        "$inbox"/.body-*) /bin/rm -f "$staged_body" 2>/dev/null || true ;;
      esac
    }

    # A one-use ticket from the peer-verified ticket socket, when this pane can
    # reach it. The broker knows which panes must present one; a pane whose
    # sandbox denies the socket sends none and is authenticated by capability.
    # Everything but `ready`, each write checked: without `ready` nothing was
    # sent, so any failure here is a clean refusal.
    write_request() {
      /bin/mkdir "$request_dir" || return 1
      /usr/bin/printf '%s' "$command" > "$request_dir/command" || return 1
      /usr/bin/printf '%s' "$target" > "$request_dir/target" || return 1
      /usr/bin/printf '%s' "$item" > "$request_dir/item" || return 1
      /usr/bin/printf '%s' "$idempotency_key" > "$request_dir/idempotency-key" || return 1
      /usr/bin/printf '%s' "$pane_token" > "$request_dir/token" || return 1
      /bin/cat "$staged_body" > "$request_dir/body" || return 1
      request_ticket
      if [ -n "$ticket" ]; then
        /usr/bin/printf '%s' "$ticket" > "$request_dir/ticket" || return 1
      fi
    }

    ticket_socket=__PARLEY_TICKET_SOCKET__
    ticket=""
    # unasked, issued, refused, or silent when the socket gave no answer in
    # time (an app the Mac had not yet scheduled after a wake): only silence
    # is worth asking again.
    ticket_outcome=unasked
    request_ticket() {
      ticket=""
      ticket_outcome=unasked
      [ -n "$ticket_socket" ] && [ -S "$ticket_socket" ] && [ -x /usr/bin/nc ] || return 0
      ticket="$(/usr/bin/printf '%s %s\n' "$pane_token" "$request_id" | /usr/bin/nc -U -w 3 "$ticket_socket" 2>/dev/null | /usr/bin/tr -d '\r\n')" || ticket=""
      case "$ticket" in
        refused:*) ticket=""; ticket_outcome=refused ;;
        "") ticket_outcome=silent ;;
        *) ticket_outcome=issued ;;
      esac
    }

    # Writes the request under a new id, then `ready`. The staged body stays
    # until the reply's status is known, so a request refused for want of a
    # ticket can be written again.
    send_request() {
      request_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
      request_dir="$inbox/$request_id"
      response_dir="$outbox/$request_id"
      if ! write_request 2>/dev/null; then
        cleanup
        if [ -d "$endpoint" ] && [ ! -L "$endpoint" ]; then
          echo "Parley could not write the request, so nothing was sent" >&2
        else
          echo "the Parley relay broker is not running" >&2
        fi
        return 2
      fi
      if ! /usr/bin/printf '%s' ready > "$request_dir/ready"; then
        cleanup
        echo "Parley could not finish writing the request; it may or may not have been sent" >&2
        return 2
      fi
    }

    post() {
      # Ctrl-C or a tool timeout's SIGTERM ends this subshell with no return
      # path, so it cleans up first; a staged body would otherwise wait for
      # the transport's ten-minute scratch sweep.
      trap 'cleanup; exit 130' INT
      trap 'cleanup; exit 143' TERM
      trap 'cleanup; exit 129' HUP
      if ! protected_directory "$endpoint" || ! protected_directory "$inbox" || ! protected_directory "$outbox" || ! broker_is_running; then
        echo "the Parley relay broker is not running" >&2
        return 2
      fi

      # The body is read before the request exists: a producer slower than
      # the transport's abandonment age used to lose a request folder it was
      # still filling. It waits hidden in the inbox, which the transport
      # skips, and is copied in once the request is written; the folder then
      # exists only for these local writes. `mv` is not in the container
      # utility contract, so this copies rather than renames.
      request_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
      staged_body="$inbox/.body-$request_id"
      if ! /bin/cat > "$staged_body"; then
        cleanup
        echo "Parley could not stage the request, so nothing was sent" >&2
        return 2
      fi

      # Reading stdin can take as long as its producer. The transport found
      # before it must still be the one there; if it stopped or restarted
      # meanwhile, a running one is looked for again. One that died without
      # a restart is noticed while waiting. The directories are checked again
      # just before use.
      if { [ "$(heartbeat_instance)" != "$sent_instance" ] && ! broker_is_running; } \
        || ! protected_directory "$endpoint" || ! protected_directory "$inbox" || ! protected_directory "$outbox"; then
        cleanup
        echo "the Parley relay broker is not running" >&2
        return 2
      fi

      send_request || return 2

      ticket_retries=0
      ask_id_reported=0
      checks=0
      stale_readings=0
      last_beat="$(heartbeat_time)"
      while :; do
        # Once the transport has read the request (it is in neither the inbox
        # nor processing, and has no reply yet), no ticket refusal can follow,
        # so the staged body goes: request text does not sit on disk through
        # a long Ask or wait. A refusal is written before the request leaves
        # processing, so it is never mistaken for this.
        if [ -n "$staged_body" ] && [ ! -e "$request_dir" ] && [ ! -e "$endpoint/processing/$request_id" ] \
          && [ ! -e "$response_dir/ready" ]; then
          /bin/rm -f "$staged_body"
          staged_body=""
        fi
        if [ "$ask_id_reported" -eq 0 ] \
          && { [ "$command" = "ask" ] || [ "$command" = "context-ask" ] || [ "$command" = "request-run" ] || [ "$command" = "team-request" ] || [ "$command" = "team-add" ]; } \
          && protected_directory "$response_dir" \
          && [ -f "$response_dir/accepted" ] && [ ! -L "$response_dir/accepted" ] \
          && [ -f "$response_dir/handoff-id" ] && [ ! -L "$response_dir/handoff-id" ]; then
          handoff_id="$(/bin/cat "$response_dir/handoff-id")"
          case "$handoff_id" in
            *[!a-f0-9-]*|"") ;;
            *)
              if [ "${#handoff_id}" -eq 36 ]; then
                if [ "$command" = "request-run" ]; then
                  echo "Parley Run ID: $handoff_id" >&2
                elif [ "$command" = "team-request" ]; then
                  echo "Parley Team Session ID: $handoff_id" >&2
                elif [ "$command" = "team-add" ]; then
                  echo "Parley Pane Request ID: $handoff_id" >&2
                else
                  echo "Parley Ask ID: $handoff_id" >&2
                fi
                ask_id_reported=1
              fi
              ;;
          esac
        fi
        if [ -f "$response_dir/ready" ] && [ ! -L "$response_dir" ] && [ ! -L "$response_dir/ready" ] \
          && [ -f "$response_dir/status" ] && [ ! -L "$response_dir/status" ] \
          && [ -f "$response_dir/body" ] && [ ! -L "$response_dir/body" ]; then
          status="$(/bin/cat "$response_dir/status")"
          if [ "$status" = "428" ] && [ "$ticket_outcome" = "silent" ] && [ "$ticket_retries" -lt 10 ]; then
            # Refused before anything was read: this pane must present a
            # ticket and the socket did not answer in time, as while the Mac
            # sleeps and dark-wakes. Nothing was sent, so the same request
            # goes again with a fresh ticket.
            ticket_retries=$((ticket_retries + 1))
            cleanup_directory "$request_dir"
            cleanup_directory "$response_dir"
            /bin/sleep 1
            send_request || return 2
            checks=0
            continue
          fi
          if [ "$status" = "102" ]; then
            # The broker's long-poll window passed with the work still open:
            # nothing to print; the caller asks again.
            cleanup
            return 75
          fi
          # A reply not written out in full is a failure, whatever the
          # broker answered: `post` runs where `set -e` does not reach, and a
          # cut-short image used to be saved as if whole.
          if ! /bin/cat "$response_dir/body"; then
            cleanup
            echo "Parley answered, but its reply could not be written out in full" >&2
            return 74
          fi
          cleanup
          case "$status" in
            2??) return 0 ;;
            *) return 22 ;;
          esac
        fi
        checks=$((checks + 1))
        # Every 50 ms for the first second, where nearly every reply lands,
        # then every 250 ms: a long wait must not start twenty processes a
        # second. The broker's heartbeat is read about once a second; a
        # vanished endpoint is final, a heartbeat that has not changed only
        # after five readings in a row (see heartbeat_time, wake_transport).
        if [ "$checks" -le 20 ]; then
          heartbeat_every=20
          pause=0.05
        else
          heartbeat_every=4
          pause=0.25
        fi
        if [ $((checks % heartbeat_every)) -eq 0 ]; then
          if [ ! -d "$endpoint" ] || [ -L "$endpoint" ]; then
            cleanup
            echo "the Parley relay broker stopped before replying" >&2
            return 2
          fi
          beat="$(heartbeat_time)"
          instance="$(heartbeat_instance)"
          if [ -n "$instance" ] && [ "$instance" != "$sent_instance" ]; then
            if [ -f "$request_dir/ready" ] && [ ! -L "$request_dir" ]; then
              # Still in the inbox, so written after the new transport's
              # start discarded the old requests: it will be processed.
              sent_instance="$instance"
            else
              cleanup
              echo "the Parley relay broker restarted before replying; the request may or may not have been delivered" >&2
              return 2
            fi
          fi
          if [ "$beat" != 0 ] && [ "$beat" != "$last_beat" ]; then
            stale_readings=0
          else
            stale_readings=$((stale_readings + 1))
            if [ "$stale_readings" -ge 5 ]; then
              # `post` runs in a pipeline subshell, where the script's EXIT
              # trap never fires, so clean up here: a broker that comes back
              # must not act on a request the agent was told had failed.
              cleanup
              echo "the Parley relay broker stopped before replying" >&2
              return 2
            fi
            wake_transport
          fi
          last_beat="$beat"
        fi
        /bin/sleep "$pause"
      done
    }

    case "$command" in
      request-run|team-request|team-add)
        printf '%s\\0' "$@" | post
        ;;
      team-status)
        printf '' | post
        ;;
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
      progress|done|fail)
        if [ "$#" -gt 0 ]; then
          printf '%s' "$*"
        else
          /bin/cat
        fi | post
        ;;
      whoami|panes|events|signal|status)
        printf '' | post
        ;;
      wait)
        # A bounded long-poll: each post returns within the broker's window,
        # and 75 means the work is still open, so ask again. A wait whose
        # shell is killed therefore leaves no request blocked for long.
        while :; do
          wait_status=0
          printf '' | post || wait_status=$?
          [ "$wait_status" -eq 75 ] || exit "$wait_status"
        done
        ;;
      cancel)
        printf '' | post
        ;;
      context-list|context-show|context-discard)
        printf '' | post
        ;;
      context-draft|context-add|done-file)
        case "$target" in
          /*) ;;
          *) target="$PWD/$target" ;;
        esac
        if [ ! -f "$target" ]; then
          echo "Parley can stage only a readable file: $target" >&2
          exit 2
        fi
        /bin/cat -- "$target" | post
        ;;
      image)
        # The reply is the image's bytes, written where this agent asked,
        # with this agent's own permissions. It lands in a scratch folder
        # beside that file first and replaces it only once Parley has served
        # the whole image, so a refusal leaves a file already there as it
        # was; the refusal's text goes to stderr. A container has cat but no
        # mv, so the copy is a cat.
        if [ -d "$image_to" ]; then
          echo "--to names a folder; name the file to write: $image_to" >&2
          exit 2
        fi
        # The scratch folder is made with mkdir, which fails on anything
        # already there, a link included, so nothing but this run's own
        # folder is ever written or removed.
        image_scratch="$image_to.parley-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
        if ! /bin/mkdir -m 700 -- "$image_scratch"; then
          echo "could not make a scratch folder beside $image_to, so nothing was fetched" >&2
          exit 1
        fi
        image_partial="$image_scratch/image"
        image_cleanup() { /bin/rm -f -- "$image_partial"; /bin/rmdir -- "$image_scratch" 2>/dev/null || true; }
        trap 'image_cleanup; exit 130' INT
        trap 'image_cleanup; exit 143' TERM
        trap 'image_cleanup; exit 129' HUP
        image_status=0
        printf '' | post > "$image_partial" || image_status=$?
        if [ "$image_status" -ne 0 ]; then
          # Only a refusal (22) carries the broker's text; anything else
          # may hold part of the image.
          if [ "$image_status" -eq 22 ] && [ -f "$image_partial" ]; then
            /bin/cat -- "$image_partial" >&2
            echo >&2
          fi
          image_cleanup
          exit "$image_status"
        fi
        if ! /bin/cat -- "$image_partial" > "$image_to"; then
          image_cleanup
          echo "could not write $image_to" >&2
          exit 1
        fi
        image_cleanup
        echo "Saved the image to $image_to" >&2
        ;;
    esac
    """
}

/// One value shared between a broker call and a callback it hands to the Ask
/// engine, which runs that callback on the same thread but outside the
/// broker lock.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) { lock.withLock { stored = value } }
}
