import Darwin
import Dispatch
import Foundation

public enum RelayFileTransportError: LocalizedError {
    case invalidRuntimeDirectory(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRuntimeDirectory(detail):
            "Parley agent transport refused its runtime directory: \(detail)"
        case let .runtime(detail):
            "Parley agent transport: \(detail)"
        }
    }
}

/// A sandbox-compatible request/response door for commands issued from agent
/// panes. Each pane receives one capability-named endpoint and its mandatory
/// outer process sandbox denies every sibling endpoint. The native UI continues
/// to use the relay socket; this transport carries only pane-authenticated agent
/// commands.
public final class RelayFileTransport: @unchecked Sendable {
    public static let maximumBodyBytes = 200_000

    public let runtimeDirectory: URL

    private let broker: RelayBroker
    private let credentials: RelayCredentials
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "parley.native.agent-file-transport", qos: .utility)
    private let workers = DispatchGroup()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat = Date.distantPast

    public init(
        broker: RelayBroker,
        credentials: RelayCredentials,
        runtimeDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.broker = broker
        self.credentials = credentials
        self.runtimeDirectory = runtimeDirectory
        self.fileManager = fileManager
    }

    public static func runtimeDirectory(
        applicationDirectory: URL,
        temporaryRoot: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    ) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in applicationDirectory.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let suffix = String(format: "%016llx", hash)
        return temporaryRoot.appendingPathComponent("parley-native-\(getuid())-\(suffix)", isDirectory: true)
    }

    public static func endpointDirectory(runtimeDirectory: URL, paneToken: String) -> URL {
        runtimeDirectory.appendingPathComponent(paneToken, isDirectory: true)
    }

    @discardableResult
    public static func prepareEndpoint(
        runtimeDirectory: URL,
        paneToken: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isPaneCapability(paneToken) else {
            throw RelayFileTransportError.invalidRuntimeDirectory("invalid pane capability")
        }
        try prepareDirectory(runtimeDirectory, createParents: true, fileManager: fileManager)
        let endpoint = endpointDirectory(runtimeDirectory: runtimeDirectory, paneToken: paneToken)
        try prepareDirectory(endpoint, createParents: false, fileManager: fileManager)
        for name in ["inbox", "processing", "outbox"] {
            try prepareDirectory(
                endpoint.appendingPathComponent(name, isDirectory: true),
                createParents: false,
                fileManager: fileManager
            )
        }
        return endpoint
    }

    public func start() throws {
        try lock.withLock {
            guard timer == nil else { throw RelayFileTransportError.runtime("transport is already running") }
            try Self.prepareDirectory(runtimeDirectory, createParents: true, fileManager: fileManager)
            let retainedTokens = Set(try credentials.allTokens())
            for token in retainedTokens {
                _ = try Self.prepareEndpoint(
                    runtimeDirectory: runtimeDirectory,
                    paneToken: token,
                    fileManager: fileManager
                )
            }
            try removeOrphanedEndpoints(retaining: retainedTokens)
            try discardStaleExchangeFiles()
            try writeHeartbeats()

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.serviceTick() }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
        for endpoint in endpointDirectories() {
            try? fileManager.removeItem(at: heartbeat(in: endpoint))
        }
        _ = workers.wait(timeout: .now() + 2)
    }

    private func serviceTick() {
        if Date().timeIntervalSince(lastHeartbeat) >= 1 {
            try? writeHeartbeats()
        }
        for endpoint in endpointDirectories() {
            let inbox = endpoint.appendingPathComponent("inbox", isDirectory: true)
            let processing = endpoint.appendingPathComponent("processing", isDirectory: true)
            guard let candidates = try? fileManager.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let requestID = candidate.lastPathComponent
                guard Self.isRequestID(requestID),
                      fileManager.fileExists(atPath: candidate.appendingPathComponent("ready").path) else { continue }
                let claimed = processing.appendingPathComponent(requestID, isDirectory: true)
                do {
                    try fileManager.moveItem(at: candidate, to: claimed)
                } catch {
                    continue
                }
                workers.enter()
                let workers = workers
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    defer { workers.leave() }
                    self?.process(requestID: requestID, directory: claimed, endpoint: endpoint)
                }
            }
        }
    }

    private func process(requestID: String, directory: URL, endpoint: URL) {
        let request: FileRequest
        do {
            request = try readRequest(from: directory, expectedToken: endpoint.lastPathComponent)
        } catch {
            try? fileManager.removeItem(at: directory)
            try? writeResponse(
                FileResponse(status: 400, body: error.localizedDescription),
                requestID: requestID,
                endpoint: endpoint
            )
            return
        }

        // Credentials and request text leave the filesystem before a blocking
        // Ask or wait begins. The worker retains only its in-memory value.
        try? fileManager.removeItem(at: directory)
        let response = route(request) { [weak self] handoffID in
            try? self?.writeAskAcceptance(
                handoffID: handoffID,
                requestID: requestID,
                endpoint: endpoint
            )
        }
        try? writeResponse(response, requestID: requestID, endpoint: endpoint)
    }

    private func route(_ request: FileRequest, onAskAccepted: @escaping (String) -> Void) -> FileResponse {
        switch request.command {
        case "whoami":
            return encode(broker.agentIdentity(token: request.token))
        case "panes":
            return encode(broker.agentPanes(token: request.token))
        case "events":
            return encode(broker.agentEvents(token: request.token, since: request.item))
        case "signal":
            return encode(broker.handleVendorSignal(token: request.token, signal: request.item))
        case "relay":
            return encode(broker.handle(
                token: request.token,
                target: request.target,
                text: request.body,
                idempotencyKey: request.idempotencyKey
            ))
        case "paste":
            return encode(broker.handlePaste(
                token: request.token,
                target: request.target,
                text: request.body,
                idempotencyKey: request.idempotencyKey
            ))
        case "ask":
            return encode(broker.handleAsk(
                token: request.token,
                target: request.target,
                text: request.body,
                idempotencyKey: request.idempotencyKey,
                onAccepted: onAskAccepted
            ))
        case "ask-many":
            return encode(broker.handleAskMany(
                token: request.token,
                targets: request.target,
                text: request.body,
                idempotencyKey: request.idempotencyKey
            ))
        case "context-draft":
            return encode(broker.handleContextDraft(
                token: request.token,
                name: request.item,
                path: request.target,
                text: request.body
            ))
        case "context-add":
            return encode(broker.handleContextAdd(
                token: request.token,
                draftID: request.item,
                path: request.target,
                text: request.body
            ))
        case "context-list":
            return encode(broker.contextDrafts(token: request.token))
        case "context-show":
            return encode(broker.contextDraft(token: request.token, draftID: request.item))
        case "context-discard":
            return encode(broker.discardContextDraft(token: request.token, draftID: request.item))
        case "context-ask":
            return encode(broker.handleContextAsk(
                token: request.token,
                draftID: request.item,
                target: request.target,
                text: request.body,
                idempotencyKey: request.idempotencyKey,
                onAccepted: onAskAccepted
            ))
        case "answer":
            return encode(broker.handleAnswer(
                token: request.token,
                consultationID: request.item,
                text: request.body
            ))
        case "delegate":
            return encode(broker.handleDelegate(
                token: request.token,
                target: request.target,
                text: request.body,
                idempotencyKey: request.idempotencyKey
            ))
        case "status":
            return encode(broker.delegationStatus(token: request.token))
        case "wait":
            return encode(broker.waitForTrackedWork(token: request.token, handoffID: request.item))
        case "progress":
            return encode(broker.handleDelegationProgress(
                token: request.token,
                handoffID: request.item,
                text: request.body
            ))
        case "done":
            return encode(broker.handleDelegationResult(
                token: request.token,
                handoffID: request.item,
                text: request.body,
                succeeded: true
            ))
        case "done-file":
            return encode(broker.handleDelegationFileResult(
                token: request.token,
                handoffID: request.item,
                path: request.target,
                text: request.body
            ))
        case "fail":
            return encode(broker.handleDelegationResult(
                token: request.token,
                handoffID: request.item,
                text: request.body,
                succeeded: false
            ))
        case "cancel":
            return encode(broker.cancelHandoff(token: request.token, handoffID: request.item))
        default:
            return FileResponse(status: 400, body: "unknown Parley agent command")
        }
    }

    private func encode(_ response: RelayResponse) -> FileResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response.body) else {
            return FileResponse(status: 500, body: "could not encode relay response")
        }
        return FileResponse(status: response.status, body: String(decoding: data, as: UTF8.self))
    }

    private func encode(_ response: RelayTextResponse) -> FileResponse {
        FileResponse(status: response.status, body: response.text)
    }

    private func readRequest(from directory: URL, expectedToken: String) throws -> FileRequest {
        try validateDirectory(directory)
        let command = try readField("command", from: directory, maximumBytes: 32)
        let allowed = [
            "whoami", "panes", "events", "signal", "relay", "paste", "ask", "ask-many", "answer", "delegate", "status", "wait", "progress", "done", "done-file", "fail", "cancel",
            "context-draft", "context-add", "context-list", "context-show", "context-discard", "context-ask",
        ]
        guard allowed.contains(command) else { throw RelayFileTransportError.runtime("unknown command") }
        let token = try readField("token", from: directory, maximumBytes: 256)
        guard token == expectedToken else {
            throw RelayFileTransportError.runtime("pane capability does not match its endpoint")
        }
        let request = FileRequest(
            command: command,
            target: try readField("target", from: directory, maximumBytes: 1_024),
            item: try readField("item", from: directory, maximumBytes: 128),
            idempotencyKey: try readField("idempotency-key", from: directory, maximumBytes: 128),
            token: token,
            body: try readField("body", from: directory, maximumBytes: Self.maximumBodyBytes)
        )
        return request
    }

    private func readField(_ name: String, from directory: URL, maximumBytes: Int) throws -> String {
        let file = directory.appendingPathComponent(name, isDirectory: false)
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw RelayFileTransportError.runtime("invalid request field \(name)")
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw RelayFileTransportError.runtime("request field \(name) is too large")
        }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw RelayFileTransportError.runtime("request field \(name) is invalid")
        }
        return text
    }

    private func writeAskAcceptance(handoffID: String, requestID: String, endpoint: URL) throws {
        guard Self.isRequestID(requestID), Self.isRequestID(handoffID) else { return }
        let directory = try responseDirectory(requestID: requestID, endpoint: endpoint)
        guard !fileManager.fileExists(atPath: directory.appendingPathComponent("ready").path) else { return }
        try writeProtected(handoffID, to: directory.appendingPathComponent("handoff-id"))
        try writeProtected("accepted", to: directory.appendingPathComponent("accepted"))
    }

    private func writeResponse(_ response: FileResponse, requestID: String, endpoint: URL) throws {
        guard Self.isRequestID(requestID) else { return }
        let directory = try responseDirectory(requestID: requestID, endpoint: endpoint)
        guard !fileManager.fileExists(atPath: directory.appendingPathComponent("ready").path) else { return }
        try writeProtected(String(response.status), to: directory.appendingPathComponent("status"))
        try writeProtected(response.body, to: directory.appendingPathComponent("body"))
        try writeProtected("ready", to: directory.appendingPathComponent("ready"))
    }

    private func responseDirectory(requestID: String, endpoint: URL) throws -> URL {
        let outbox = endpoint.appendingPathComponent("outbox", isDirectory: true)
        let directory = outbox.appendingPathComponent(requestID, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try validateDirectory(directory)
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try validateDirectory(directory)
        }
        return directory
    }

    private static func prepareDirectory(
        _ directory: URL,
        createParents: Bool,
        fileManager: FileManager
    ) throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw RelayFileTransportError.invalidRuntimeDirectory("cannot inspect \(directory.path)")
            }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: createParents,
                attributes: [.posixPermissions: 0o700]
            )
            guard lstat(directory.path, &metadata) == 0 else {
                throw RelayFileTransportError.invalidRuntimeDirectory("cannot inspect \(directory.path)")
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid() else {
            throw RelayFileTransportError.invalidRuntimeDirectory(directory.path)
        }
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw RelayFileTransportError.invalidRuntimeDirectory("cannot protect \(directory.path)")
        }
    }

    private func validateDirectory(_ directory: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw RelayFileTransportError.runtime("invalid request directory")
        }
    }

    private func discardStaleExchangeFiles() throws {
        for endpoint in endpointDirectories() {
            for name in ["inbox", "processing", "outbox"] {
                let directory = endpoint.appendingPathComponent(name, isDirectory: true)
                let entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for entry in entries {
                    try fileManager.removeItem(at: entry)
                }
            }
        }
    }

    private func removeOrphanedEndpoints(retaining tokens: Set<String>) throws {
        for endpoint in endpointDirectories() where !tokens.contains(endpoint.lastPathComponent) {
            try fileManager.removeItem(at: endpoint)
        }
    }

    private func writeHeartbeats() throws {
        for endpoint in endpointDirectories() {
            try writeProtected(
                String(Int(Date().timeIntervalSince1970)),
                to: heartbeat(in: endpoint)
            )
        }
        lastHeartbeat = Date()
    }

    private func endpointDirectories() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runtimeDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { Self.isPaneCapability($0.lastPathComponent) }
            .filter { (try? validateDirectory($0)) != nil }
            .prefix(256)
            .map { $0 }
    }

    private func heartbeat(in endpoint: URL) -> URL {
        endpoint.appendingPathComponent("heartbeat", isDirectory: false)
    }

    private func writeProtected(_ value: String, to file: URL) throws {
        try Data(value.utf8).write(to: file, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func isRequestID(_ value: String) -> Bool {
        guard value == value.lowercased(), UUID(uuidString: value) != nil else { return false }
        return value.count == 36
    }

    private static func isPaneCapability(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 48 && bytes.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
}

private struct FileRequest {
    let command: String
    let target: String
    let item: String
    let idempotencyKey: String
    let token: String
    let body: String
}

private struct FileResponse {
    let status: Int
    let body: String
}
