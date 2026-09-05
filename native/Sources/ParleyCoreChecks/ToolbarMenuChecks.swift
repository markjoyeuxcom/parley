import AppKit
import ParleyUI
import SwiftUI

@MainActor
private final class ToolbarMenuProbe: NSObject, ObservableObject {
    @Published var tick = 0
    let name: String
    var tracking: NSMenu?
    var opened: NSMenu?
    var mutations = 0
    var refreshes = 0
    var chromeChanges = 0
    var selections: [String] = []
    init(_ name: String) { self.name = name }

    @objc func began(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu.supermenu == nil,
              menu.items.contains(where: { $0.title == "Choose 0" || $0.title == "Choose 13" }) else { return }
        tracking = menu
        opened = menu
    }
    @objc func ended(_ note: Notification) {
        if note.object as? NSMenu === tracking { tracking = nil }
    }
    @objc func mutated(_ note: Notification) {
        guard var menu = note.object as? NSMenu, let tracking, refreshes > 0 else { return }
        while let parent = menu.supermenu { menu = parent }
        if menu === tracking { mutations += 1 }
    }

    var menu: ToolbarActionMenu {
        let revision = tick
        return ToolbarActionMenu(
            title: revision == 0 ? name : "\(name) \(revision)",
            systemImage: revision.isMultiple(of: 2) ? "shippingbox" : "shippingbox.fill",
            isEnabled: revision != 5,
            accessibilityLabel: name, accessibilityValue: "Revision \(revision)",
            help: "Menu help", accessibilityHint: "Choose an action",
            items: [
                .heading("Targets"),
                .action("Choose \(revision)", help: "Action help") { self.selections.append("root-\(revision)") },
                .submenu("Other Workspace", items: [
                    .action("Target \(revision)", systemImage: "arrow.turn.up.right") { self.selections.append("target-\(revision)") },
                    .submenu("Nested", items: [
                        .action("File \(revision)") { self.selections.append("file-\(revision)") }
                    ])
                ]),
                .separator,
                .action("Unavailable", isEnabled: false) { self.selections.append("disabled") },
                .message("No other targets")
            ]
        )
    }
}

private struct ToolbarMenuFixture: View {
    @ObservedObject var probe: ToolbarMenuProbe
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { probe.menu; Text("Wide \(probe.tick)").frame(width: 200) }
            HStack { probe.menu; Text("Compact \(probe.tick)").frame(width: 40) }
        }.frame(width: probe.tick.isMultiple(of: 2) ? 360 : 180, height: 80)
    }
}

func checkToolbarMenuSurvivesUpdatesWhileTracking(_ name: String) throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let probe = ToolbarMenuProbe(name)
        let host = NSHostingView(rootView: ToolbarMenuFixture(probe: probe))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let center = NotificationCenter.default
        center.addObserver(probe, selector: #selector(ToolbarMenuProbe.began), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(probe, selector: #selector(ToolbarMenuProbe.ended), name: NSMenu.didEndTrackingNotification, object: nil)
        for name in [NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            center.addObserver(probe, selector: #selector(ToolbarMenuProbe.mutated), name: name, object: nil)
        }
        defer { center.removeObserver(probe) }

        @MainActor func control(in view: NSView) -> NSControl? {
            if let control = view as? NSControl { return control }
            return view.subviews.lazy.compactMap { control(in: $0) }.first
        }
        guard let button = control(in: host), button.bounds.width > 40 else {
            throw ToolbarMenuFailure("No usable \(name) control")
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard probe.tracking != nil else { return }
                if let popup = button as? NSPopUpButton, !popup.isEnabled || popup.title != name {
                    probe.chromeChanges += 1
                }
                probe.refreshes += 1
                probe.tick = probe.refreshes
                if probe.refreshes >= 12 { probe.tracking?.cancelTracking() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Bound even a failure to recognize the menu; never synthesize global input.
        let timeout = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { (button as? NSPopUpButton)?.menu?.cancelTracking() }
        }
        RunLoop.main.add(timeout, forMode: .common)
        defer { timer.invalidate(); timeout.invalidate() }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        button.mouseDown(with: event)
        timer.invalidate()
        timeout.invalidate()
        guard let menu = probe.opened, probe.refreshes >= 12 else {
            throw ToolbarMenuFailure("\(name) lost tracking after \(probe.refreshes) live refreshes")
        }
        guard probe.chromeChanges == 0 else {
            throw ToolbarMenuFailure("\(name) changed its button title or availability while open")
        }
        guard probe.mutations == 0 else {
            throw ToolbarMenuFailure("\(name) changed \(probe.mutations) menu items during tracking")
        }
        guard let root = menu.items.first(where: { $0.title == "Choose 0" }),
              let submenu = menu.items.first(where: { $0.title == "Other Workspace" })?.submenu,
              let target = submenu.items.first(where: { $0.title == "Target 0" }),
              let nested = submenu.items.first(where: { $0.title == "Nested" })?.submenu,
              let file = nested.items.first(where: { $0.title == "File 0" }),
              menu.items.first(where: { $0.title == "Unavailable" })?.isEnabled == false else {
            throw ToolbarMenuFailure("\(name) did not preserve its open item tree")
        }
        if let disabled = menu.items.first(where: { $0.title == "Unavailable" }) {
            menu.performActionForItem(at: menu.index(of: disabled))
        }
        menu.performActionForItem(at: menu.index(of: root))
        submenu.performActionForItem(at: submenu.index(of: target))
        nested.performActionForItem(at: nested.index(of: file))
        guard probe.selections == ["root-0", "target-0", "file-0"] else {
            throw ToolbarMenuFailure("\(name) routed a selection to a different snapshot: \(probe.selections)")
        }

        probe.tick = 13
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let popup = button as? NSPopUpButton else { throw ToolbarMenuFailure("No native pull-down control") }
        probe.opened = nil
        let close = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { popup.menu?.cancelTracking() }
        }
        RunLoop.main.add(close, forMode: .common)
        defer { close.invalidate() }
        popup.performClick(nil)
        guard let reopened = probe.opened,
              let fresh = reopened.items.first(where: { $0.title == "Choose 13" }) else {
            throw ToolbarMenuFailure("\(name) did not refresh on its next opening")
        }
        reopened.performActionForItem(at: reopened.index(of: fresh))
        guard probe.selections.last == "root-13", popup.title == "\(name) 13" else {
            throw ToolbarMenuFailure("\(name) retained an old action or changed its toolbar label")
        }
        probe.tick = 5
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard !popup.isEnabled else {
            throw ToolbarMenuFailure("\(name) did not apply its latest disabled state after closing")
        }
        print("\(name): 0 item or button changes across 12 live updates; nested selections preserved; next opening refreshed")
    }
}

private struct ToolbarMenuFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
