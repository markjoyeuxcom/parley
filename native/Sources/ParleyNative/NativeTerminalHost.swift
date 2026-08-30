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

    func makeNSView(context: Context) -> NSView {
        do {
            let terminal = try model.ghosttyView(paneID: paneID)
            if focusOnAttach {
                DispatchQueue.main.async {
                    model.focusNativeTerminalIfSelected(paneID, in: terminal.window)
                }
            }
            return terminal
        } catch {
            return UnavailableTerminalView(message: error.localizedDescription)
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard view is AppTerminalView else { return }
        model.setGhosttyPaneVisible(true, paneID: paneID)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let terminal = view as? AppTerminalView else { return }
        terminal.setSurfaceVisible(false)
        // Deliberately do not clear its controller. GhosttyPaneRegistry retains
        // this exact view and its exec surface for workspace/window reattach.
    }
}

private final class UnavailableTerminalView: NSView {
    init(message: String) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: message)
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
