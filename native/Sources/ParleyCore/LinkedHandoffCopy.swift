import Foundation

/// Person-facing messages for opening a linked child from a returned result.
/// Challenge and Verify open a linked review Ask to a reviewer pane; Request
/// Changes opens a linked Delegate to the pane that should revise the result.
/// The wording never calls that pane a reviewer or the child a review.
public enum LinkedHandoffCopy {
    public static func notRelayReady(_ relationship: RelayHandoffRelationship) -> String {
        switch relationship {
        case .requestChanges:
            "The selected result no longer has a relay-ready source and explicit target pane for the linked Delegate. Nothing was sent."
        case .challenge, .verify:
            "The selected result no longer has a relay-ready source and explicit reviewer pane. Nothing was sent."
        }
    }

    public static func targetBusy(_ relationship: RelayHandoffRelationship, targetName: String) -> String {
        switch relationship {
        case .requestChanges:
            "\(targetName) already has tracked work. Finish or cancel it before sending this linked Delegate; a request for changes is never queued."
        case .challenge, .verify:
            "\(targetName) already has tracked work. Finish or cancel it before starting this linked review."
        }
    }

    public static func resultTooLarge(_ relationship: RelayHandoffRelationship) -> String {
        switch relationship {
        case .requestChanges:
            "This result is too large for one linked Delegate. Add the selected result to a Context Pack and refer to it from a shorter request for changes instead."
        case .challenge, .verify:
            "This result is too large for one linked Ask. Add the selected result to a Context Pack and review its visible sources instead."
        }
    }
}
