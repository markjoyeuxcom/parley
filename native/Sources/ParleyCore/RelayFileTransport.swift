import Darwin
import Dispatch
import Foundation

public enum RelayFileTransportError: LocalizedError {
    case invalidRuntimeDirectory(String)
    case runtime(String)
    /// A request field over its bound, so a caller can say which bound.
    case fieldTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRuntimeDirectory(detail):
            "Parley agent transport refused its runtime directory: \(detail)"
        case let .runtime(detail):
            "Parley agent transport: \(detail)"
        case let .fieldTooLarge(name):
            "Parley agent transport: request field \(name) is too large"
        }
    }
}

/// The three clocks the transport compares times on, each chosen for what it
/// measures. Injectable so a check can model a sleep (wall and monotonic
/// jump, awake time does not) or a clock step (wall alone moves).
public struct RelayTransportClocks: Sendable {
    /// Written into heartbeats and compared with reply file times.
    public var wall: @Sendable () -> Date
    /// Nanoseconds that keep counting through sleep and never step back:
    /// when a heartbeat is due.
    public var monotonic: @Sendable () -> UInt64
    /// Nanoseconds that stop while the Mac sleeps: how long a shim, frozen
    /// by that sleep too, has had to act.
    public var awake: @Sendable () -> UInt64

    public init(wall: @escaping @Sendable () -> Date, monotonic: @escaping @Sendable () -> UInt64, awake: @escaping @Sendable () -> UInt64) {
        self.wall = wall
        self.monotonic = monotonic
        self.awake = awake
    }

    public static let system = RelayTransportClocks(
        wall: { Date() },
        monotonic: { clock_gettime_nsec_np(CLOCK_MONOTONIC) },
        awake: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    )
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
    /// Issues and redeems one-use tickets. Nil in fixtures that have no
    /// socket; every pane's policy is then unavailable and requests stay
    /// token-only, exactly as before tickets existed.
    private let tickets: RelayTicketServer?
    private let fileManager: FileManager
    private let clocks: RelayTransportClocks
    private let queue = DispatchQueue(label: "parley.native.agent-file-transport", qos: .utility)
    private let workers = DispatchGroup()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// When heartbeats were last written, on the monotonic clock, which keeps
    /// counting through sleep and never steps backwards. A wall-clock
    /// comparison stopped every heartbeat for as long as a clock stepped back.
    private var lastHeartbeat: UInt64?
    /// Written as every heartbeat's content, new on every `start()`. A restart
    /// discards the requests shims are still waiting on, and a request leaves
    /// the filesystem while it is processed, so a shim learns its request is
    /// gone only from the instance changing (0b58a71e).
    private var instance = ""
    private var schedule = TransportPollSchedule()
    /// Request directories seen without their `ready` marker, by first
    /// sighting. A shim finishes writing within milliseconds; the fast
    /// follow-up lasts `pendingFollowUpWindow`, after which the directory
    /// is polled at the normal cadence, and past `abandonedRequestAge` it is
    /// discarded as a writer that crashed mid-request. Sightings are in
    /// awake time, which stops while the Mac sleeps: a shim frozen part-way
    /// through a request gets its full time once the Mac wakes.
    private var pendingSince: [String: UInt64] = [:]
    /// Uncollected replies already older than `staleResponseAge` by their
    /// file time, by first sighting in awake time.
    private var staleSince: [String: UInt64] = [:]
    /// A shim's hidden inbox scratch (a staged body, a wake entry) by path:
    /// its modification time when last seen, and since when (awake time)
    /// it has not changed. The tick never lists hidden entries, so this is
    /// what removes the scratch of a shim that was killed.
    private var scratchSince: [String: (modified: Date, since: UInt64)] = [:]
    public static let pendingFollowUpWindow: TimeInterval = 0.25
    public let abandonedRequestAge: TimeInterval
    /// Requests that can block for minutes. They count against
    /// `blockingGate`; every other request is short and never counted.
    public static let blockingCommands: Set<String> = ["wait", "ask", "ask-many", "context-ask", "request-run", "team-request", "team-add"]
    public static let defaultMaximumBlockingRequests = 64
    public static let defaultWaitWindow: TimeInterval = 55
    /// A reply nobody collected within this age is removed: its shim is
    /// gone. A live shim collects its reply within half a second.
    public static let defaultStaleResponseAge: TimeInterval = 600
    public let waitWindow: TimeInterval
    public let staleResponseAge: TimeInterval
    /// At most this many request threads at once. A burst past it waits in
    /// the inbox and is claimed as threads finish, so a flood of short
    /// requests cannot create threads without bound.
    public static let defaultMaximumWorkerThreads = 128
    private let maximumWorkerThreads: Int
    private var runningWorkers = 0
    private var peakWorkers = 0
    /// The most request threads that have run at once (diagnostics and checks).
    public var peakWorkerThreads: Int { lock.withLock { peakWorkers } }
    public var maximumWorkerThreadLimit: Int { maximumWorkerThreads }
    private let blockingGate: BlockingRequestGate
    public var activeBlockingRequests: Int { blockingGate.activeCount }
    /// At most four staging requests hold their bodies at once: each may be
    /// a 10 MB image, where every other request holds at most 200 KB, so 128
    /// request threads could otherwise hold 1.3 GB.
    private let stagingSlots = DispatchSemaphore(value: 4)
    /// Ticks serviced so far (diagnostics and checks).
    public var tickCount: Int { lock.withLock { ticks } }
    private var ticks = 0
    /// One directory watcher per endpoint inbox (keyed by pane capability):
    /// a write there wakes the transport at once, so the timer can back off.
    private var inboxWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// The fallback timer's current cadence (diagnostics and checks).
    public var currentPollInterval: DispatchTimeInterval { lock.withLock { schedule.interval } }
    /// How many times an inbox watcher woke the transport (diagnostics and checks).
    public var watcherWakeCount: Int { lock.withLock { wakes } }
    private var wakes = 0
    /// Ticks that claimed or held back work, the part of those held back
    /// because every request thread was busy, and ticks kept on the fast
    /// cadence by a request still being written (diagnostics and checks).
    /// With the watcher wakes they say what kept a transport from backing off:
    /// once in CI it made 28 ticks in 8 s without reaching idle (Prax 24e184f8).
    public var activeTickCount: Int { lock.withLock { activeTicks } }
    public var saturatedTickCount: Int { lock.withLock { saturatedTicks } }
    public var pendingTickCount: Int { lock.withLock { pendingTicks } }
    private var activeTicks = 0
    private var saturatedTicks = 0
    private var pendingTicks = 0

