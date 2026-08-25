import Darwin
import Dispatch
import Foundation
import Security

public enum RelayCoreTransportLimits {
    public static let maximumBodyBytes = 200_000
}

struct RelayWorkspaceHistoryDeletionRequest: Codable {
    let workspaceID: String
    let workspaceName: String?
}

public enum RelayCoreError: LocalizedError {
    case invalidControlToken
    case randomGenerationFailed
    case socket(String)
    case invalidLocator
    case malformedResponse
    case response(Int, String)
    case serviceExecutableNotFound
    case serviceFailed(String)

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
        case .serviceExecutableNotFound:
            "The Parley core service executable is missing. Run `npm run build` and try again."
        case let .serviceFailed(detail):
            "The Parley core service did not start: \(detail)"
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

    /// Returns nil only for a legacy core that predates the identity route.
    public func coreIdentity() throws -> CoreServiceIdentity? {
        let response = try request(
            method: "GET",
            path: "/identity",
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        if response.status == 404 { return nil }
        guard response.status == 200 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return try JSONDecoder().decode(CoreServiceIdentity.self, from: response.body)
    }

    public func shutdownIfIdle() throws -> RelayCoreUpgradeResponse {
        try idleShutdownRequest(path: "/ui/shutdown-if-idle")
    }

    public func stopIfIdle() throws -> RelayCoreUpgradeResponse {
        try idleShutdownRequest(path: "/ui/stop-if-idle")
    }

    private func idleShutdownRequest(path: String) throws -> RelayCoreUpgradeResponse {
        let response = try request(
            method: "POST",
            path: path,
            headers: ["X-Parley-Control": controlToken],
            body: Data()
        )
        guard response.status == 202 || response.status == 409 else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return RelayCoreUpgradeResponse(
            status: response.status,
            readiness: try JSONDecoder().decode(RelayUpgradeReadiness.self, from: response.body)
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
        if response.status == 404 { return [] }
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
            body: body
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
            body: body
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
        if response.status == 404 {
            // A newly attached UI can briefly outpace a persistent core from
            // the previous build. Preserve workflow until that core is safely
            // restarted; the bounded history remains authoritative.
            return try handoffs(limit: 500).filter(\.hasUnreadResult)
        }
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
            body: body
        )
        guard let bundle = try? JSONDecoder().decode(RelayAskManyBundle.self, from: response.body) else {
            throw RelayCoreError.response(response.status, String(decoding: response.body, as: UTF8.self))
        }
        return RelayAskManyUIResponse(status: response.status, bundle: bundle)
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

    private func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data
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
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

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

public struct RelayCoreUpgradeResponse: Equatable, Sendable {
    public let status: Int
    public let readiness: RelayUpgradeReadiness

    public init(status: Int, readiness: RelayUpgradeReadiness) {
        self.status = status
        self.readiness = readiness
    }
}

private struct CoreHTTPResponse {
    let status: Int
    let body: Data
}

/// Handles explicit termination on the main dispatch queue. Top-level Swift
/// state is main-actor isolated; running this handler on a global queue causes
/// a runtime isolation trap during shutdown.
public enum RelayServiceProcess {
    @MainActor
    public static func waitForTermination(
        _ shutdown: @escaping @MainActor @Sendable (_ signalNumber: Int32) -> Void
    ) -> Never {
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                shutdown(number)
                exit(0)
            }
            source.resume()
            return source
        }
        withExtendedLifetime(sources) {
            dispatchMain()
        }
    }
}

public enum RelayCoreLauncher {
    public static func attachExisting(applicationDirectory: URL) throws -> RelayCoreClient {
        let controlToken = try RelayCoreControlToken.load(
            at: applicationDirectory.appendingPathComponent("core-control-token")
        )
        let client = RelayCoreClient(
            infoFile: applicationDirectory.appendingPathComponent("relay-url"),
            controlToken: controlToken
        )
        guard client.isHealthy() else {
            throw RelayCoreError.serviceFailed(
                "the Production core is not running. Start the installed Parley app before attaching Development"
            )
        }
        return client
    }

    public static func ensureRunning(
        applicationDirectory: URL,
        cwd: String,
        environment: [String: String],
        tmuxSessionName: String = "parley",
        runtimeMarker: String? = nil,
        executable suppliedExecutable: URL? = nil,
        timeout: TimeInterval = 10
    ) throws -> RelayCoreClient {
        let controlToken = try RelayCoreControlToken.loadOrCreate(
            at: applicationDirectory.appendingPathComponent("core-control-token")
        )
        let infoFile = applicationDirectory.appendingPathComponent("relay-url")
        let client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
        if client.isHealthy() { return client }

        let executable = suppliedExecutable ?? resolveExecutable(environment: environment)
        guard let executable else { throw RelayCoreError.serviceExecutableNotFound }

        let logFile = applicationDirectory.appendingPathComponent("core.log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        let log = try FileHandle(forWritingTo: logFile)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--application-directory", applicationDirectory.path,
            "--cwd", cwd,
            "--tmux-session", tmuxSessionName,
        ]
        if let runtimeMarker {
            process.arguments?.append(contentsOf: ["--runtime-marker", runtimeMarker])
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if client.isHealthy() { return client }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let timedOut = process.isRunning
        let lastOutput = (try? Data(contentsOf: logFile)).flatMap { data -> String? in
            guard !data.isEmpty else { return nil }
            return String(decoding: data.suffix(2_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let reason = timedOut ? "startup timed out" : "service exited with status \(process.terminationStatus)"
        let detail = lastOutput.map { "\(reason). Last service output:\n\($0)" } ?? reason
        if timedOut { process.terminate() }
        throw RelayCoreError.serviceFailed(detail)
    }

    public static func resolveExecutable(
        environment: [String: String],
        bundleExecutable: URL? = Bundle.main.executableURL,
        argument0: String = CommandLine.arguments[0]
    ) -> URL? {
        if let override = environment["PARLEY_CORE_SERVICE"], override.hasPrefix("/") {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        let candidates = [
            bundleExecutable?.deletingLastPathComponent().appendingPathComponent("parley-core-service"),
            URL(fileURLWithPath: argument0).standardizedFileURL
                .deletingLastPathComponent().appendingPathComponent("parley-core-service"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
