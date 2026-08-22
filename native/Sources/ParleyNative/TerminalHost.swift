import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHost: NSViewRepresentable {
    let configuration: AttachConfiguration
    let handle: TerminalHandle

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
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

        handle.terminal = terminal
        terminal.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: configuration.environment,
            currentDirectory: configuration.cwd
        )

        DispatchQueue.main.async {
            do { try terminal.setUseMetal(true) }
            catch { /* CoreGraphics remains visible if Metal is unavailable. */ }
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        handle.terminal = terminal
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Void) {
        // This detaches the tmux client. The isolated tmux server and every
        // agent pane continue running for the next Parley window.
        terminal.terminate()
    }
}
