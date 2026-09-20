import AppKit
import SwiftUI

/// Mouse tracking owns the hold; keyboard/VoiceOver activation is a toggle.
public struct HoldToTalkButton: NSViewRepresentable {
    public var enabled: Bool
    public var recording: Bool
    public var begin: () -> Void
    public var end: () -> Void
    public var toggle: () -> Void
    public init(enabled: Bool, recording: Bool, begin: @escaping () -> Void, end: @escaping () -> Void, toggle: @escaping () -> Void) {
        self.enabled = enabled; self.recording = recording; self.begin = begin; self.end = end; self.toggle = toggle
    }
    public func makeNSView(context: Context) -> VoiceHoldButton { VoiceHoldButton() }
    public func updateNSView(_ view: VoiceHoldButton, context: Context) {
        view.isEnabled = enabled; view.title = recording ? "Recording" : "Dictate"
        view.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: nil)
        view.begin = begin; view.end = end; view.toggle = toggle
        view.setAccessibilityLabel(recording ? "Stop voice recording" : "Start voice recording")
        view.setAccessibilityHelp("Hold the mouse or Control Shift Space to dictate. Keyboard or VoiceOver activation starts and stops recording. Nothing is sent until reviewed.")
    }
}

public final class VoiceHoldButton: NSButton {
    var begin: () -> Void = {}
    var end: () -> Void = {}
    var toggle: () -> Void = {}
    private var trackingMouse = false
    public init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; controlSize = .small; imagePosition = .imageLeading
        target = self; action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingMouse = true; begin()
        defer { end(); trackingMouse = false }
        super.mouseDown(with: event)
    }
    @objc private func activate() { if !trackingMouse { toggle() } }
    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle(); return true
    }
}
