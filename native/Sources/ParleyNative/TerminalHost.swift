import AppKit
import ParleyTerminal
import SwiftTerm
import SwiftUI

/// A process-backed terminal that lets the native split surface make its
/// corresponding Parley pane authoritative before SwiftTerm handles the
/// click. AppKit keeps subsequent drag events with this view, including when
/// the pointer crosses its bottom edge.
final class PaneTerminalView: ParleyLocalProcessTerminalView {
    var onPrimaryMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // NSView does not automatically become first responder when clicked.
        // Without this, the newest attached terminal keeps receiving keyboard
        // input even after the model selects an older pane.
        window?.makeFirstResponder(self)
        let callback = onPrimaryMouseDown
        super.mouseDown(with: event)
        // Updating the observable pane model during AppKit mouse dispatch can
        // rebuild the split around the view that owns the event. Publish the
        // authoritative base-session selection on the next main-loop turn.
        DispatchQueue.main.async {
            callback?()
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let configuration: AttachConfiguration
    let handle: TerminalHandle
    let focusOnAttach: Bool
    let preservesTerminalFocusOnResign: Bool
    let onFocus: (() -> Void)?

    init(
        configuration: AttachConfiguration,
        handle: TerminalHandle,
        focusOnAttach: Bool = true,
        preservesTerminalFocusOnResign: Bool = false,
        onFocus: (() -> Void)? = nil
    ) {
        self.configuration = configuration
        self.handle = handle
        self.focusOnAttach = focusOnAttach
        self.preservesTerminalFocusOnResign = preservesTerminalFocusOnResign
        self.onFocus = onFocus
    }

    func makeNSView(context: Context) -> PaneTerminalView {
        let terminal = PaneTerminalView(frame: .zero)
        ParleyTerminalConfiguration.apply(to: terminal)
        terminal.preservesTerminalFocusOnResign = preservesTerminalFocusOnResign
        terminal.onPrimaryMouseDown = onFocus

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
            if focusOnAttach {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        return terminal
    }

    func updateNSView(_ terminal: PaneTerminalView, context: Context) {
        handle.terminal = terminal
        terminal.preservesTerminalFocusOnResign = preservesTerminalFocusOnResign
        terminal.onPrimaryMouseDown = onFocus
    }

    static func dismantleNSView(_ terminal: PaneTerminalView, coordinator: Void) {
        // This detaches the tmux client. The isolated tmux server and every
        // agent pane continue running for the next Parley window.
        terminal.onPrimaryMouseDown = nil
        terminal.terminate()
    }
}
