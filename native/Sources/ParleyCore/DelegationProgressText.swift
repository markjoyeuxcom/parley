import Foundation

/// A progress note is a compact, agent-declared status string, not terminal
/// output and not a lifecycle transition. Keep it single-line and byte-bounded
/// so it remains safe to project into status and the existing inspector.
public enum DelegationProgressText {
    public static let maximumBytes = 200

    public static func normalize(_ input: String) -> String {
        RelayText.clean(input)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
