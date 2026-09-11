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
///
/// `RelayHandoff` itself now lives here too. Its whole data closure is
/// platform-free, so a record can be read, rendered or exported without the
/// broker that produced it.

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

public struct RelayHandoff: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let idempotencyKey: String
    public let kind: RelayHandoffKind
    public let sourcePaneID: String
    public let sourceName: String
    public let sourceLaunchGeneration: Int?
    public let sourceKind: PaneKind?
    public let sourceWorkspaceID: String
    public let sourceWorkspaceName: String?
    public let targetPaneID: String
    public let targetName: String
    public let targetKind: PaneKind?
    public let targetWorkspaceID: String
    public let targetWorkspaceName: String?
    public let text: String
    public let submitted: Bool
    public var inReplyToHandoffID: String? = nil
    public var relationship: RelayHandoffRelationship? = nil
    public var humanVerdict: RelayHandoffVerdict? = nil
    public var humanReviewNote: String? = nil
    public var reviewedAt: Date? = nil
    public var reviewRevision: Int? = nil
    public var progressNote: String? = nil
    public var progressUpdatedAt: Date? = nil
    /// Bounded, informational Git facts about the target pane's working
    /// folder: paths only, never content, and never attribution, because
    /// other panes and the person edit the same tree.
    public var gitFactsAtDelegation: DelegationGitSnapshot? = nil
    public var gitFactsAtReturn: DelegationGitSnapshot? = nil
    public var resultText: String?
    public var commandRun: ReviewedCommandRun? = nil
    public var resultContextReviewID: String? = nil
    public var readAt: Date? = nil
    public var state: RelayHandoffState
    public var updatedAt: Date
    public var transitions: [RelayHandoffTransition]
    public var retryDisposition: RelayRetryDisposition? = nil
    public var attention: RelayAttention? = nil

    public var canRetrySafely: Bool {
        state == .failed
            && retryDisposition == .safe
            && (kind == .relay || kind == .paste)
    }

    public var hasReturnedResult: Bool {
        (kind == .ask || kind == .delegate || kind == .commandRun)
            && !(resultText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public var hasUnreadResult: Bool {
        hasReturnedResult && readAt == nil
    }
}
