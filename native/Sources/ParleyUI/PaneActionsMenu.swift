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

/// The enabled actions of a snapshot menu, flattened for VoiceOver. The
/// overlay menu opens only on a right or Control click and is not in the
/// accessibility tree, so a row that relies on it names every action it
/// offers instead; a submenu's title leads its actions' names.
public enum ToolbarMenuAccessibility {
    public struct Action: Identifiable {
        public let id: Int
        public let name: String
        public let perform: () -> Void
    }

    public static func actions(_ items: [ToolbarMenuItem]) -> [Action] {
        var actions: [Action] = []
        func collect(_ items: [ToolbarMenuItem], path: [String]) {
            for item in items {
                switch item {
                case let .action(title, _, enabled, _, _, perform) where enabled:
                    actions.append(Action(id: actions.count, name: (path + [title]).joined(separator: ": "), perform: perform))
                case let .submenu(title, _, enabled, children) where enabled:
                    collect(children, path: path + [title])
                default:
                    break
                }
            }
        }
        collect(items, path: [])
        return actions
    }
}

public extension View {
    /// A right-click and Control-click menu built as an AppKit snapshot
    /// (`PaneContextMenu`), whose actions VoiceOver also reaches by name.
    func snapshotContextMenu(_ items: [ToolbarMenuItem]) -> some View {
        overlay { PaneContextMenu(items: items) }
            .accessibilityActions {
                ForEach(ToolbarMenuAccessibility.actions(items)) { action in
                    Button(action.name, action: action.perform)
                }
            }
    }
}
