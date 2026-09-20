import AppKit
import ParleyUI
import SwiftUI

@MainActor
private final class PaneActionsProbe: NSObject, ObservableObject {
    @Published var revision = 0
    var tracking: NSMenu?
    var opened: NSMenu?
    var refreshes = 0
    var mutations = 0
    var selections: [Int] = []

    @objc func began(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu.supermenu == nil,
              menu.items.contains(where: { $0.title == "Move to Workspace" }) else { return }
        tracking = menu
        opened = menu
    }
    @objc func ended(_ note: Notification) {
        if note.object as? NSMenu === tracking { tracking = nil }
    }
    @objc func changed(_ note: Notification) {
        guard var menu = note.object as? NSMenu, let tracking, refreshes > 0 else { return }
        while let parent = menu.supermenu { menu = parent }
        if menu === tracking { mutations += 1 }
    }

    var items: [ToolbarMenuItem] {
        let captured = revision
        return [
            .action(captured.isMultiple(of: 2) ? "Zoom Pane" : "Unzoom") {},
            .action("Rename…") {},
            .separator,
            .submenu("Move to Workspace", items: [
                .action("Workspace \(captured)") { self.selections.append(captured) },
                .action("Another Workspace") { self.selections.append(-1) },
            ]),
            .separator,
            .action("Close Pane…", isDestructive: true) {},
        ]
    }
}

private struct PaneActionsFixture: View {
    @ObservedObject var probe: PaneActionsProbe
    var contextual = false
    var body: some View {
        if contextual {
            Text("Pane \(probe.revision)")
                .frame(width: 240, height: 28)
                .overlay { PaneContextMenu(items: probe.items) }
        } else {
            HStack {
                Text("Pane \(probe.revision)")
                Spacer()
                PaneActionsMenu(accessibilityLabel: "Pane actions for Pane \(probe.revision)", items: probe.items)
            }.padding(8).frame(width: 240, height: 28)
        }
    }
}

func checkPaneActionsMenuTracking(contextual: Bool = false) throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let probe = PaneActionsProbe()
        let host = NSHostingView(rootView: PaneActionsFixture(probe: probe, contextual: contextual))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let center = NotificationCenter.default
        center.addObserver(probe, selector: #selector(PaneActionsProbe.began), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(probe, selector: #selector(PaneActionsProbe.ended), name: NSMenu.didEndTrackingNotification, object: nil)
        for name in [NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            center.addObserver(probe, selector: #selector(PaneActionsProbe.changed), name: name, object: nil)
        }
        defer { center.removeObserver(probe) }

        @MainActor func findControl(_ view: NSView) -> NSView? {
            if contextual {
                if view.identifier?.rawValue == "ParleyPaneContextMenu" { return view }
            } else if let control = view as? NSControl, !(control is NSTextField) { return control }
            return view.subviews.lazy.compactMap { findControl($0) }.first
        }
        guard let button = findControl(host), button.bounds.width > 0, button.bounds.height > 0 else {
            throw PaneActionsFailure("Missing pane action button: \(String(describing: findControl(host)?.bounds))")
        }

        var completed = false
        for attempt in 1...3 {
            probe.revision = 0
            probe.refreshes = 0
            probe.mutations = 0
            probe.opened = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard probe.tracking != nil else { return }
                    probe.refreshes += 1
                    probe.revision = probe.refreshes
                    if probe.refreshes >= 12 {
                        if contextual, probe.refreshes == 12, let submenu = probe.tracking?.items.first(where: { $0.title == "Move to Workspace" })?.submenu {
                            submenu.performActionForItem(at: 0)
                        }
                        probe.tracking?.cancelTracking()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            let timeout = Timer(timeInterval: 3, repeats: false) { _ in
                MainActor.assumeIsolated { probe.tracking?.cancelTracking(); (button as? NSPopUpButton)?.menu?.cancelTracking() }
            }
            RunLoop.main.add(timeout, forMode: .common)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: contextual ? .rightMouseDown : .leftMouseDown, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if contextual { button.rightMouseDown(with: event) } else { button.mouseDown(with: event) }
            timer.invalidate()
            timeout.invalidate()
            guard probe.mutations == 0 else {
                throw PaneActionsFailure("Pane actions changed \(probe.mutations) menu items during \(probe.refreshes) live updates")
            }
            if probe.refreshes >= 12 { completed = true; break }
            print("  note: pane actions tracking ended externally after \(probe.refreshes) updates (attempt \(attempt) of 3)")
        }
        guard completed, let menu = probe.opened,
              let submenu = menu.items.first(where: { $0.title == "Move to Workspace" })?.submenu,
              submenu.items.map(\.title) == ["Workspace 0", "Another Workspace"] else {
            throw PaneActionsFailure("Pane actions did not preserve the workspace submenu during live updates")
        }
        if !contextual { submenu.performActionForItem(at: 0) }
        guard probe.selections == [0] else { throw PaneActionsFailure("Move selected a changed destination") }

        probe.revision = 13
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let close = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if contextual, let fresh = probe.tracking?.items.first(where: { $0.title == "Move to Workspace" })?.submenu {
                    fresh.performActionForItem(at: 0)
                }
                probe.tracking?.cancelTracking()
                (button as? NSPopUpButton)?.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(close, forMode: .common)
        defer { close.invalidate() }
        if contextual {
            // The second entry path is Control-click, not only right-click.
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .control,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            button.mouseDown(with: event)
        } else {
            guard let popup = button as? NSPopUpButton else { throw PaneActionsFailure("No native pane action control") }
            popup.performClick(nil)
        }
        guard let fresh = probe.opened?.items.first(where: { $0.title == "Move to Workspace" })?.submenu,
              fresh.items.map(\.title) == ["Workspace 13", "Another Workspace"] else {
            throw PaneActionsFailure("Pane actions did not refresh workspace destinations when reopened")
        }
        if !contextual { fresh.performActionForItem(at: 0) }
        guard probe.selections == [0, 13] else { throw PaneActionsFailure("Reopened menu retained an old destination") }
        if contextual {
            // No current context-click means the transparent overlay must not
            // intercept ordinary pane selection or scrolling.
            guard button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) == nil else {
                throw PaneActionsFailure("The context menu overlay intercepted ordinary input")
            }
        } else {
            guard button.bounds.width >= 16, button.bounds.width <= 32, button.bounds.height >= 16 else {
                throw PaneActionsFailure("The pane action button lost its compact click target: \(button.bounds)")
            }
        }
        print("Pane actions \(contextual ? "sidebar" : "header"): workspace submenu unchanged across 12 live updates; selections use opening snapshot; reopening refreshes destinations")
    }
}

private struct PaneActionsFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
