import Foundation

/// A colour role in the native chrome palette. Kept separate from SwiftUI so
/// the border decision can be checked without rendering anything.
public enum ChromeTone: String, Equatable, Sendable {
    case accent
    case orange
    case red
    case green
    case separator
}

/// How a pane's border is drawn.
///
/// Selection and attention previously shared one visual channel: a returned
/// result drew an accent ring, and so did selection, so a selected pane with a
/// result was indistinguishable from a selected pane without one. Each meaning
/// now owns a channel. The outer ring is always selection and nothing else;
/// attention is always a separate inner ring in its own colour. A reader can
/// tell which is which from position alone, before colour is considered.
public struct PaneChromeRings: Equatable, Sendable {
    public let outer: ChromeTone
    public let outerWidth: Double
    public let inner: ChromeTone?
    public let innerWidth: Double

    public init(outer: ChromeTone, outerWidth: Double, inner: ChromeTone?, innerWidth: Double) {
        self.outer = outer
        self.outerWidth = outerWidth
        self.inner = inner
        self.innerWidth = innerWidth
    }

    public static func forPane(selected: Bool, attention: PaneAttentionReason?) -> PaneChromeRings {
        PaneChromeRings(
            outer: selected ? .accent : .separator,
            outerWidth: selected ? 2 : 1,
            inner: attention.map(tone(for:)),
            innerWidth: 2)
    }

    /// `returnedResult` must never be `.accent`: that is the selection colour,
    /// and reusing it is exactly what made the two states look identical.
    public static func tone(for reason: PaneAttentionReason) -> ChromeTone {
        switch reason {
        case .permissionRequest: .orange
        case .returnedResult: .green
        case .interruptedHandoff: .red
        }
    }
}
