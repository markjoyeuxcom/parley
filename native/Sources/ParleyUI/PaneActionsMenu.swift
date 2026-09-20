import AppKit
import SwiftUI

public struct PaneActionsMenu: View {
    public let accessibilityLabel: String
    public let items: [ToolbarMenuItem]

    public init(accessibilityLabel: String, items: [ToolbarMenuItem]) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items
    }

    public var body: some View {
        // Terminal callbacks still publish model changes while a menu tracks,
        // even when the periodic refresh timer is paused. Keep the complete
        // item tree and its captured destinations fixed until this opening ends.
        ToolbarActionMenu(
            title: "Pane actions", systemImage: "ellipsis", iconOnly: true,
            accessibilityLabel: accessibilityLabel, items: items
        ).fixedSize()
    }
}

/// Transparent overlay: ordinary pane selection and scrolling pass through.
/// Right-click and Control-click open the same native item snapshot as the header.
public struct PaneContextMenu: NSViewRepresentable {
    public let items: [ToolbarMenuItem]

    public init(items: [ToolbarMenuItem]) { self.items = items }

    public func makeNSView(context: Context) -> NSView {
        let view = PaneContextMenuView()
        view.items = items
        view.identifier = NSUserInterfaceItemIdentifier("ParleyPaneContextMenu")
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        (view as? PaneContextMenuView)?.items = items
    }
}

private final class PaneContextMenuView: NSView {
    var items: [ToolbarMenuItem] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) { openMenu(with: event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { openMenu(with: event) }
        else { super.mouseDown(with: event) }
    }

    private func openMenu(with event: NSEvent) {
        let menu = NSMenu()
        let opening = NativeActionMenuSnapshot(items: items)
        opening.append(to: menu)
        withExtendedLifetime(opening) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
