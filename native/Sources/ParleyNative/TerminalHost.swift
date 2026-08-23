import AppKit
import ParleyTerminal
import SwiftTerm
import SwiftUI

struct TerminalHost: NSViewRepresentable {
    let configuration: AttachConfiguration
    let handle: TerminalHandle

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        ParleyTerminalConfiguration.apply(to: terminal)

        handle.terminal = terminal
        terminal.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: configuration.environment,
            currentDirectory: configuration.cwd
        )

        DispatchQueue.main.async {
            do { try ParleyTerminalConfiguration.enablePreferredRenderer(on: terminal) }
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
