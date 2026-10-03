import AppKit
import SwiftUI

/// Dictate is click to start, click to stop: every activation (a mouse click,
/// the keyboard or VoiceOver) toggles recording. Until 3 October 2026 the
/// mouse held it, recording only while the button stayed pressed (Mark's
/// request). Control-Shift-Space keeps its hold in the main window, and
/// recording still ends on its own at the 60-second limit or when the window
/// loses focus.
public struct DictateButton: NSViewRepresentable {
    public var enabled: Bool
    public var recording: Bool
    public var toggle: () -> Void
    public init(enabled: Bool, recording: Bool, toggle: @escaping () -> Void) {
        self.enabled = enabled; self.recording = recording; self.toggle = toggle
    }
    public func makeNSView(context: Context) -> DictateToggleButton { DictateToggleButton() }
    public func updateNSView(_ view: DictateToggleButton, context: Context) {
        view.isEnabled = enabled; view.title = recording ? "Stop" : "Dictate"
        view.image = NSImage(systemSymbolName: recording ? "stop.fill" : "mic", accessibilityDescription: nil)
        view.toggle = toggle
        view.setAccessibilityLabel(recording ? "Stop voice recording" : "Start voice recording")
        view.setAccessibilityHelp("Starts and stops voice recording. Control Shift Space held in the main window also dictates. Nothing is sent until reviewed.")
    }
}

public final class DictateToggleButton: NSButton {
    var toggle: () -> Void = {}
    public init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; controlSize = .small; imagePosition = .imageLeading
        target = self; action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { toggle() }
    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle(); return true
    }
}
