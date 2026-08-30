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
    case invalidControlToken
    case randomGenerationFailed
    case socket(String)
    case invalidLocator
    case malformedResponse
    case response(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidControlToken:
            "Parley's core control credential is invalid."
        case .randomGenerationFailed:
            "Parley could not create its core control credential."
        case let .socket(detail):
            "Parley core: \(detail)"
        case .invalidLocator:
            "Parley's core endpoint is missing or invalid."
        case .malformedResponse:
            "Parley's core returned a malformed response."
        case let .response(status, detail):
            "Parley's core returned \(status): \(detail)"
        }
    }
}

/// A capability used only by the native UI to inspect and complete broker
/// state. Agent panes receive their own pane credential, never this token.
public enum RelayCoreControlToken {
    public static func load(at file: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RelayCoreError.invalidControlToken
        }
        let token = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else {
            throw RelayCoreError.invalidControlToken
        }
        return token
    }

    public static func loadOrCreate(at file: URL, fileManager: FileManager = .default) throws -> String {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let lockPath = file.path + ".lock"
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_EXLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RelayCoreError.socket("could not lock the control credential: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)

        if fileManager.fileExists(atPath: file.path) {
            return try load(at: file)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RelayCoreError.randomGenerationFailed
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}

/// A short-lived native UI client. Coordination state remains in the core, so
/// discarding this value and creating another never discards a consultation.
public struct RelayCoreClient: Sendable {
    public let infoFile: URL
    private let controlToken: String

    public init(infoFile: URL, controlToken: String) {
        self.infoFile = infoFile
        self.controlToken = controlToken
    }

    public func isHealthy() -> Bool {
        guard let response = try? request(method: "GET", path: "/health", body: Data()) else { return false }
        return response.status == 200 && response.body == Data("ok".utf8)
    }

    /// Used only to retire the pre-app-resident core during the first upgrade.
    public func shutdownLegacyCoreIfIdle() throws -> LegacyCoreShutdownResponse {
        try legacyCoreShutdownRequest(path: "/ui/shutdown-if-idle")
    }

    private func legacyCoreShutdownRequest(path: String) throws -> LegacyCoreShutdownResponse {
        let response = try request(
            method: "POST",
            path: path,
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 202 || response.status == 409 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return LegacyCoreShutdownResponse(
            status: response.status,
            readiness: try JSONDecoder().decode(LegacyCoreShutdownReadiness.self, from: response.body)
        )
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

    public func rejectContextReview(_ reviewID: String) throws -> RelayTextResponse {
        let response = try request(
            method: "POST",
            path: "/ui/context-reviews/reject/\(reviewID)",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
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

    public func completeContextDraft(
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

    public func askFromUI(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false
    ) throws -> RelayTextResponse {
        let body = try JSONEncoder().encode(RelayUIAskRequest(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            text: text,
            idempotencyKey: idempotencyKey,
            preserveFormatting: preserveFormatting
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

    public func askManyFromUI(
        sourcePaneID: String,
        targetPaneIDs: [String],
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false
    ) throws -> RelayAskManyUIResponse {
        let body = try JSONEncoder().encode(RelayUIAskManyRequest(
            sourcePaneID: sourcePaneID,
            targetPaneIDs: targetPaneIDs,
            text: text,
            idempotencyKey: idempotencyKey,
            preserveFormatting: preserveFormatting
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
        let locator = try String(contentsOf: infoFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard locator.hasPrefix("unix:") else { throw RelayCoreError.invalidLocator }
        let socketPath = String(locator.dropFirst("unix:".count))

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
                let count = Darwin.send(descriptor, base.advanced(by: sent), raw.count - sent, 0)
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

public struct LegacyCoreShutdownResponse: Equatable, Sendable {
    public let status: Int
    public let readiness: LegacyCoreShutdownReadiness

    public init(status: Int, readiness: LegacyCoreShutdownReadiness) {
        self.status = status
        self.readiness = readiness
    }
}

private struct CoreHTTPResponse {
    let status: Int
    let body: Data
}
