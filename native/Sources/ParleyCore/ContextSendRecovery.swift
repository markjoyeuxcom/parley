import Foundation

/// What becomes of a person's edits to an agent-staged context draft when
/// sending it (approving an agent's waiting Ask, or sending a draft as the
/// person's own Ask) did not come back as a success. Decided from the review
/// read fresh from the core afterwards, the way `ReviewedAskHistory` decides
/// for a person's own Ask.
public enum ContextSendRecovery: Equatable, Sendable {
    /// Nothing was delivered and the draft is as the person sent it (the core
    /// never received the request, or handed it back holding their edits):
    /// the edits reopen at this review's revision, state and target.
    case reopen(AgentContextReview)
    /// Nothing was delivered, but the draft changed under the person: the
    /// agent added a part or turned it into an Ask, which is the core's
    /// stale-revision refusal. Reopening the old copy at the new revision
    /// would drop the agent's addition or approve a request the person never
    /// saw, so the draft is shown as it is now and the edits are offered to
    /// copy.
    case changed(AgentContextReview)
    /// The context was delivered, and the send reported a failure afterwards
    /// (no answer in time, or the target closed). Nothing to reopen.
    case delivered
    /// Delivery may have started, or the state is unknown: the edits are
    /// offered to copy, never reopened for a second send.
    case copyOnly(reason: String)

    public static func decide(reviewID: String, sent: ContextPack, sentRevision: Date,
                              fresh: [AgentContextReview]?) -> ContextSendRecovery {
        guard let fresh else {
            return .copyOnly(reason: "Parley could not read the draft's state, so whether it was delivered is unknown.")
        }
        guard let review = fresh.first(where: { $0.id == reviewID }) else {
            return .copyOnly(reason: "The draft is no longer listed, so whether it was delivered is unknown.")
        }
        switch review.state {
        case .draft, .awaitingReview:
            let unchanged = review.updatedAt == sentRevision
                || (review.pack.note == sent.note
                    && review.pack.parts.map(\.id) == sent.parts.map(\.id)
                    && review.pack.parts.map(\.text) == sent.parts.map(\.text))
            return unchanged ? .reopen(review) : .changed(review)
        case .completed:
            return .delivered
        case .approved:
            return .copyOnly(reason: "The draft was approved and delivery may still be under way.")
        case .failed, .interrupted, .rejected, .discarded:
            return .copyOnly(reason: "The draft is now \(review.state.rawValue): \(review.detail ?? "no detail was recorded"). If delivery had started, part of the pack could already be in the target's input line.")
        }
    }
}
