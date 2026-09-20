import Darwin
import Dispatch
import Foundation
import Security

public enum RelayCoreTransportLimits {
    public static let maximumBodyBytes = 200_000
    public static let trackedResponseTimeout: TimeInterval = 31 * 60
}

struct RelayWorkspaceHistoryDeletionRequest: Codable {
    let workspaceID: String
    let workspaceName: String?
}

struct RelayHistoryRetentionUpdateRequest: Codable {
    let maximumRecords: Int
}

public enum RelayCoreError: LocalizedError {
    case randomGenerationFailed
    case socket(String)
    case malformedResponse
    case response(Int, String)
    case mainThreadBlockingRequest(String)

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "Parley could not create its core control credential."
        case let .socket(detail):
            "Parley core: \(detail)"
        case .malformedResponse:
            "Parley's core returned a malformed response."
        case let .response(status, detail):
            "Parley's core returned \(status): \(detail)"
        case let .mainThreadBlockingRequest(path):
            "Parley refused to wait on its core from the main thread (\(path)). That request can take minutes and the core delivers through the main thread, so waiting here would freeze the app. Nothing was sent."
        }
    }
}

/// A capability used only by the native UI to inspect and complete broker
/// state. Agent panes receive their own pane credential, never this token.
public enum RelayCoreControlToken {
    /// Fresh authority for one app-resident core. Never read or write a token file.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RelayCoreError.randomGenerationFailed
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        return token
    }
}

/// A short-lived native UI client. Coordination state remains in the core, so
/// discarding this value and creating another never discards a consultation.
public struct RelayCoreClient: Sendable {
    private let socketFile: URL
    private let controlToken: String
    private let expectedServerPID: Int32

    /// The socket path is supplied by trusted native construction. `infoFile`
    /// names its directory only; its editable contents are never consulted.
    /// The app's core delivers into panes through `DispatchQueue.main.sync`, so
    /// a tracked request made from the main thread can never complete. A check
    /// fixture whose core delivers through plain closures may opt out; the app
    /// never does.
    private let allowsTrackedRequestsOnMainThread: Bool

    public init(
        infoFile: URL,
        controlToken: String,
        socketFile: URL? = nil,
        expectedServerPID: Int32 = getpid(),
        allowsTrackedRequestsOnMainThread: Bool = false
    ) {
        self.socketFile = socketFile ?? infoFile.deletingLastPathComponent().appendingPathComponent("relay.sock")
        self.controlToken = controlToken
        self.expectedServerPID = expectedServerPID
        self.allowsTrackedRequestsOnMainThread = allowsTrackedRequestsOnMainThread
    }

    public func isHealthy() -> Bool {
        guard let response = try? request(method: "GET", path: "/health", body: Data()) else { return false }
        return response.status == 200 && response.body == Data("ok".utf8)
    }

