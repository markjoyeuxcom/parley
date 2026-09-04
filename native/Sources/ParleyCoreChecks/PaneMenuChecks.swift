import AppKit
import ParleyCore
import ParleyUI
import SwiftUI

@MainActor
private final class PaneMenuProbe: NSObject, ObservableObject {
    @Published var tick = 0
    var trackedMenu: NSMenu?
    var lastMenu: NSMenu?
    var didOpen = false
    var changesWhileTracking = 0
    @objc func menuDidBegin(_ note: Notification) {
        guard let menu = note.object as? NSMenu,
              menu.items.contains(where: { $0.title == "Shell" }) else { return }
        trackedMenu = menu
        lastMenu = menu
        didOpen = true
    }
    @objc func menuDidEnd(_ note: Notification) {
        if note.object as? NSMenu === trackedMenu { trackedMenu = nil }
    }
    @objc func menuDidMutate(_ note: Notification) {
        guard var menu = note.object as? NSMenu, let trackedMenu, tick >= 1 else { return }
        while let parent = menu.supermenu { menu = parent }
        if menu === trackedMenu { changesWhileTracking += 1 }
    }
    var selections: [(PaneKind, SplitDirection, PaneCreationFolder)] = []
}

private struct PaneMenuFixture: View {
    @ObservedObject var probe: PaneMenuProbe
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { menu; Text("Wide \(probe.tick)").frame(width: 200) }
            HStack { menu; Text("Compact \(probe.tick)").frame(width: 40) }
        }.frame(width: probe.tick.isMultiple(of: 2) ? 360 : 180, height: 80)
    }
    private var menu: some View {
        PaneCreationMenu(offersActivePaneFolder: probe.tick.isMultiple(of: 2)) { kind, direction, folder in
            probe.selections.append((kind, direction, folder))
        }
    }
}

func checkPaneMenuSurvivesUpdatesWhileTracking() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let probe = PaneMenuProbe()
        let host = NSHostingView(rootView: PaneMenuFixture(probe: probe))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let center = NotificationCenter.default
        center.addObserver(probe, selector: #selector(PaneMenuProbe.menuDidBegin), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(probe, selector: #selector(PaneMenuProbe.menuDidEnd), name: NSMenu.didEndTrackingNotification, object: nil)
        for name in [NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            center.addObserver(probe, selector: #selector(PaneMenuProbe.menuDidMutate), name: name, object: nil)
        }
        defer { center.removeObserver(probe) }
        // Deliberately runs in tracking mode: terminal callbacks and pending
        // MainActor work can still update the model when the refresh timer pauses.
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                probe.tick += 1
                if probe.tick >= 12 { probe.trackedMenu?.cancelTracking() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        @MainActor func menuControl(in view: NSView) -> NSControl? {
            if let control = view as? NSControl { return control }
            return view.subviews.lazy.compactMap { menuControl(in: $0) }.first
        }
        guard let button = menuControl(in: host) else {
            throw PaneMenuCheckFailure(message: "the toolbar did not render its menu control")
        }
        guard button.bounds.width > 40, button.bounds.height >= 16 else {
            throw PaneMenuCheckFailure(message: "the menu button has no usable click target: \(button.bounds)")
        }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        // AppKit tracks a real menu in this check process. No global input,
        // vendor process or second Parley instance is involved.
        button.mouseDown(with: event)
        timer.invalidate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard probe.didOpen, probe.tick >= 12 else {
            throw PaneMenuCheckFailure(message: "the menu did not remain open for the refresh stress check (opened: \(probe.didOpen), ticks: \(probe.tick))")
        }
        guard probe.changesWhileTracking == 0 else {
            throw PaneMenuCheckFailure(message: "\(probe.changesWhileTracking) menu item mutations occurred during tracking")
        }
        guard let menu = probe.lastMenu else { throw PaneMenuCheckFailure(message: "no opened menu") }
        let vendorItems = menu.items.filter { $0.submenu != nil }
        guard vendorItems.map(\.title) == PaneKind.allCases.map(\.label) else {
            throw PaneMenuCheckFailure(message: "the menu lost or reordered a pane kind")
        }
        for (kind, item) in zip(PaneKind.allCases, vendorItems) {
            let submenu = item.submenu!
            let actions = submenu.items.enumerated().filter { $0.element.action != nil }
            guard actions.count == 6 else { throw PaneMenuCheckFailure(message: "a folder or split choice is missing") }
            for (index, _) in actions { submenu.performActionForItem(at: index) }
            let actual = Array(probe.selections.suffix(6))
            let expected: [(SplitDirection, PaneCreationFolder)] = [
                (.horizontal, .newPane), (.vertical, .newPane),
                (.horizontal, .activePane), (.vertical, .activePane),
                (.horizontal, .chosen), (.vertical, .chosen),
            ]
            guard actual.count == expected.count,
                  zip(actual, expected).allSatisfy({ selected, expected in
                      selected.0 == kind && selected.1 == expected.0 && selected.2 == expected.1
                  }) else { throw PaneMenuCheckFailure(message: "a menu selection routed to the wrong pane, split or folder") }
        }
        guard probe.selections.count == 30 else {
            throw PaneMenuCheckFailure(message: "a menu action fired more than once")
        }
        // Closing releases the snapshot. The next opening must use the latest
        // configuration instead of permanently freezing the initial choices.
        probe.tick = 13
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        probe.didOpen = false
        let closeSecondOpening = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { probe.trackedMenu?.cancelTracking() }
        }
        RunLoop.main.add(closeSecondOpening, forMode: .common)
        defer { closeSecondOpening.invalidate() }
        (button as? NSPopUpButton)?.performClick(nil)
        guard probe.didOpen else { throw PaneMenuCheckFailure(message: "the menu could not reopen") }
        guard menu.items.compactMap(\.submenu).allSatisfy({ submenu in
            submenu.items.filter { $0.action != nil }.count == 4
                && !submenu.items.contains { $0.title == "Active Pane Folder" }
        }) else { throw PaneMenuCheckFailure(message: "the next opening retained stale folder choices") }
        guard (button as? NSPopUpButton)?.title == "Pane" else {
            throw PaneMenuCheckFailure(message: "selecting a submenu changed the toolbar label")
        }
        print("Pane menu: 0 mutations during 12 live refreshes; all 30 split actions routed correctly; next opening refreshed")
    }
}

private struct PaneMenuCheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
