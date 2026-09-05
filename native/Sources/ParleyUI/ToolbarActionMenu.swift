import AppKit
import SwiftUI

public indirect enum ToolbarMenuItem {
    case action(String, systemImage: String? = nil, isEnabled: Bool = true, help: String? = nil, isDestructive: Bool = false, perform: () -> Void)
    case submenu(String, systemImage: String? = nil, isEnabled: Bool = true, items: [ToolbarMenuItem])
    case heading(String)
    case message(String)
    case separator
}

/// Like PaneCreationMenu, each opening owns an immutable AppKit item tree.
/// Live model changes update only the next opening, including submenus and actions.
public struct ToolbarActionMenu: NSViewRepresentable {
    public let title: String
    public let systemImage: String
    public let isEnabled: Bool
    public let accessibilityLabel: String
    public let accessibilityValue: String
    public let help: String
    public let accessibilityHint: String
    public let items: [ToolbarMenuItem]

    public init(
        title: String, systemImage: String, isEnabled: Bool = true,
        accessibilityLabel: String, accessibilityValue: String = "",
        help: String = "", accessibilityHint: String = "", items: [ToolbarMenuItem]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.help = help
        self.accessibilityHint = accessibilityHint
        self.items = items
    }

    public var asSubmenu: ToolbarMenuItem {
        .submenu(title, systemImage: systemImage, isEnabled: isEnabled, items: items)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    public func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        context.coordinator.menuNeedsUpdate(menu)
        menu.delegate = context.coordinator
        button.menu = menu
        button.selectItem(at: 0)
        button.imagePosition = .imageLeading
        context.coordinator.button = button
        context.coordinator.updateControl()
        return button
    }

    public func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.updateControl()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.cell?.cellSize
    }

    @MainActor
    public final class Coordinator: NSObject, NSMenuDelegate {
        fileprivate var configuration: ToolbarActionMenu
        fileprivate weak var button: NSPopUpButton?
        private var isTracking = false

        fileprivate init(configuration: ToolbarActionMenu) { self.configuration = configuration }

        fileprivate func updateControl() {
            // Even changing the count, image or enabled state of the button can
            // disturb tracking. Apply all chrome changes only while closed.
            guard !isTracking, let button else { return }
            button.menu?.item(at: 0)?.title = configuration.title
            button.menu?.item(at: 0)?.image = NSImage(systemSymbolName: configuration.systemImage, accessibilityDescription: nil)
            button.isEnabled = configuration.isEnabled
            button.setAccessibilityLabel(configuration.accessibilityLabel)
            button.setAccessibilityValue(configuration.accessibilityValue)
            button.setAccessibilityHelp(configuration.accessibilityHint)
            button.toolTip = configuration.help
            button.sizeToFit()
            button.invalidateIntrinsicContentSize()
        }

        public func menuNeedsUpdate(_ menu: NSMenu) {
            guard !isTracking else { return }
            let snapshot = configuration
            menu.removeAllItems()
            let label = menu.addItem(withTitle: snapshot.title, action: nil, keyEquivalent: "")
            label.image = NSImage(systemSymbolName: snapshot.systemImage, accessibilityDescription: nil)
            append(snapshot.items, to: menu)
        }

        public func menuWillOpen(_ menu: NSMenu) { isTracking = true }

        public func menuDidClose(_ menu: NSMenu) {
            isTracking = false
            // AppKit still dispatches the selected action after closing. Keep
            // its item and captured closure intact; refresh only button chrome.
            DispatchQueue.main.async { [weak self] in self?.updateControl() }
        }

        private func append(_ items: [ToolbarMenuItem], to menu: NSMenu) {
            menu.autoenablesItems = false
            for item in items {
                switch item {
                case let .action(title, image, enabled, help, destructive, perform):
                    let row = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                    row.target = self
                    row.representedObject = ToolbarMenuSelection(perform)
                    row.isEnabled = enabled
                    row.toolTip = help
                    if let image { row.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
                    if destructive {
                        row.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
                    }
                    menu.addItem(row)
                case let .submenu(title, image, enabled, children):
                    let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    row.isEnabled = enabled
                    if let image { row.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
                    let submenu = NSMenu(title: title)
                    append(children, to: submenu)
                    row.submenu = submenu
                    menu.addItem(row)
                case let .heading(title):
                    menu.addItem(NSMenuItem.sectionHeader(title: title))
                case let .message(title):
                    let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    row.isEnabled = false
                    menu.addItem(row)
                case .separator:
                    menu.addItem(.separator())
                }
            }
        }

        @objc private func choose(_ item: NSMenuItem) {
            guard item.isEnabled else { return }
            (item.representedObject as? ToolbarMenuSelection)?.perform()
        }
    }
}

@MainActor
private final class ToolbarMenuSelection {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}
