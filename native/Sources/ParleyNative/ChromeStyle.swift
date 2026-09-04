import ParleyCore
import SwiftUI

/// The one semantic palette for native chrome. Colour states a fact about
/// coordination or process health; it never identifies a vendor.
///
/// - accent: the selected pane, a handoff in flight, a routing role
/// - orange: a person's attention is needed (permission, stale protocol,
///   relay off, shared writers, disconnected core)
/// - red: failure (failed or interrupted handoff, non-zero exit, terminal gone)
/// - green: connection health only (the core dot)
/// - secondary: everything neutral (completed, stopped, identity, metadata)
enum ChromeColor {
    static let identityBar = Color.secondary.opacity(0.45)

    static func tone(_ tone: WorkbenchNoticeTone) -> Color {
        switch tone {
        case .attention: .orange
        case .failure: .red
        case .inFlight: .accentColor
        case .neutral: .secondary
        }
    }

    static func handoff(_ handoff: RelayHandoff) -> Color {
        if handoff.attention != nil { return .orange }
        return switch handoff.state {
        case .created, .delivered, .waiting, .answered: .accentColor
        case .failed, .interrupted: .red
        case .completed, .cancelled: .secondary
        }
    }

    static func connection(_ state: WorkbenchConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .coreDisconnected: .orange
        case .terminalDisconnected: .red
        }
    }

    static func paneProcess(_ pane: WorkbenchPane) -> Color {
        switch WorkbenchStateProjection.pane(pane) {
        case .empty, .running, .stopped: .secondary
        case .exited: .red
        case .protocolStale, .relayUnavailable: .orange
        }
    }

    static func attention(_ reason: PaneAttentionReason) -> Color {
        switch reason {
        case .permissionRequest: .orange
        case .returnedResult: .accentColor
        case .interruptedHandoff: .red
        }
    }

    static func verdict(_ verdict: RelayHandoffVerdict) -> Color {
        switch verdict {
        case .accepted: .primary
        case .needsChanges: .orange
        case .rejected: .red
        case .inconclusive: .secondary
        }
    }
}

/// The type ramp for chrome. Nothing renders below 9 pt; uppercase is used
/// only through `heading`. Terminal text is governed by Ghostty, not here.
enum ChromeFont {
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 11)
    static let bodyMedium = Font.system(size: 11, weight: .medium)
    static let bodySemibold = Font.system(size: 11, weight: .semibold)
    static let secondary = Font.system(size: 10)
    static let secondaryMedium = Font.system(size: 10, weight: .medium)
    /// Factual numbers and times: tabular digits, monospaced.
    static let meta = Font.system(size: 9, design: .monospaced).monospacedDigit()
    static let chip = Font.system(size: 9, weight: .semibold, design: .monospaced)
    static let heading = Font.system(size: 9, weight: .semibold, design: .monospaced)
    static let mono = Font.system(size: 10, design: .monospaced)
}

/// Vendor identity without colour: a two-letter monogram beside the name.
enum ChromeIdentity {
    static func monogram(_ kind: PaneKind) -> String {
        switch kind {
        case .claude: "CL"
        case .codex: "CX"
        case .agy: "AG"
        case .copilot: "CP"
        case .shell: "SH"
        }
    }
}

/// An inline state chip in sentence case, tinted with one semantic colour.
struct ChromeChip: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(ChromeLabel.chipCase(text))
            .font(ChromeFont.chip)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// A short uppercase heading for a section; the only place uppercase is used.
struct ChromeHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(ChromeFont.heading)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A small identity mark: monogram in a hairline box, no vendor colour.
struct ChromeMonogram: View {
    let kind: PaneKind
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
            Text(ChromeIdentity.monogram(kind))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
