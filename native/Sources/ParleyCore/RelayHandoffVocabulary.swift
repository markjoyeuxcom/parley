import Foundation

/// The vocabulary a handoff is described in.
///
/// These are the words the rest of Parley reasons with: what kind of handoff
/// it is, what state it reached, why it wants attention, where a transition
/// came from. They were declared beside the broker that produces them, in a
/// file that needs Darwin, which meant nothing could depend on the vocabulary
/// without depending on the implementation.
///
/// Nothing here knows how a handoff is delivered, stored or authenticated.
/// This file carries no platform import and must keep it that way.

public enum RelayHandoffKind: String, Codable, Equatable, Sendable {
    case relay
    case paste
    case ask
    case delegate
    case commandRun

    public var label: String {
        switch self {
        case .relay: "Relay"
        case .paste: "Paste"
        case .ask: "Ask"
        case .delegate: "Delegate"
        case .commandRun: "Command run"
        }
    }
}

public enum RelayHandoffRelationship: String, CaseIterable, Codable, Equatable, Sendable {
    case challenge
    case verify
    case requestChanges

    public var label: String {
        switch self {
        case .challenge: "Challenge"
        case .verify: "Verify"
        case .requestChanges: "Request Changes"
        }
    }
}

public enum RelayHandoffVerdict: String, CaseIterable, Codable, Equatable, Sendable {
    case accepted
    case needsChanges
    case rejected
    case inconclusive

    public var label: String {
        switch self {
        case .accepted: "Accepted"
        case .needsChanges: "Needs Changes"
        case .rejected: "Rejected"
        case .inconclusive: "Inconclusive"
        }
    }
}

public enum RelayHandoffState: String, Codable, Equatable, Sendable {
    case created
    case delivered
    case waiting
    case answered
    case completed
    case cancelled
    case failed
    case interrupted
}

public enum RelayRetryDisposition: String, Codable, Equatable, Sendable {
    /// Parley knows the writer failed before terminal input began.
    case safe
    /// Terminal input may have started, so retrying could duplicate text.
    case uncertain
    /// The operation cannot be meaningfully resumed from the activity UI.
    case unsupported
}

public enum RelayAttention: String, Codable, Equatable, Sendable {
    case targetNotReady
    case permissionRequired
    case targetUnavailable
}

public enum RelayTransitionOrigin: String, Codable, Equatable, Sendable {
    case human
    case automation
}

public enum RelayActivityEventKind: String, Codable, Equatable, Sendable {
    case paneRestarted
    case paneResumeRequested
    case paneReaped
    case workspaceCreated
    case workspaceClosed
    case workspaceRestored
    case recipeSubmitted
    case recipeInterrupted
    case comparisonForwarded
    case vendorSessionStarted
    case vendorTurnStarted
    case vendorTurnEnded
    case vendorAwaitingPermission
    case vendorNotification
    case vendorSessionEnded
    case teamSessionRequested
    case teamSessionApproved
    case teamPaneCreated
    case teamSessionEnded
    case teamPaneStopAttempted
}

public struct RelayHandoffTransition: Codable, Equatable, Sendable {
    public let state: RelayHandoffState
    public let occurredAt: Date
    public let detail: String?
    public let origin: RelayTransitionOrigin?

    public init(
        state: RelayHandoffState,
        occurredAt: Date,
        detail: String?,
        origin: RelayTransitionOrigin? = nil
    ) {
        self.state = state
        self.occurredAt = occurredAt
        self.detail = detail
        self.origin = origin
    }
}