    public init(
        broker: RelayBroker,
        credentials: RelayCredentials,
        runtimeDirectory: URL,
        tickets: RelayTicketServer? = nil,
        fileManager: FileManager = .default,
        abandonedRequestAge: TimeInterval = 30,
        maximumBlockingRequests: Int = RelayFileTransport.defaultMaximumBlockingRequests,
        waitWindow: TimeInterval = RelayFileTransport.defaultWaitWindow,
        staleResponseAge: TimeInterval = RelayFileTransport.defaultStaleResponseAge,
        maximumWorkerThreads: Int = RelayFileTransport.defaultMaximumWorkerThreads,
        clocks: RelayTransportClocks = .system
    ) {
        self.broker = broker
        self.credentials = credentials
        self.tickets = tickets
        self.runtimeDirectory = runtimeDirectory
        self.fileManager = fileManager
        self.clocks = clocks
        self.abandonedRequestAge = max(0.1, abandonedRequestAge)
        self.blockingGate = BlockingRequestGate(limit: maximumBlockingRequests)
        self.waitWindow = max(0.1, waitWindow)
        self.staleResponseAge = max(0.1, staleResponseAge)
        // Blocking requests hold their threads, so the limit always leaves
        // at least one above them for done, answer and the other short ones.
        self.maximumWorkerThreads = max(maximumWorkerThreads, blockingGate.limit + 1)
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
            instance = UUID().uuidString.lowercased()
            try Self.prepareDirectory(runtimeDirectory, createParents: true, fileManager: fileManager)
            let retainedTokens = Set(try credentials.allTokens())
            for token in retainedTokens {
                _ = try Self.prepareEndpoint(
                    runtimeDirectory: runtimeDirectory,
                    paneToken: token,
                    fileManager: fileManager
                )
            }
            // The same prune as every heartbeat: folders listed before the
            // capabilities are read, and one that cannot be removed does not
            // stop the core from starting.
            pruneRetiredEndpoints()
            discardStaleExchangeFiles()
            writeHeartbeats()

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: schedule.interval, leeway: .milliseconds(10))
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
        // Cancelling does not wait for a tick already running, which could
        // write a heartbeat after the removal below, telling shims a stopped
        // transport is alive, or recreate the inbox watchers. On the serial
        // queue no tick runs alongside this block, and none follows it.
        queue.sync {
            lock.withLock {
                for watcher in inboxWatchers.values { watcher.cancel() }
                inboxWatchers.removeAll()
            }
        }
        for endpoint in endpointDirectories() {
            try? fileManager.removeItem(at: heartbeat(in: endpoint))
        }
        _ = workers.wait(timeout: .now() + 2)
    }

    private func serviceTick() {
        // A stopped transport writes nothing, whatever event arrives late.
        guard lock.withLock({ () -> Bool in
            guard timer != nil else { return false }
            ticks += 1
            return true
        }) else { return }
        let now = clocks.wall()
        let uptime = clocks.awake()
        if lastHeartbeat.map({ clocks.monotonic() &- $0 >= 1_000_000_000 }) ?? true {
            pruneRetiredEndpoints()
            writeHeartbeats()
            removeStaleResponses(now: now, uptime: uptime)
            removeDeadShimScratch(uptime: uptime)
        }
        var activity = false
        // A request directory that exists but has no `ready` marker yet: the
        // shim is still writing it. The watcher fired on the directory's
        // creation, so follow up quickly rather than waiting a full cadence,
        // but only for a bounded window; an abandoned directory must not keep
        // the transport spinning.
        var pending = false
        var seenWithoutReady: Set<String> = []
        let endpoints = endpointDirectories()
        syncInboxWatchers(endpoints)
        var saturated = false
        for endpoint in endpoints where !saturated {
            let inbox = endpoint.appendingPathComponent("inbox", isDirectory: true)
            let processing = endpoint.appendingPathComponent("processing", isDirectory: true)
            guard let candidates = try? fileManager.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let requestID = candidate.lastPathComponent
                guard Self.isRequestID(requestID) else { continue }
                guard fileManager.fileExists(atPath: candidate.appendingPathComponent("ready").path) else {
                    seenWithoutReady.insert(requestID)
                    let firstSeen = lock.withLock { () -> UInt64 in
                        if let existing = pendingSince[requestID] { return existing }
                        pendingSince[requestID] = uptime
                        return uptime
                    }
                    let age = Double(uptime &- firstSeen) / 1_000_000_000
                    if age > abandonedRequestAge {
                        // The writer never finished; nothing was claimed or answered.
                        try? fileManager.removeItem(at: candidate)
                        _ = lock.withLock { pendingSince.removeValue(forKey: requestID) }
                    } else if age <= Self.pendingFollowUpWindow {
                        pending = true
                    }
                    continue
                }
                let reserved = lock.withLock { () -> Bool in
                    guard runningWorkers < maximumWorkerThreads else { return false }
                    runningWorkers += 1
                    peakWorkers = max(peakWorkers, runningWorkers)
                    return true
                }
                guard reserved else {
                    // Left in the inbox; the fast cadence claims it as threads free up.
                    saturated = true
                    activity = true
                    break
                }
                let claimed = processing.appendingPathComponent(requestID, isDirectory: true)
                do {
                    try fileManager.moveItem(at: candidate, to: claimed)
                } catch {
                    lock.withLock { runningWorkers -= 1 }
                    continue
                }
                activity = true
                workers.enter()
                let workers = workers
                // A thread of its own, never the shared pool: see RelayWorkerThread.
                RelayWorkerThread.start(name: "parley.relay.request") { [weak self] in
                    defer {
                        self?.lock.withLock { self?.runningWorkers -= 1 }
                        workers.leave()
                    }
                    self?.process(requestID: requestID, directory: claimed, endpoint: endpoint)
                }
            }
        }
        lock.withLock {
            pendingSince = pendingSince.filter { seenWithoutReady.contains($0.key) }
            if activity { activeTicks += 1 }
            if saturated { saturatedTicks += 1 }
            if pending { pendingTicks += 1 }
            let before = schedule.interval
            schedule.observe(activity: activity || pending)
            if pending {
                timer?.schedule(deadline: .now() + .milliseconds(5), repeating: schedule.interval, leeway: .milliseconds(2))
            } else if schedule.interval != before {
                rescheduleLocked()
            }
        }
    }

    /// Runs on the transport queue with `lock` held.
    private func rescheduleLocked() {
        timer?.schedule(deadline: .now() + schedule.interval, repeating: schedule.interval, leeway: .milliseconds(10))
    }

    /// Keeps one vnode watcher per live endpoint inbox. A watcher fires on the
    /// transport queue, restores the active cadence and services the tick
    /// immediately, so a backed-off timer never delays an agent's request.
    private func syncInboxWatchers(_ endpoints: [URL]) {
        let live = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.lastPathComponent, $0) })
        lock.withLock {
            for (token, watcher) in inboxWatchers where live[token] == nil {
                watcher.cancel()
                inboxWatchers.removeValue(forKey: token)
            }
            for (token, endpoint) in live where inboxWatchers[token] == nil {
                let inbox = endpoint.appendingPathComponent("inbox", isDirectory: true)
                let descriptor = open(inbox.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .link, .rename, .delete], queue: queue)
                watcher.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        self.wakes += 1
                        self.schedule.wake()
                        self.rescheduleLocked()
                    }
                    self.serviceTick()
                }
                watcher.setCancelHandler { close(descriptor) }
                watcher.resume()
                inboxWatchers[token] = watcher
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
        let blocking = Self.blockingCommands.contains(request.command)
        if blocking, !blockingGate.enter() {
            try? writeResponse(
                FileResponse(status: 503, body: "Parley already has \(blockingGate.limit) agent requests waiting on this Mac; nothing was sent. Try again in a minute."),
                requestID: requestID,
                endpoint: endpoint
            )
            return
        }
        defer { if blocking { blockingGate.leave() } }
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
        case "request-run":
            return encode(broker.handleCommandRun(token: request.token, folder: request.target, body: request.body,
                idempotencyKey: request.idempotencyKey, onAccepted: onAskAccepted))
        case "team-request":
            return encode(broker.handleTeamRequest(token: request.token, body: request.body,
                idempotencyKey: request.idempotencyKey, onAccepted: onAskAccepted))
        case "team-add":
            return encode(broker.handleTeamAdd(token: request.token, body: request.body,
                idempotencyKey: request.idempotencyKey, onAccepted: onAskAccepted))
        case "team-status":
            return encode(broker.handleTeamStatus(token: request.token))
        case "whoami":
            return encode(broker.agentIdentity(token: request.token, attestation: request.attestation, ticketPolicy: request.ticketPolicy))
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
                content: request.image.map(AgentStagedContent.image) ?? .text(request.body)
            ))
        case "context-add":
            return encode(broker.handleContextAdd(
                token: request.token,
                draftID: request.item,
                path: request.target,
                content: request.image.map(AgentStagedContent.image) ?? .text(request.body)
            ))
        case "image":
            let response = broker.handleImageFetch(token: request.token, digest: request.item)
            return FileResponse(status: response.status, body: "", data: response.body)
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
                idempotencyKey: request.idempotencyKey,
                inReplyToHandoffID: request.item.isEmpty ? nil : request.item
            ))
        case "status":
            return encode(broker.delegationStatus(token: request.token))
        case "wait":
            // A bounded long-poll: after `waitWindow` the shim is told to ask
            // again, so a wait whose shim a vendor killed holds its thread
            // for at most one window.
            return encode(broker.waitForTrackedWork(token: request.token, handoffID: request.item, within: waitWindow))
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
                content: request.image.map(AgentStagedContent.image) ?? .text(request.body)
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
        let fields = try RelayRequestFields(runtimeDirectory: runtimeDirectory,
            components: [expectedToken, "processing", directory.lastPathComponent])
        func field(_ name: String, maximumBytes: Int) throws -> String {
            try fields.read(name, maximumBytes: maximumBytes)!
        }
        let command = try field("command", maximumBytes: 32)
        let allowed = [
            "request-run", "team-request", "team-add", "team-status", "whoami", "panes", "events", "signal", "relay", "paste", "ask", "ask-many", "answer", "delegate", "status", "wait", "progress", "done", "done-file", "fail", "cancel",
            "context-draft", "context-add", "context-list", "context-show", "context-discard", "context-ask", "image",
        ]
        guard allowed.contains(command) else { throw RelayFileTransportError.runtime("unknown command") }
        let token = try field("token", maximumBytes: 256)
        guard token == expectedToken else {
            throw RelayFileTransportError.runtime("pane capability does not match its endpoint")
        }
        // A ticket proves the kernel saw the caller and that the caller
        // descends from this pane. Whether one is demanded is the pane's
        // policy; a ticket that arrives is always checked and consumed.
        guard let policy = broker.ticketPolicy(token: token, socketListening: tickets?.isListening ?? false) else {
            throw RelayFileTransportError.runtime("the source agent pane is not running or its capability is invalid")
        }
        let attestation: RelayAttestation
        if let ticket = try fields.read("ticket", maximumBytes: 64, optional: true)?.trimmingCharacters(in: .whitespacesAndNewlines), !ticket.isEmpty {
            guard let tickets, tickets.redeem(ticket, token: token, requestID: directory.lastPathComponent) else {
                throw RelayFileTransportError.runtime("the ticket is invalid, expired or already used")
            }
            attestation = .peerVerified
        } else if policy.requirement == .required {
            throw RelayFileTransportError.runtime("a ticket is required for this pane and none was presented: \(policy.reason)")
        } else {
            attestation = .tokenOnly
        }
        // A staged file may be an image, up to the image limit; anything else
        // is text within the ordinary body limit, as before images existed.
        var body = ""
        var image: Data?
        var stagingSlot: StagingSlot?
        if ["context-draft", "context-add", "done-file"].contains(command) {
            guard stagingSlots.wait(timeout: .now() + 30) == .success else {
                throw RelayFileTransportError.runtime("Parley is staging other files from panes; nothing was staged, so try again")
            }
            stagingSlot = StagingSlot(stagingSlots)
            let tooLarge = RelayFileTransportError.runtime(
                "the file is too large: Parley accepts a PNG or JPEG image of at most \(ContextImageInspector.maximumBytes) bytes and any other file of at most \(Self.maximumBodyBytes) bytes, so nothing was staged"
            )
            let data: Data
            do { data = try fields.readData("body", maximumBytes: max(Self.maximumBodyBytes, ContextImageInspector.maximumBytes))! }
            catch RelayFileTransportError.fieldTooLarge { throw tooLarge }
            if ContextImageInspector.looksLikeImage(data) {
                image = data
            } else {
                guard data.count <= Self.maximumBodyBytes else { throw tooLarge }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw RelayFileTransportError.runtime("request field body is not UTF-8")
                }
                body = text
            }
        } else {
            body = try field("body", maximumBytes: Self.maximumBodyBytes)
        }
        var request = FileRequest(
            command: command,
            target: try field("target", maximumBytes: command == "request-run" ? 4_096 : 1_024),
            item: try field("item", maximumBytes: 128),
            idempotencyKey: try field("idempotency-key", maximumBytes: 128),
            token: token,
            body: body,
            attestation: attestation,
            ticketPolicy: policy
        )
        request.image = image
        request.stagingSlot = stagingSlot
        return request
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
        try writeProtected(response.data ?? Data(response.body.utf8), to: directory.appendingPathComponent("body"))
        try writeProtected("ready", to: directory.appendingPathComponent("ready"))
    }

    /// Replies whose shim never collected them: a vendor killed the shim,
    /// typically while a wait or Ask was in progress. Only a finished reply
    /// (`ready` present) is removed; an Ask still in progress keeps its
    /// acceptance files. A file time also counts the time the Mac slept, so
    /// after a wake every reply looks old, including one a shim frozen by
    /// that sleep is about to collect; a reply is removed only once it has
    /// also stayed stale for up to 30 seconds of awake time.
    private func removeStaleResponses(now: Date, uptime: UInt64) {
        let grace = UInt64(min(staleResponseAge, 30) * 1_000_000_000)
        var stillStale: [String: UInt64] = [:]
        for endpoint in endpointDirectories() {
            let outbox = endpoint.appendingPathComponent("outbox", isDirectory: true)
            guard let replies = try? fileManager.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil, options: []) else { continue }
            for reply in replies where Self.isRequestID(reply.lastPathComponent) {
                let ready = reply.appendingPathComponent("ready")
                guard let written = (try? fileManager.attributesOfItem(atPath: ready.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(written) > staleResponseAge else { continue }
                let firstSeen = lock.withLock { staleSince[reply.path] } ?? uptime
                if uptime &- firstSeen >= grace {
                    try? fileManager.removeItem(at: reply)
                } else {
                    stillStale[reply.path] = firstSeen
                }
            }
        }
        lock.withLock { staleSince = stillStale }
    }

    /// Scratch that has not changed for `staleResponseAge` of awake time
    /// belongs to a shim that is gone: a producer still writing a body keeps
    /// changing it, and a wake entry lasts microseconds.
    private func removeDeadShimScratch(uptime: UInt64) {
        let age = UInt64(staleResponseAge * 1_000_000_000)
        var seen: [String: (modified: Date, since: UInt64)] = [:]
        let previous = lock.withLock { scratchSince }
        for endpoint in endpointDirectories() {
            let inbox = endpoint.appendingPathComponent("inbox", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: []) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasPrefix(".body-") || name.hasPrefix(".wake-"),
                      let modified = (try? fileManager.attributesOfItem(atPath: entry.path))?[.modificationDate] as? Date else { continue }
                let since = previous[entry.path].flatMap { $0.modified == modified ? $0.since : nil } ?? uptime
                if uptime &- since >= age {
                    try? fileManager.removeItem(at: entry)
                } else {
                    seen[entry.path] = (modified, since)
                }
            }
        }
        lock.withLock { scratchSince = seen }
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

    /// Entry by entry: something a pane left that cannot be removed (a
    /// container can write into its own endpoint) must not stop the core.
    /// Hidden inbox entries are a live shim's scratch (a body it is still
    /// reading, a wake entry) and are left to it, or to the scratch sweep. A
    /// finished reply (`ready` present) is kept for the shim still waiting on
    /// it; the stale-reply sweep removes it if nobody collects it.
    private func discardStaleExchangeFiles() {
        for endpoint in endpointDirectories() {
            for name in ["inbox", "processing", "outbox"] {
                let directory = endpoint.appendingPathComponent(name, isDirectory: true)
                let entries = (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )) ?? []
                for entry in entries {
                    if name == "inbox", entry.lastPathComponent.hasPrefix(".") { continue }
                    if name == "outbox", fileManager.fileExists(atPath: entry.appendingPathComponent("ready").path) { continue }
                    try? fileManager.removeItem(at: entry)
                }
            }
        }
    }

    /// Every start or restart rotates a pane's capability and prepares a new
    /// endpoint, and every stop or close forgets it; the endpoint a retired
    /// capability named is removed here, once a second. The folders are
    /// listed before the capabilities are read: an endpoint is prepared only
    /// after its capability is stored, so one listed here is either among the
    /// capabilities read afterwards or was retired in between. Capabilities
    /// that cannot be read remove nothing.
    private func pruneRetiredEndpoints() {
        let listed = endpointDirectories(limit: nil)
        guard !listed.isEmpty, let tokens = try? Set(credentials.allTokens()) else { return }
        for endpoint in listed where !tokens.contains(endpoint.lastPathComponent) {
            try? fileManager.removeItem(at: endpoint)
        }
    }

    /// Each endpoint on its own: a pane that broke its own heartbeat (a
    /// container can put a directory in its place) must not stop the others'.
    private func writeHeartbeats() {
        for endpoint in endpointDirectories() {
            try? writeProtected(instance, to: heartbeat(in: endpoint))
        }
        lastHeartbeat = clocks.monotonic()
    }

    private func endpointDirectories(limit: Int? = 256) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runtimeDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { Self.isPaneCapability($0.lastPathComponent) }
            .filter { (try? validateDirectory($0)) != nil }
            .prefix(limit ?? .max)
            .map { $0 }
    }

    private func heartbeat(in endpoint: URL) -> URL {
        endpoint.appendingPathComponent("heartbeat", isDirectory: false)
    }

    private func writeProtected(_ value: String, to file: URL) throws {
        try writeProtected(Data(value.utf8), to: file)
    }

    private func writeProtected(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic])
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
    /// For `context-draft`, `context-add` and `done-file`: the body's bytes
    /// when they are an image, which then never reach `body` as text.
    var image: Data? = nil
    /// Released when the last copy of the request is dropped.
    var stagingSlot: StagingSlot? = nil
    let attestation: RelayAttestation
    let ticketPolicy: RelayTicketPolicy?
}

/// One of the transport's staging slots, given back when the request that
/// holds it is dropped, however the request ends.
private final class StagingSlot: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    init(_ semaphore: DispatchSemaphore) { self.semaphore = semaphore }
    deinit { semaphore.signal() }
}

private struct FileResponse {
    let status: Int
    let body: String
    /// A body of bytes (a fetched image), written in place of `body`.
    var data: Data? = nil
}
