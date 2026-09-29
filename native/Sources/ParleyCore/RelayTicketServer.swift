import Darwin
import Dispatch
import Foundation

/// How one request through the agent transport was authenticated.
public enum RelayAttestation: String, Codable, Equatable, Sendable {
    /// The request carried a one-use ticket that the ticket socket issued to a
    /// process whose kernel ancestry reaches this application's launch root,
    /// where the pane identity and generation were injected at launch.
    case peerVerified = "peer-verified"
    /// The pane capability alone, as before tickets existed.
    case tokenOnly = "token-only"
}

/// Whether a pane's requests must carry a ticket. Derived from facts about
/// the pane and the socket, never from terminal text, and disclosed in the
/// launch review and in `whoami`.
public struct RelayTicketPolicy: Equatable, Sendable {
    public enum Requirement: String, Codable, Equatable, Sendable {
        /// A request without a valid ticket is refused.
        case required
        /// A ticket is redeemed when one arrives and not demanded.
        case optional
        /// No ticket can reach the pane, so requests stay token-only.
        case unavailable
    }

    public let requirement: Requirement
    public let reason: String

    public init(_ requirement: Requirement, _ reason: String) {
        self.requirement = requirement
        self.reason = reason
    }

    /// What each vendor's pane was observed to do on 14 September 2026, not
    /// what its documentation suggests. Claude Code and Copilot run their shell
    /// commands on the host without a sandbox, and Agy, launched with its own
    /// `--sandbox`, still reached the socket from a real pane, so all three
    /// must present a ticket. Codex's sandbox, run with Parley's own
    /// permissions table under `codex sandbox`, denies Unix sockets while the
    /// table keeps network off and admits them once `network={enabled=true}`
    /// is in it, which Parley writes exactly when the profile allows network;
    /// so a Codex pane on such a profile must present a ticket, and one
    /// without network is asked for one, since only an approved escalation
    /// could reach the socket. A container never has the socket mounted.
    /// `claudeSandbox` is Claude's own sandbox setting captured for this launch
    /// by `ClaudeHostConfiguration`; a person who switched it on in their
    /// settings has put a sandbox around Claude's shell commands that denies
    /// Unix sockets unless its `allowUnixSockets` admits one, which Parley has
    /// not checked, so a ticket becomes welcome rather than demanded.
    public static func policy(kind: PaneKind, inContainer: Bool, socketListening: Bool, claudeSandbox: ClaudeSandboxFact? = nil,
                              codexNetworkAllowed: Bool? = nil) -> RelayTicketPolicy {
        guard socketListening else {
            return RelayTicketPolicy(.unavailable, "the ticket socket is not listening")
        }
        if inContainer {
            return RelayTicketPolicy(.unavailable, "the ticket socket is not mounted in a container")
        }
        switch kind {
        case .codex where codexNetworkAllowed == true:
            return RelayTicketPolicy(.required, "Codex's sandbox admits Unix sockets because this profile enables network, checked with codex sandbox and Parley's own table")
        case .codex where codexNetworkAllowed == false:
            return RelayTicketPolicy(.optional, "Codex's sandbox denies Unix sockets while this profile keeps network off; a ticket arrives only through an approved escalation")
        case .codex:
            return RelayTicketPolicy(.optional, "Codex's profile is not known, so whether its sandbox admits the ticket socket is not known; a ticket is welcome")
        case .agy:
            return RelayTicketPolicy(.required, "Agy's own sandbox admitted the ticket socket from a real pane on 14 September 2026")
        case .claude where claudeSandbox?.enabled == true:
            return RelayTicketPolicy(.optional, "Claude's own sandbox is on and whether its allowUnixSockets admits the ticket socket is unchecked; set in \(claudeSandbox?.source ?? "your settings")")
        case .claude, .copilot:
            return RelayTicketPolicy(.required, "\(kind.label) runs its shell commands on this Mac without a sandbox")
        case .shell:
            return RelayTicketPolicy(.unavailable, "shell panes hold no capability")
        }
    }

    /// `networkAllowed` answers for the pane's exact launch generation; the
    /// broker supplies its launch snapshot, and nil means unknown.
    public static func policy(for pane: WorkbenchPane, socketListening: Bool, networkAllowed: Bool? = nil,
                              claudeSandbox: ClaudeSandboxFact? = nil) -> RelayTicketPolicy {
        return policy(kind: pane.kind, inContainer: pane.containerConfiguration != nil, socketListening: socketListening,
            claudeSandbox: claudeSandbox, codexNetworkAllowed: pane.kind == .codex ? networkAllowed : nil)
    }
}

