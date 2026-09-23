import Foundation

/// Relay requests run on threads of their own, never on the shared dispatch
/// pool. Some of them block for minutes (Ask, wait, a command run, a team
/// decision), and the pool has a fixed number of threads per process (70 on
/// the Mac the 22 September 2026 review ran on): once enough blocked work
/// holds them, no other queued work runs, including the request that would
/// release the blocked ones, the ticket socket and the UI's control socket.
/// A dedicated thread is not drawn from that pool.
public enum RelayWorkerThread {
    public static func start(name: String, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.name = name
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// How many agent requests that can block for a long time may run at once.
/// Past the limit a new one is refused at once rather than queued, so an
/// agent sees a clear error instead of a hang, and short requests such as
/// done, answer and relay are never counted.
public final class BlockingRequestGate: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var active = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public func enter() -> Bool {
        lock.withLock {
            guard active < limit else { return false }
            active += 1
            return true
        }
    }

    public func leave() { lock.withLock { active = max(0, active - 1) } }

    public var activeCount: Int { lock.withLock { active } }
}