    public func consultations() throws -> [RelayConsultation] {
        let response = try request(
            method: "GET",
            path: "/consultations",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode([RelayConsultation].self, from: response.body)
    }

    public func contextReviews() throws -> [AgentContextReview] {
        let response = try request(
            method: "GET",
            path: "/context-reviews",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode([AgentContextReview].self, from: response.body)
    }

    public func discardContextDraft(reviewID: String, expectedUpdatedAt: Date) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(AgentContextDraftDiscard(reviewID: reviewID, expectedUpdatedAt: expectedUpdatedAt))
        let response = try request(
            method: "POST",
            path: "/ui/context-reviews/discard",
            headers: ["X-Parley-Control": controlToken, "Content-Type": "application/json"],
            body: body
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func deleteContextReviews(_ deletion: AgentContextDeletion) throws -> RelayTextResponse {
        let response = try request(method: "POST", path: "/ui/context-reviews/delete",
            headers: ["X-Parley-Control": controlToken, "Content-Type": "application/json"],
            body: JSONEncoder().encode(deletion))
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func approveContextReview(
        reviewID: String,
        expectedUpdatedAt: Date,
        pack: ContextPack,
        targetPaneID: String
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(AgentContextReviewApproval(
            reviewID: reviewID,
            expectedUpdatedAt: expectedUpdatedAt,
            targetPaneID: targetPaneID,
            pack: pack
        ))
        if let oversized = oversizedContextResponse(body) { return oversized }
        let response = try request(
            method: "POST",
            path: "/ui/context-reviews/approve",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func rejectContextReview(_ reviewID: String, expectedUpdatedAt: Date) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/context-reviews/reject/\(reviewID)",
            headers: ["X-Parley-Control": controlToken, "Content-Type": "application/json"],
            body: try JSONEncoder().encode(AgentContextDraftDiscard(reviewID: reviewID, expectedUpdatedAt: expectedUpdatedAt))
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func captureTrustedContext(
        _ capture: AgentContextTrustedCaptureRequest
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(capture)
        if let oversized = oversizedContextResponse(body) { return oversized }
        let response = try request(
            method: "POST",
            path: "/ui/context-reviews/capture",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body
        )
        return RelayTextResponse(
            status: response.status,
            text: String(decoding: response.body, as: UTF8.self)
        )
    }

    /// Sends a person-reviewed agent draft as one correlated Ask. Returns when
    /// the answer arrives or the consultation times out, so it must run off
    /// the main thread like `askFromUI`; the key lets the UI reveal the exact
    /// handoff afterwards.
    public func completeContextDraft(
        reviewID: String,
        expectedUpdatedAt: Date,
        pack: ContextPack,
        targetPaneID: String,
        idempotencyKey: String? = nil
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(AgentContextReviewApproval(
            reviewID: reviewID,
            expectedUpdatedAt: expectedUpdatedAt,
            targetPaneID: targetPaneID,
            pack: pack,
            idempotencyKey: idempotencyKey
        ))
        if let oversized = oversizedContextResponse(body) { return oversized }
        let response = try request(
            method: "POST",
            path: "/ui/context-reviews/complete",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    private func oversizedContextResponse(_ body: Data) -> RelayTextResponse? {
        guard body.count > RelayCoreTransportLimits.maximumBodyBytes else { return nil }
        return RelayTextResponse(
            status: 413,
            text: "The reviewed context payload is \(body.count) bytes. Reduce it below \(RelayCoreTransportLimits.maximumBodyBytes) bytes before sending."
        )
    }

    public func handoffs(limit: Int? = nil) throws -> [RelayHandoff] {
        let path = limit.map { "/handoffs?limit=\(min(500, max(1, $0)))" } ?? "/handoffs"
        let response = try request(
            method: "GET",
            path: path,
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode([RelayHandoff].self, from: response.body)
    }

    public func activityEvents(limit: Int? = nil) throws -> [RelayActivityEvent] {
        let path = limit.map { "/activity-events?limit=\(min(500, max(1, $0)))" } ?? "/activity-events"
        let response = try request(
            method: "GET",
            path: path,
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode([RelayActivityEvent].self, from: response.body)
    }

    @discardableResult
    public func recordActivity(_ requestBody: RelayActivityEventRequest) throws -> RelayActivityEvent {
        let body = try JSONEncoder().encode(requestBody)
        let response = try request(
            method: "POST",
            path: "/ui/activity",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode(RelayActivityEvent.self, from: response.body)
    }

    public func unreadHandoffs() throws -> [RelayHandoff] {
        let response = try request(
            method: "GET",
            path: "/handoffs/unread",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode([RelayHandoff].self, from: response.body)
    }

    public func answerFromUI(consultationID: String, text: String) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/answer/\(consultationID)",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "text/plain; charset=utf-8",
            ],
            body: Data(text.utf8)
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func voiceHandoffFromUI(_ handoff: VoiceHandoffRequest) throws -> RelayTextResponse {
        let response = try request(method: "POST", path: "/ui/voice-handoff",
            headers: ["X-Parley-Control": controlToken, "Content-Type": "application/json"],
            body: try JSONEncoder().encode(handoff), receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout)
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func askFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false,
        origin: RelayTransitionOrigin = .human
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(RelayUIAskRequest(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            preserveFormatting: preserveFormatting,
            origin: origin
        ))
        let response = try request(
            method: "POST",
            path: "/ui/ask",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func reviewAskFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        inReplyToHandoffID: String,
        relationship: RelayHandoffRelationship
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(RelayUIReviewAskRequest(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            inReplyToHandoffID: inReplyToHandoffID,
            relationship: relationship
        ))
        let response = try request(
            method: "POST",
            path: "/ui/review-ask",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        return RelayTextResponse(
            status: response.status,
            text: String(decoding: response.body, as: UTF8.self)
        )
    }

    /// One linked Delegate child for a returned Delegate result. The status is
    /// the broker's; the text is its error, or its receipt note on success.
    public func requestChangesFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        inReplyToHandoffID: String
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(RelayUIRequestChangesRequest(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            inReplyToHandoffID: inReplyToHandoffID
        ))
        let response = try request(
            method: "POST",
            path: "/ui/request-changes",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        let raw = String(decoding: response.body, as: UTF8.self)
        guard let receipt = try? JSONDecoder().decode(RelayResponseBody.self, from: response.body) else {
            return RelayTextResponse(status: response.status, text: raw)
        }
        return RelayTextResponse(status: response.status, text: receipt.error ?? receipt.note ?? raw)
    }

    public func updateHandoffReview(
        _ update: RelayHandoffReviewUpdate
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(update)
        let response = try request(
            method: "POST",
            path: "/ui/handoff-review",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body
        )
        return RelayTextResponse(
            status: response.status,
            text: String(decoding: response.body, as: UTF8.self)
        )
    }

    public func askManyFromUI(
        sourcePaneID: String,
        targetPaneIDs: [String],
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false,
        origin: RelayTransitionOrigin = .human
    ) throws -> RelayAskManyUIResponse {
        let body = try JSONEncoder().encode(RelayUIAskManyRequest(
            sourcePaneID: sourcePaneID,
            targetPaneIDs: targetPaneIDs,
            text: text,
            idempotencyKey: idempotencyKey,
            preserveFormatting: preserveFormatting,
            origin: origin
        ))
        let response = try request(
            method: "POST",
            path: "/ui/ask-many",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        guard let bundle = try? JSONDecoder().decode(RelayAskManyBundle.self, from: response.body) else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return RelayAskManyUIResponse(status: response.status, bundle: bundle)
    }

    public func reviewedBusyDrafts() throws -> [ReviewedBusyDraft] {
        let response = try request(
            method: "GET",
            path: "/ui/reviewed-busy-drafts",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode([ReviewedBusyDraft].self, from: response.body)
    }

    public func enqueueReviewedBusyDraft(
        _ requestBody: ReviewedBusyDraftCreateRequest
    ) throws -> ReviewedBusyDraft {
        let body = try JSONEncoder().encode(requestBody)
        let response = try request(
            method: "POST",
            path: "/ui/reviewed-busy-drafts",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body
        )
        guard response.status == 201 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode(ReviewedBusyDraft.self, from: response.body)
    }

    public func sendReviewedBusyDraft(
        _ requestBody: ReviewedBusyDraftSendRequest
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(requestBody)
        let response = try request(
            method: "POST",
            path: "/ui/reviewed-busy-drafts/send",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body,
            receiveTimeout: RelayCoreTransportLimits.trackedResponseTimeout
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func cancelReviewedBusyDraft(_ draftID: String) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/reviewed-busy-drafts/cancel/\(draftID)",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func cancelHandoff(_ handoffID: String) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/cancel/\(handoffID)",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func retryHandoff(_ handoffID: String) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/retry/\(handoffID)",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func markHandoffRead(_ handoffID: String) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/read/\(handoffID)",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func deleteAllHistory() throws -> RelayTextResponse {
        let response = try request(
            method: "POST", path: "/ui/history/delete-all",
            headers: ["X-Parley-Control": controlToken], body: Data()
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func deleteWorkspaceHistory(
        workspaceID: String,
        workspaceName: String?
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(RelayWorkspaceHistoryDeletionRequest(
            workspaceID: workspaceID,
            workspaceName: workspaceName
        ))
        let response = try request(
            method: "POST",
            path: "/ui/history/delete-workspace",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body
        )
        return RelayTextResponse(status: response.status, text: String(decoding: response.body, as: UTF8.self))
    }

    public func historyRetentionPolicy() throws -> CollaborationHistoryRetentionPolicy {
        let response = try request(
            method: "GET",
            path: "/ui/history/retention",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode(CollaborationHistoryRetentionPolicy.self, from: response.body)
    }

    public func updateHistoryRetention(
        maximumRecords: Int
    ) throws -> CollaborationHistoryRetentionChange {
        let body = try JSONEncoder().encode(RelayHistoryRetentionUpdateRequest(
            maximumRecords: maximumRecords
        ))
        let response = try request(
            method: "POST",
            path: "/ui/history/retention",
            headers: [
                "X-Parley-Control": controlToken,
                "Content-Type": "application/json",
            ],
            body: body
        )
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode(CollaborationHistoryRetentionChange.self, from: response.body)
    }

    private func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data,
        receiveTimeout: TimeInterval = 3
    ) throws -> CoreHTTPResponse {
        // A tracked request returns only after the core has delivered into a
        // pane or an answer has arrived, and the core delivers through
        // DispatchQueue.main.sync. A main thread parked in recv below can never
        // service that hop: v0.1.40 froze on a context-pack Ask until it was
        // force-quit. Refuse before touching the socket, so a call site that
        // forgets gets an alert rather than a frozen app.
        if receiveTimeout >= RelayCoreTransportLimits.trackedResponseTimeout, Thread.isMainThread,
           !allowsTrackedRequestsOnMainThread {
            throw RelayCoreError.mainThreadBlockingRequest(path)
        }
        let socketPath = socketFile.path

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("could not create client socket") }
        defer { Darwin.close(descriptor) }

        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let wholeSeconds = Int(receiveTimeout.rounded(.down))
        let fractionalMicroseconds = Int((receiveTimeout - Double(wholeSeconds)) * 1_000_000)
        var receive = timeval(tv_sec: wholeSeconds, tv_usec: Int32(fractionalMicroseconds))
        var sendTimeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout.size(ofValue: receive)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout.size(ofValue: sendTimeout)))

        var address = try unixAddress(path: socketPath)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw socketError("could not connect") }
        // Authenticate the process before sending even one credential byte.
        guard LocalSocketPeer.matches(descriptor, pid: expectedServerPID) else {
            throw socketError("the control socket is not owned by this app process")
        }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: parley\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        try send(Data(head.utf8) + body, descriptor: descriptor)
        _ = Darwin.shutdown(descriptor, SHUT_WR)

        var received = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw socketError("could not read response")
            }
            received.append(contentsOf: buffer.prefix(count))
        }
        return try parseResponse(received)
    }

    private func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw RelayCoreError.socket("socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    private func send(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), raw.count - sent, MSG_NOSIGNAL)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw socketError("could not send request") }
                sent += count
            }
        }
    }

    private func parseResponse(_ data: Data) throws -> CoreHTTPResponse {
        let marker = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: marker),
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw RelayCoreError.malformedResponse
        }
        let fields = head.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard fields.count >= 2, let status = Int(fields[1]) else {
            throw RelayCoreError.malformedResponse
        }
        return CoreHTTPResponse(status: status, body: data.subdata(in: boundary.upperBound..<data.endIndex))
    }

    private func socketError(_ prefix: String) -> RelayCoreError {
        RelayCoreError.socket("\(prefix): \(String(cString: strerror(errno)))")
    }
}

private struct CoreHTTPResponse {
    let status: Int
    let body: Data
}

/// Kernel-reported peer identity, independent of any owner-writable path or token file.
enum LocalSocketPeer {
    static func matches(_ descriptor: Int32, pid: Int32) -> Bool {
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return pid > 1 && getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0
            && size == MemoryLayout<pid_t>.size && peer == pid
    }
}