/// One-use tickets over a peer-verified Unix socket.
///
/// The agent transport is files, because a vendor's sandbox may deny every
/// socket, so a capability file is all the transport can ask for; and any
/// process running as the person can read that file. This socket adds what
/// files cannot: the kernel names the connecting process, and the process
/// must be a descendant of the pane the capability belongs to, found by the
/// `PARLEY_PANE_ID` marker Parley put into that pane's launch environment.
/// A ticket lives ten seconds, redeems once, and is bound to the capability
/// it was issued for. Nothing here reads terminal text.
public final class RelayTicketServer: @unchecked Sendable {
    public static let ticketLifetime: TimeInterval = 10
    public static let socketName = "tickets.sock"
    public static let maximumAncestryHops = 32
    public static let maximumRequestBytes = 256
    /// `sun_path` on macOS holds 104 bytes including the terminator.
    public static let maximumSocketPathBytes = 103

    /// The launch generation travels beside the pane id in the launch
    /// environment; a process of an earlier generation of the same pane is
    /// not a process of the pane.
    public static let generationMarkerKey = "PARLEY_PANE_GENERATION"

    /// One environment value (by key) of one process.
    public typealias MarkerValue = @Sendable (String, Int32) -> String?
    public typealias ParentPID = @Sendable (Int32) -> Int32?
    public typealias LaunchIntermediate = @Sendable (Int32) -> Bool
    /// The pane's current launch generation, or nil when the pane is unknown.
    public typealias PaneGeneration = @Sendable (String) -> Int?

