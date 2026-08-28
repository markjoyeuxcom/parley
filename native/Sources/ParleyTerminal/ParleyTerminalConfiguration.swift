import AppKit
import SwiftTerm

/// The production terminal configuration shared by the app and its soak gate.
/// Keeping one implementation prevents a green harness from quietly exercising
/// a renderer mode different from the one people actually use.
public enum ParleyTerminalConfiguration {
    @MainActor
    public static func apply(to terminal: LocalProcessTerminalView) {
        applyAppearance(to: terminal)
    }

    /// Shared by the pty-attached host and the headless control-mode host.
    @MainActor
    public static func applyAppearance(to terminal: TerminalView) {
        terminal.autoresizingMask = [.width, .height]
        terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeForegroundColor = NSColor(white: 0.88, alpha: 1)
        terminal.nativeBackgroundColor = NSColor(white: 0.085, alpha: 1)
        terminal.selectedTextBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.55)
        terminal.caretColor = .systemBlue
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        // Agent TUIs repaint most rows. SwiftTerm's persistent-row mode is for
        // sparse updates; one aggregated buffer per frame is the bounded shape
        // for this workload. The dependency is pinned to the release that
        // fixed unbounded Metal BufferPool growth under changing content.
        terminal.metalBufferingMode = .perFrameAggregated
    }

    @MainActor
    public static func enablePreferredRenderer(on terminal: LocalProcessTerminalView) throws {
        try terminal.setUseMetal(true)
    }
}

/// SwiftTerm maps AppKit responder changes to DEC focus reports. Independent
/// preview leaves remain visibly attached while keyboard focus moves between
/// siblings, so they may opt out of terminal focus-out without changing the
/// server-wide tmux focus-events setting.
@MainActor
open class ParleyLocalProcessTerminalView: LocalProcessTerminalView {
    public var preservesTerminalFocusOnResign = false

    public override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if preservesTerminalFocusOnResign,
           data.elementsEqual([0x1b, 0x5b, 0x4f]) {
            return
        }
        forwardTerminalInput(source: source, data: data)
    }

    /// Separated for deterministic verification without starting a child PTY.
    open func forwardTerminalInput(
        source: TerminalView,
        data: ArraySlice<UInt8>
    ) {
        super.send(source: source, data: data)
    }
}
