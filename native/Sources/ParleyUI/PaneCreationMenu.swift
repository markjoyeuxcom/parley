import AppKit
import ParleyCore
import SwiftUI

public enum PaneCreationFolder {
    case newPane, activePane, chosen
}

/// A menu opening owns one immutable item tree. SwiftUI updates can replace the
/// next opening's configuration, but cannot invalidate AppKit's highlighted
/// item or its submenu while the person is choosing a split.
public struct PaneCreationMenu: NSViewRepresentable {
    public let offersActivePaneFolder: Bool
    public let onCreate: (PaneKind, SplitDirection, PaneCreationFolder) -> Void

    public init(
        offersActivePaneFolder: Bool,
        onCreate: @escaping (PaneKind, SplitDirection, PaneCreationFolder) -> Void
    ) {
        self.offersActivePaneFolder = offersActivePaneFolder
        self.onCreate = onCreate
    }

    public func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    public func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let menu = NSMenu(title: "Pane")
        menu.autoenablesItems = false
        context.coordinator.menuNeedsUpdate(menu)
        menu.delegate = context.coordinator
        button.menu = menu
        button.selectItem(at: 0)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("New pane")
        button.setAccessibilityHelp("Choose an agent or shell and where to split the active workspace")
        button.toolTip = "Open a new agent or shell pane"
        button.sizeToFit()
        return button
    }

    public func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Do not assign button.menu, change items, or call menu.update() here.
        context.coordinator.configuration = self
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.cell?.cellSize
    }

    @MainActor
    public final class Coordinator: NSObject, NSMenuDelegate {
        fileprivate var configuration: PaneCreationMenu
        private var isTracking = false

        fileprivate init(configuration: PaneCreationMenu) { self.configuration = configuration }

        public func menuNeedsUpdate(_ menu: NSMenu) {
            guard !isTracking else { return }
            let snapshot = configuration
            menu.removeAllItems()
            // A pull-down button reserves its first item for the button label.
            let label = menu.addItem(withTitle: "Pane", action: nil, keyEquivalent: "")
            label.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            for kind in PaneKind.allCases {
                let item = NSMenuItem(title: kind.label, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: kind.label)
                submenu.autoenablesItems = false
                addHeading("New Pane Folder", to: submenu)
                addAction("Split Right", kind, .horizontal, .newPane, snapshot, to: submenu)
                addAction("Split Below", kind, .vertical, .newPane, snapshot, to: submenu)
                if snapshot.offersActivePaneFolder {
                    submenu.addItem(.separator())
                    addHeading("Active Pane Folder", to: submenu)
                    addAction("Split Right Here", kind, .horizontal, .activePane, snapshot, to: submenu)
                    addAction("Split Below Here", kind, .vertical, .activePane, snapshot, to: submenu)
                }
                submenu.addItem(.separator())
                addHeading("Another Folder", to: submenu)
                addAction("Split Right in Folder…", kind, .horizontal, .chosen, snapshot, to: submenu)
                addAction("Split Below in Folder…", kind, .vertical, .chosen, snapshot, to: submenu)
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        public func menuWillOpen(_ menu: NSMenu) { isTracking = true }
        public func menuDidClose(_ menu: NSMenu) { isTracking = false }

        private func addHeading(_ title: String, to menu: NSMenu) {
            menu.addItem(NSMenuItem.sectionHeader(title: title))
        }

        private func addAction(
            _ title: String, _ kind: PaneKind, _ direction: SplitDirection,
            _ folder: PaneCreationFolder, _ snapshot: PaneCreationMenu, to menu: NSMenu
        ) {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Selection { snapshot.onCreate(kind, direction, folder) }
            menu.addItem(item)
        }

        @objc private func choose(_ item: NSMenuItem) {
            (item.representedObject as? Selection)?.perform()
        }
    }
}

@MainActor
private final class Selection {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}