    public let socketFile: URL
    private let credentials: RelayCredentials
    private let applicationPID: Int32
    private let markerValue: MarkerValue
    private let parentPID: ParentPID
    private let isLaunchIntermediate: LaunchIntermediate
    private let paneGeneration: PaneGeneration
    /// A ticket ages on awake time (`clocks.awake`, which stops while the
    /// Mac sleeps): a shim that got its ticket just before a sleep has its
    /// full lifetime after the wake, and a clock change never expires one.
    private let clocks: RelayTransportClocks
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "parley.native.ticket-socket", qos: .utility)
    private let connections = DispatchQueue(label: "parley.native.ticket-connections", qos: .utility, attributes: .concurrent)
    private var tickets: [String: (token: String, requestID: String, expiresAwake: UInt64)] = [:]
    private var issued = 0
    private var refused = 0
    private var listening = false
    /// Why `start` did not leave the socket listening, when it did not.
    public private(set) var startFailure: String?

    /// Beside the endpoints when that fits a Unix socket path; otherwise in
    /// the user's temporary directory under a name derived from the transport
    /// directory, so the server and every shim it installs agree on it.
    public static func socketURL(transportDirectory: URL) -> URL {
        let beside = transportDirectory.appendingPathComponent(socketName, isDirectory: false)
        if beside.path.utf8.count <= maximumSocketPathBytes { return beside }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in transportDirectory.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("parley-tickets-\(String(hash, radix: 16)).sock", isDirectory: false)
    }

    public init(
        socketFile: URL,
        credentials: RelayCredentials,
        applicationPID: Int32 = getpid(),
        paneGeneration: @escaping PaneGeneration,
        markerValue: @escaping MarkerValue = { key, pid in ProcessEnvironmentMarker.value(key, forProcess: pid) },
        parentPID: @escaping ParentPID = { pid in ProcessKernelFacts.parentPID(ofProcess: pid) },
        isLaunchIntermediate: @escaping LaunchIntermediate = ProcessKernelFacts.isPrivilegedLogin,
        clocks: RelayTransportClocks = .system
    ) {
        self.socketFile = socketFile
        self.credentials = credentials
        self.applicationPID = applicationPID
        self.paneGeneration = paneGeneration
        self.markerValue = markerValue
        self.parentPID = parentPID
        self.isLaunchIntermediate = isLaunchIntermediate
        self.clocks = clocks
    }

    public var isListening: Bool { lock.withLock { listening } }
    public var issuedCount: Int { lock.withLock { issued } }
    public var refusedCount: Int { lock.withLock { refused } }

    /// Binds, listens and accepts in the background. A failure is kept in
    /// `startFailure` and thrown; the caller decides whether the transport
    /// runs token-only without it.
    public func start() throws {
        try lock.withLock {
            guard !listening else { return }
            let path = socketFile.path
            guard path.utf8.count <= Self.maximumSocketPathBytes else {
                let failure = "ticket socket path is longer than a Unix socket allows (\(path.utf8.count) bytes)"
                startFailure = failure
                throw RelayFileTransportError.runtime(failure)
            }
            unlink(path)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                let failure = "ticket socket could not be created: \(String(cString: strerror(errno)))"
                startFailure = failure
                throw RelayFileTransportError.runtime(failure)
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                let bytes = Array(path.utf8)
                for index in 0..<min(bytes.count, capacity - 1) { destination[index] = bytes[index] }
                destination[min(bytes.count, capacity - 1)] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = LocalSocketCreation.withOwnerOnlyPermissions {
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
                let failure = "ticket socket could not listen: \(String(cString: strerror(errno)))"
                close(descriptor)
                unlink(path)
                startFailure = failure
                throw RelayFileTransportError.runtime(failure)
            }
            listener = descriptor
            listening = true
            startFailure = nil
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.resume()
            acceptSource = source
        }
    }

    public func stop() {
        lock.withLock {
            guard listening else { return }
            listening = false
            acceptSource?.cancel()
            acceptSource = nil
            close(listener)
            listener = -1
            unlink(socketFile.path)
            tickets.removeAll()
        }
    }

    /// Consumes one ticket. True only for an unexpired, unused ticket issued
    /// for exactly this capability and transport request directory.
    public func redeem(_ ticket: String, token: String, requestID: String) -> Bool {
        lock.withLock {
            purgeExpiredLocked()
            guard let entry = tickets[ticket], entry.token == token, entry.requestID == requestID else { return false }
            tickets[ticket] = nil
            return true
        }
    }

    /// First prove kernel ancestry to Parley. Only the direct launch root's
    /// markers count, optionally below Ghostty's root-owned login process.
    /// Descendants cannot impersonate another pane by replacing their own
    /// environment. If the launch root cannot be read, refuse rather than
    /// falling back to a child's assertion. Host vendor applications remain
    /// trusted; this does not isolate an unrestricted same-user process.
    public func attest(peerPID: Int32, paneID: String, generation: Int) -> Bool {
        var pid = peerPID
        var child: Int32?
        var visited: Set<Int32> = []
        for _ in 0..<Self.maximumAncestryHops {
            guard pid > 1, pid != applicationPID, visited.insert(pid).inserted,
                  let parent = parentPID(pid), parent > 1, parent != pid else { return false }
            if parent == applicationPID {
                let root: Int32
                if isLaunchIntermediate(pid) {
                    guard let child else { return false }
                    root = child
                } else {
                    root = pid
                }
                return markerValue(PaneProcessAnchorProjection.markerKey, root) == paneID
                    && markerValue(Self.generationMarkerKey, root) == String(generation)
            }
            child = pid
            pid = parent
        }
        return false
    }

    private func acceptPending() {
        let listener = lock.withLock { self.listener }
        guard listener >= 0 else { return }
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return }
        connections.async { [weak self] in
            self?.serve(connection)
            close(connection)
        }
    }

    private func serve(_ connection: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let reply: String
        if let refusal = refusal(for: connection) {
            lock.withLock { refused += 1 }
            reply = "refused: \(refusal)\n"
        } else {
            reply = issue(for: connection) + "\n"
        }
        reply.withCString { pointer in
            _ = Darwin.send(connection, pointer, strlen(pointer), 0)
        }
    }

    /// Reads the capability and request UUID, then checks the peer. Returns
    /// nil when a ticket may be issued; both fields are left in `presented`.
    private var presented: [Int32: (token: String, requestID: String)] = [:]

    private func refusal(for connection: Int32) -> String? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else { return "peer is not this user" }
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer > 1 else { return "peer process unknown" }
        let capacity = Self.maximumRequestBytes
        var buffer = [UInt8](repeating: 0, count: capacity)
        var received = 0
        while received < capacity {
            let offset = received
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(connection, bytes.baseAddress!.advanced(by: offset), capacity - offset, 0)
            }
            guard count > 0 else { break }
            received += count
            if buffer[..<received].contains(10) { break }
        }
        guard let newline = buffer[..<received].firstIndex(of: 10),
              let line = String(bytes: buffer[..<newline], encoding: .utf8) else { return "no capability presented" }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[0].isEmpty, UUID(uuidString: String(fields[1])) != nil else {
            return "a capability and transport request UUID are required"
        }
        let token = String(fields[0]), requestID = String(fields[1])
        guard let paneID = credentials.paneID(for: token) else { return "unknown capability" }
        guard let generation = paneGeneration(paneID) else { return "pane unknown" }
        guard attest(peerPID: peer, paneID: paneID, generation: generation) else { return "not a process of that pane's current launch" }
        lock.withLock { presented[connection] = (token, requestID) }
        return nil
    }

    private func issue(for connection: Int32) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        arc4random_buf(&bytes, bytes.count)
        let ticket = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            purgeExpiredLocked()
            guard let request = presented.removeValue(forKey: connection) else { return }
            tickets[ticket] = (token: request.token, requestID: request.requestID,
                               expiresAwake: clocks.awake() + UInt64(Self.ticketLifetime * 1_000_000_000))
            issued += 1
        }
        return ticket
    }

    private func purgeExpiredLocked() {
        let now = clocks.awake()
        tickets = tickets.filter { $0.value.expiresAwake > now }
    }
}
