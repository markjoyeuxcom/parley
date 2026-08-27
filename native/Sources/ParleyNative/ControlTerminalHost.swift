import AppKit
import ParleyCore
import ParleyTerminal
import SwiftTerm
import SwiftUI

/// A native terminal for one single-pane member window, fed by the tmux
/// control-mode stream instead of a pty client. The view owns its scrollback,
/// so selection, wheel and drag auto-scroll are plain terminal behaviour with
/// no tmux copy mode involved; mouse-aware CLIs still receive their events
/// through input forwarding because the fed bytes carry their mouse-mode
/// requests into this view exactly as they would into a real terminal.
struct ControlTerminalHost: NSViewRepresentable {
    let paneID: String
    let windowID: String
    let model: AppModel
    let handle: TerminalHandle

    func makeCoordinator() -> Coordinator {
        Coordinator(paneID: paneID, windowID: windowID, model: model)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        ParleyTerminalConfiguration.applyAppearance(to: terminal)
        terminal.terminalDelegate = context.coordinator
        handle.terminal = terminal
        model.attachControlStream(paneID: paneID, to: terminal)
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ terminal: TerminalView, context: Context) {
        handle.terminal = terminal
    }

    static func dismantleNSView(_ terminal: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private let paneID: String
        private let windowID: String
        private weak var model: AppModel?

        init(paneID: String, windowID: String, model: AppModel) {
            self.paneID = paneID
            self.windowID = windowID
            self.model = model
        }

        func detach() {
            model?.detachControlStream(paneID: paneID)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model?.sendControlInput(paneID: paneID, bytes: data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            model?.resizeControlWindow(windowID, columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
