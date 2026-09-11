import AppKit
import GhosttyTerminal
import ParleyCore
import SwiftUI

/// Presents one retained Ghostty exec surface. The registry, not SwiftUI's
/// transient representable, owns the native view so workspace switches and a
/// hidden Parley window do not destroy the child process or terminal state.
struct NativeTerminalHost: NSViewRepresentable {
    let paneID: String
    let model: AppModel
    let focusOnAttach: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        attachIfNeeded(host)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        // The surface can be unavailable for reasons that pass: the pane list
        // has not been published yet during a workspace restore, for instance.
        // SwiftUI keeps the view it was given, so without retrying here the
        // first transient failure would leave the pane showing its error for as
        // long as the view lived — and a pane that never changes its launch
        // generation never gets a fresh `makeNSView` to recover through.
        attachIfNeeded(host)
        guard host.terminal != nil else { return }
        model.setGhosttyPaneVisible(true, paneID: paneID)
    }

    private func attachIfNeeded(_ host: TerminalHostView) {
        guard host.terminal == nil else { return }
        do {
            let terminal = try model.ghosttyView(paneID: paneID)
            host.mount(terminal)
            if focusOnAttach {
                DispatchQueue.main.async {
                    model.focusNativeTerminalIfSelected(paneID, in: terminal.window)
                }
            }
        } catch {
            host.showUnavailable(error.localizedDescription)
        }
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        host.detachTerminal()
    }
}

/// Hosts the retained Ghostty surface rather than being it, so an unavailable
/// pane can be replaced by its terminal later without SwiftUI rebuilding the
/// representable.
final class TerminalHostView: NSView {
    private(set) var terminal: AppTerminalView?
    private var unavailable: UnavailableTerminalView?

    func mount(_ terminal: AppTerminalView) {
        guard self.terminal !== terminal else { return }
        unavailable?.removeFromSuperview()
        unavailable = nil
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.terminal = terminal
    }

    func showUnavailable(_ message: String) {
        if let unavailable {
            unavailable.message = message
            return
        }
        let view = UnavailableTerminalView(message: message)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        unavailable = view
    }

    /// Releases the surface back to the registry. Deliberately does not clear
    /// its controller: `GhosttyPaneRegistry` retains this exact view and its
    /// exec surface for workspace and window reattach.
    func detachTerminal() {
        guard let terminal else { return }
        terminal.setSurfaceVisible(false)
        terminal.removeFromSuperview()
        self.terminal = nil
    }
}

private final class UnavailableTerminalView: NSView {
    private let label: NSTextField

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(message: String) {
        label = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
