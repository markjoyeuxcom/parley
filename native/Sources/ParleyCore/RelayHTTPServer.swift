import Darwin
import Dispatch
import Foundation

public enum RelayServerError: LocalizedError {
    case socket(String)
    case malformedRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .socket(detail): "Parley relay broker: \(detail)"
        case let .malformedRequest(detail): detail
        }
    }
}

/// The native UI's narrow local Unix-socket door into the persistent core.
/// Agent panes use `RelayFileTransport` because vendor sandboxes may deny every
/// network syscall, including Unix-domain socket connections.
public final class RelayHTTPServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 32_768
    private static let maximumBodyBytes = 200_000

    private let broker: RelayBroker
    private let infoFile: URL
    private let socketFile: URL
    private let controlToken: String?
    private let identity: CoreServiceIdentity
    private let shutdownRequested: @Sendable (RelayCoreShutdownReason) -> Void
    private let queue = DispatchQueue(label: "parley.native.relay", qos: .utility)
    private let connections = DispatchGroup()
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var listener: Int32 = -1
    private var shutdownCallbackSent = false

    public init(
        broker: RelayBroker,
        infoFile: URL,
        socketFile: URL? = nil,
        controlToken: String? = nil,
        identity: CoreServiceIdentity = .current(),
        shutdownRequested: @escaping @Sendable (RelayCoreShutdownReason) -> Void = { _ in }
    ) {
        self.broker = broker
        self.infoFile = infoFile
        self.socketFile = socketFile ?? infoFile.deletingLastPathComponent().appendingPathComponent("relay.sock")
        self.controlToken = controlToken
        self.identity = identity
        self.shutdownRequested = shutdownRequested
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() throws -> Int {
        try lock.withLock {
            if listener >= 0 { throw RelayServerError.socket("broker is already running") }

            try prepareSocketPath()
            let address = try unixAddress()
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw socketError("could not create socket") }

            do {
                let descriptorFlags = fcntl(descriptor, F_GETFD, 0)
                guard descriptorFlags >= 0,
                      fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                    throw socketError("could not protect socket from child-process inheritance")
                }
                var mutableAddress = address
                let bindStatus = withUnsafePointer(to: &mutableAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bindStatus == 0 else { throw socketError("could not bind local socket") }
                guard Darwin.chmod(socketFile.path, 0o600) == 0 else {
                    throw socketError("could not protect socket")
                }
                guard Darwin.listen(descriptor, 16) == 0 else { throw socketError("could not listen") }

                let flags = fcntl(descriptor, F_GETFL, 0)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw socketError("could not make listener nonblocking")
                }

                let endpoint = "unix:\(socketFile.path)"
                try endpoint.write(to: infoFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: infoFile.path)

                listener = descriptor
                let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                readSource.setEventHandler { [weak self] in self?.acceptConnections() }
                readSource.setCancelHandler { Darwin.close(descriptor) }
                source = readSource
                readSource.resume()
                return 0
            } catch {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: socketFile)
                throw error
            }
        }
    }

    public func stop() {
        broker.cancelAll()
        lock.withLock {
            guard listener >= 0 else { return }
            listener = -1
            source?.cancel()
            source = nil
            try? FileManager.default.removeItem(at: infoFile)
            try? FileManager.default.removeItem(at: socketFile)
        }
        // `cancelAll` wakes blocking Ask requests. Give those workers time to
        // return the interruption response before the service exits; otherwise
        // their callers receive curl 52 (an empty reply).
        _ = connections.wait(timeout: .now() + 2)
    }

    private func prepareSocketPath() throws {
        guard FileManager.default.fileExists(atPath: socketFile.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketFile.path)
        guard attributes[.type] as? FileAttributeType == .typeSocket else {
            throw RelayServerError.socket("refusing to replace non-socket path at \(socketFile.path)")
        }
        if try socketIsLive() {
            throw RelayServerError.socket("another Parley relay broker is already running")
        }
        try FileManager.default.removeItem(at: socketFile)
    }

    private func socketIsLive() throws -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("could not inspect existing socket") }
        defer { Darwin.close(descriptor) }
        var address = try unixAddress()
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return status == 0
    }

    private func unixAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketFile.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw RelayServerError.socket("socket path is too long: \(socketFile.path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    private func acceptConnections() {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listener, $0, &length)
                }
            }
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            let descriptorFlags = fcntl(client, F_GETFD, 0)
            if descriptorFlags < 0 || fcntl(client, F_SETFD, descriptorFlags | FD_CLOEXEC) != 0 {
                Darwin.close(client)
                continue
            }
            // The listening descriptor is nonblocking. Make the accepted
            // connection explicitly blocking so a large activity response is
            // not truncated at the first temporary EAGAIN.
            let statusFlags = fcntl(client, F_GETFL, 0)
            if statusFlags < 0 || fcntl(client, F_SETFL, statusFlags & ~O_NONBLOCK) != 0 {
                Darwin.close(client)
                continue
            }
            connections.enter()
            let connections = connections
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { connections.leave() }
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        do {
            let request = try readRequest(from: client)
            if request.method == "GET", request.path == "/health" {
                write(RelayTextResponse(status: 200, text: "ok"), to: client)
                return
            }
            if request.method == "GET", request.path == "/identity" {
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                writeJSON(identity, fallback: "could not encode core identity", to: client)
                return
            }
            if request.method == "GET", request.path == "/consultations" {
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                write(broker.consultations(), to: client)
                return
            }
            if request.method == "GET", request.path == "/handoffs/unread" {
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                write(broker.unreadHandoffs(), to: client)
                return
            }
            if request.method == "GET",
               request.path == "/handoffs" || request.path.hasPrefix("/handoffs?") {
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let limit: Int?
                if request.path == "/handoffs" {
                    limit = nil
                } else {
                    let raw = String(request.path.dropFirst("/handoffs?limit=".count))
                    guard request.path.hasPrefix("/handoffs?limit="),
                          let parsed = Int(raw), (1...500).contains(parsed) else {
                        write(RelayTextResponse(status: 400, text: "handoff limit must be between 1 and 500"), to: client)
                        return
                    }
                    limit = parsed
                }
                write(broker.handoffs(limit: limit), to: client)
                return
            }
            if request.method == "GET",
               request.path == "/activity-events" || request.path.hasPrefix("/activity-events?") {
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let limit: Int?
                if request.path == "/activity-events" {
                    limit = nil
                } else {
                    let raw = String(request.path.dropFirst("/activity-events?limit=".count))
                    guard request.path.hasPrefix("/activity-events?limit="),
                          let parsed = Int(raw), (1...500).contains(parsed) else {
                        write(RelayTextResponse(status: 400, text: "activity limit must be between 1 and 500"), to: client)
                        return
                    }
                    limit = parsed
                }
                write(broker.activityEvents(limit: limit), to: client)
                return
            }
            guard request.method == "POST" else {
                write(RelayResponse(
                    status: 404,
                    body: RelayResponseBody(ok: false, delivered: nil, submitted: nil, note: nil, error: "POST required")
                ), to: client)
                return
            }
            let authorization = request.headers["authorization"] ?? ""
            let token = authorization.range(of: "Bearer ", options: [.anchored, .caseInsensitive])
                .map { String(authorization[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
            let target = request.headers["x-parley-to"] ?? ""
            let idempotencyKey = request.headers["x-parley-idempotency-key"]
            let text = String(decoding: request.body, as: UTF8.self)
            switch request.path {
            case "/ui/shutdown-if-idle":
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let readiness = broker.prepareForUpgrade()
                writeJSON(
                    readiness,
                    status: readiness.accepted ? 202 : 409,
                    fallback: "could not encode upgrade readiness",
                    to: client
                )
                if readiness.accepted { requestShutdownOnce(.upgrade) }
            case "/ui/stop-if-idle":
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let readiness = broker.prepareForUpgrade()
                writeJSON(
                    readiness,
                    status: readiness.accepted ? 202 : 409,
                    fallback: "could not encode uninstall readiness",
                    to: client
                )
                if readiness.accepted { requestShutdownOnce(.uninstall) }
            case "/ui/activity":
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                guard let activity = try? JSONDecoder().decode(
                    RelayActivityEventRequest.self,
                    from: request.body
                ) else {
                    write(RelayTextResponse(status: 400, text: "invalid activity event request"), to: client)
                    return
                }
                do {
                    write(try broker.recordActivity(activity), to: client)
                } catch let error as RelayActivityError {
                    write(RelayTextResponse(status: 400, text: error.localizedDescription), to: client)
                } catch {
                    write(RelayTextResponse(status: 500, text: error.localizedDescription), to: client)
                }
            case "/ui/history/delete-workspace":
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                guard let scope = try? JSONDecoder().decode(
                    RelayWorkspaceHistoryDeletionRequest.self,
                    from: request.body
                ) else {
                    write(RelayTextResponse(status: 400, text: "invalid workspace history deletion request"), to: client)
                    return
                }
                write(broker.deleteWorkspaceHistory(
                    workspaceID: scope.workspaceID,
                    workspaceName: scope.workspaceName
                ), to: client)
            case let path where path.hasPrefix("/ui/read/"):
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let handoffID = String(path.dropFirst("/ui/read/".count))
                write(broker.markHandoffRead(handoffID), to: client)
            case let path where path.hasPrefix("/ui/retry/"):
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let handoffID = String(path.dropFirst("/ui/retry/".count))
                write(broker.retryHandoff(handoffID), to: client)
            case let path where path.hasPrefix("/ui/cancel/"):
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let handoffID = String(path.dropFirst("/ui/cancel/".count))
                write(broker.cancelHandoff(handoffID), to: client)
            case let path where path.hasPrefix("/ui/answer/"):
                guard controlAuthorized(request) else {
                    write(RelayTextResponse(status: 401, text: "bad control token"), to: client)
                    return
                }
                let consultationID = String(path.dropFirst("/ui/answer/".count))
                write(broker.answerFromUI(consultationID: consultationID, text: text), to: client)
            case "/relay":
                write(broker.handle(
                    token: token,
                    target: target,
                    text: text,
                    idempotencyKey: idempotencyKey
                ), to: client)
            case "/paste":
                write(broker.handlePaste(
                    token: token,
                    target: target,
                    text: text,
                    idempotencyKey: idempotencyKey
                ), to: client)
            case "/ask":
                write(broker.handleAsk(
                    token: token,
                    target: target,
                    text: text,
                    idempotencyKey: idempotencyKey
                ), to: client)
            case "/ask-many":
                write(broker.handleAskMany(
                    token: token,
                    targets: target,
                    text: text,
                    idempotencyKey: idempotencyKey
                ), to: client)
            case "/delegate":
                write(broker.handleDelegate(
                    token: token,
                    target: target,
                    text: text,
                    idempotencyKey: idempotencyKey
                ), to: client)
            case "/status":
                write(broker.delegationStatus(token: token), to: client)
            case let path where path.hasPrefix("/wait/"):
                let handoffID = String(path.dropFirst("/wait/".count))
                write(broker.waitForDelegation(token: token, handoffID: handoffID), to: client)
            case let path where path.hasPrefix("/done/"):
                let handoffID = String(path.dropFirst("/done/".count))
                write(broker.handleDelegationResult(
                    token: token,
                    handoffID: handoffID,
                    text: text,
                    succeeded: true
                ), to: client)
            case let path where path.hasPrefix("/fail/"):
                let handoffID = String(path.dropFirst("/fail/".count))
                write(broker.handleDelegationResult(
                    token: token,
                    handoffID: handoffID,
                    text: text,
                    succeeded: false
                ), to: client)
            case let path where path.hasPrefix("/answer/"):
                let consultationID = String(path.dropFirst("/answer/".count))
                write(broker.handleAnswer(token: token, consultationID: consultationID, text: text), to: client)
            default:
                write(RelayResponse(
                    status: 404,
                    body: RelayResponseBody(
                        ok: false,
                        delivered: nil,
                        submitted: nil,
                        note: nil,
                        error: "POST /relay, /paste, /ask, /ask-many, /answer/<id>, /delegate, /status, /wait/<id>, /done/<id>, /fail/<id>, /ui/activity, /ui/answer/<id>, /ui/cancel/<id>, /ui/retry/<id> or /ui/read/<id>"
                    )
                ), to: client)
            }
        } catch {
            write(RelayResponse(
                status: 400,
                body: RelayResponseBody(ok: false, delivered: nil, submitted: nil, note: nil, error: error.localizedDescription)
            ), to: client)
        }
    }

    private func readRequest(from client: Int32) throws -> Request {
        let headerMarker = Data("\r\n\r\n".utf8)
        var received = Data()
        var expectedLength: Int?
        var bodyStart: Int?
        var parsedHead: (method: String, path: String, headers: [String: String])?

        while true {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { throw RelayServerError.malformedRequest("incomplete relay request") }
            received.append(contentsOf: buffer.prefix(count))

            if parsedHead == nil, let marker = received.range(of: headerMarker) {
                guard marker.lowerBound <= Self.maximumHeaderBytes else {
                    throw RelayServerError.malformedRequest("relay headers too large")
                }
                let headData = received[..<marker.lowerBound]
                let head = try parseHead(Data(headData))
                guard let rawLength = head.headers["content-length"], let length = Int(rawLength), length >= 0 else {
                    throw RelayServerError.malformedRequest("relay needs Content-Length")
                }
                guard length <= Self.maximumBodyBytes else {
                    throw RelayServerError.malformedRequest("relay text too long")
                }
                parsedHead = head
                expectedLength = length
                bodyStart = marker.upperBound
            }

            if let parsedHead, let expectedLength, let bodyStart,
               received.count >= bodyStart + expectedLength {
                let body = received.subdata(in: bodyStart..<(bodyStart + expectedLength))
                return Request(method: parsedHead.method, path: parsedHead.path, headers: parsedHead.headers, body: body)
            }
            if received.count > Self.maximumHeaderBytes + Self.maximumBodyBytes {
                throw RelayServerError.malformedRequest("relay request too large")
            }
        }
    }

    private func parseHead(_ data: Data) throws -> (method: String, path: String, headers: [String: String]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayServerError.malformedRequest("relay headers are not UTF-8")
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { throw RelayServerError.malformedRequest("malformed relay request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (String(request[0]), String(request[1]), headers)
    }

    private func write(_ response: RelayResponse, to client: Int32) {
        guard let body = try? JSONEncoder().encode(response.body) else { return }
        let reason: String = switch response.status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        default: "Error"
        }
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8) + body, to: client)
    }

    private func write(_ response: RelayTextResponse, to client: Int32) {
        let body = Data(response.text.utf8)
        let head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8) + body, to: client)
    }

    private func write(_ consultations: [RelayConsultation], to client: Int32) {
        guard let body = try? JSONEncoder().encode(consultations) else {
            write(RelayTextResponse(status: 500, text: "could not encode consultations"), to: client)
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8) + body, to: client)
    }

    private func write(_ handoffs: [RelayHandoff], to client: Int32) {
        guard let body = try? JSONEncoder().encode(handoffs) else {
            write(RelayTextResponse(status: 500, text: "could not encode handoffs"), to: client)
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8) + body, to: client)
    }

    private func write(_ events: [RelayActivityEvent], to client: Int32) {
        writeJSON(events, fallback: "could not encode activity events", to: client)
    }

    private func write(_ event: RelayActivityEvent, to client: Int32) {
        writeJSON(event, fallback: "could not encode activity event", to: client)
    }

    private func writeJSON<Value: Encodable>(
        _ value: Value,
        status: Int = 200,
        fallback: String,
        to client: Int32
    ) {
        guard let body = try? JSONEncoder().encode(value) else {
            write(RelayTextResponse(status: 500, text: fallback), to: client)
            return
        }
        let head = "HTTP/1.1 \(status) \(reason(for: status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8) + body, to: client)
    }

    private func requestShutdownOnce(_ reason: RelayCoreShutdownReason) {
        let shouldRequest = lock.withLock { () -> Bool in
            guard !shutdownCallbackSent else { return false }
            shutdownCallbackSent = true
            return true
        }
        guard shouldRequest else { return }
        shutdownRequested(reason)
    }

    private func controlAuthorized(_ request: Request) -> Bool {
        guard let controlToken else { return false }
        let presented = request.headers["x-parley-control"] ?? ""
        let left = Array(controlToken.utf8)
        let right = Array(presented.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }

    private func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        default: "Error"
        }
    }

    private func send(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.send(client, base.advanced(by: written), raw.count - written, 0)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return }
                written += count
            }
        }
    }

    private func socketError(_ prefix: String) -> RelayServerError {
        RelayServerError.socket("\(prefix): \(String(cString: strerror(errno)))")
    }
}

private struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}
