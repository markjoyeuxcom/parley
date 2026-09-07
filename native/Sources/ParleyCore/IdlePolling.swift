import Dispatch
import Foundation

/// Whether the app's one-second relay tick needs to fetch from its own broker.
/// The broker lives in the same process and advances `stateRevision()` on
/// every mutation the tick reads, so an unchanged revision means the five
/// socket round trips (server encode, transport, client decode) would return
/// what the app already holds. A forced fetch every `forcedFetchEveryTicks`
/// bounds the effect of any mutation path that forgets to advance it.
public enum RelayPollPolicy {
    public static let forcedFetchEveryTicks = 15

    public static func shouldFetch(revision: UInt64, lastApplied: UInt64?, ticksSinceFetch: Int) -> Bool {
        guard let lastApplied else { return true }
        if revision != lastApplied { return true }
        return ticksSinceFetch >= forcedFetchEveryTicks
    }
}

/// The agent file transport's poll cadence. Requests arrive through the
/// filesystem, so a directory event wakes the transport at once; the timer is
/// the fallback. While requests are flowing it polls every 50 ms; after a
/// quiet streak it backs off to 250 ms so an idle app does not scan every
/// pane's inbox twenty times a second.
public struct TransportPollSchedule: Equatable, Sendable {
    public static let activeInterval: DispatchTimeInterval = .milliseconds(50)
    public static let idleInterval: DispatchTimeInterval = .milliseconds(250)
    public static let quietTicksBeforeBackoff = 10

    public private(set) var interval: DispatchTimeInterval = TransportPollSchedule.activeInterval
    private var quietTicks = 0

    public init() {}

    /// Called after each tick with whether it found or processed anything.
    public mutating func observe(activity: Bool) {
        if activity {
            quietTicks = 0
            interval = Self.activeInterval
            return
        }
        quietTicks = min(quietTicks + 1, Self.quietTicksBeforeBackoff)
        if quietTicks >= Self.quietTicksBeforeBackoff { interval = Self.idleInterval }
    }

    /// A directory event: something was written to an inbox.
    public mutating func wake() {
        quietTicks = 0
        interval = Self.activeInterval
    }
}
