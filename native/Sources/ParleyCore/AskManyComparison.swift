import Foundation

public struct RelayUIAskRequest: Codable, Equatable, Sendable {
    public let sourcePaneID: String
    public let targetPaneID: String
    public let text: String
    public let idempotencyKey: String
    public let preserveFormatting: Bool?
    public let origin: RelayTransitionOrigin?

    public init(
        sourcePaneID: String,
        targetPaneID: String,
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false,
        origin: RelayTransitionOrigin = .human
    ) {
        self.sourcePaneID = sourcePaneID
        self.targetPaneID = targetPaneID
        self.text = text
        self.idempotencyKey = idempotencyKey
        self.preserveFormatting = preserveFormatting
        self.origin = origin
    }
}

public struct RelayUIAskManyRequest: Codable, Equatable, Sendable {
    public let sourcePaneID: String
    public let targetPaneIDs: [String]
    public let text: String
    public let idempotencyKey: String
    public let preserveFormatting: Bool?

    public init(
        sourcePaneID: String,
        targetPaneIDs: [String],
        text: String,
        idempotencyKey: String,
        preserveFormatting: Bool = false
    ) {
        self.sourcePaneID = sourcePaneID
        self.targetPaneIDs = targetPaneIDs
        self.text = text
        self.idempotencyKey = idempotencyKey
        self.preserveFormatting = preserveFormatting
    }
}

public struct RelayAskManyUIResponse: Equatable, Sendable {
    public let status: Int
    public let bundle: RelayAskManyBundle

    public init(status: Int, bundle: RelayAskManyBundle) {
        self.status = status
        self.bundle = bundle
    }
}

public enum AskManyComparisonDraftError: LocalizedError, Equatable {
    case noSuccessfulAnswers

    public var errorDescription: String? {
        switch self {
        case .noSuccessfulAnswers:
            "Choose at least one returned answer to forward. Failed results remain visible in the comparison but are not answers."
        }
    }
}

/// Produces only attributed source material for a person-controlled forward.
/// It deliberately has no summarisation or verdict operation: independent
/// answers stay independent until a person edits a synthesis explicitly.
public enum AskManyComparisonDraft {
    public static func forwardingText(
        question: String,
        answers: [RelayAskManyAnswer],
        selectedTargetPaneIDs: Set<String>
    ) throws -> String {
        let selected = answers.filter {
            selectedTargetPaneIDs.contains($0.targetPaneID)
                && (200..<300).contains($0.status)
                && $0.answer != nil
        }
        guard !selected.isEmpty else { throw AskManyComparisonDraftError.noSuccessfulAnswers }

        let attributed = selected.map { answer in
            "\(answer.targetName) answered independently:\n\n\(answer.answer ?? "")"
        }.joined(separator: "\n\n---\n\n")
        return "Independent answers to:\n\n\(RelayText.clean(question))\n\n---\n\n\(attributed)"
    }

    public static func synthesisText(
        question: String,
        answers: [RelayAskManyAnswer]
    ) throws -> String {
        let successful = Set(answers.compactMap { answer in
            (200..<300).contains(answer.status) && answer.answer != nil
                ? answer.targetPaneID
                : nil
        })
        let source = try forwardingText(
            question: question,
            answers: answers,
            selectedTargetPaneIDs: successful
        )
        return "\(source)\n\n---\n\nWrite an edited synthesis below. The attributed answers above remain unchanged.\n\nSynthesis:\n"
    }
}
