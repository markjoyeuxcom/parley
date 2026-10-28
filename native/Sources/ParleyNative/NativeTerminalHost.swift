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

    /// Identifies one host, so a host torn down late can tell whether a newer
    /// one has taken its retained view.
    final class Coordinator {}

    /// The host that last presented each retained view. The same view can
    /// move between two hosts in one update (a pane becoming a tab, or Tabs
    /// becoming Grid), and SwiftUI may tear the old host down before or after
    /// the new one adopted it; only the current owner may hide the surface.
    @MainActor private static var owners: [ObjectIdentifier: ObjectIdentifier] = [:]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        do {
            let terminal = try model.ghosttyView(paneID: paneID)
            Self.owners[ObjectIdentifier(terminal)] = ObjectIdentifier(context.coordinator)
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
        Self.owners[ObjectIdentifier(view)] = ObjectIdentifier(context.coordinator)
        model.setGhosttyPaneVisible(true, paneID: paneID)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let terminal = view as? AppTerminalView else { return }
        // Deliberately do not clear its controller. GhosttyPaneRegistry retains
        // this exact view and its exec surface for workspace/window reattach.
        //
        // A newer host already presents this view, so it stays visible. Torn
        // down first, this host hides it, and the newer host's request for the
        // view (`GhosttyPaneRegistry.view(for:)`) shows it again.
        let key = ObjectIdentifier(terminal)
        guard owners[key] == ObjectIdentifier(coordinator) else { return }
        owners[key] = nil
        terminal.setSurfaceVisible(false)
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
