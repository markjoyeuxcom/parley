import AppKit
import ParleyUI
import SwiftUI

@MainActor
private final class ChromeProbeWindow: NSWindow {
    var zooms = 0
    var drags = 0
    var minimizes = 0
    override func performMiniaturize(_ sender: Any?) { minimizes += 1 }
    override func performZoom(_ sender: Any?) { zooms += 1 }
    override func performDrag(with event: NSEvent) { drags += 1 }
}

private struct ChromeToolbarFixture: View {
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Menu") {}
                    Text("Workspace and actions").frame(width: 380)
                    WindowDragArea().frame(minWidth: 6, maxWidth: .infinity).frame(height: 42)
                    Button("Status") {}
                }
                HStack {
                    Button("Menu") {}
                    WindowDragArea().frame(minWidth: 6, maxWidth: .infinity).frame(height: 42)
                    Button("Status") {}
                }
            }.frame(height: 42)
            Text("Terminal content").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private func chromeExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw NSError(domain: "WindowChrome", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor
private func chromeEvent(_ window: NSWindow, _ point: NSPoint, clicks: Int = 2,
                         type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}

func checkWindowToolbarDragArea() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let window = ChromeProbeWindow(contentRect: NSRect(x: 20, y: 20, width: 980, height: 200),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "WindowChromeFixture")
        let host = NSHostingView(rootView: ChromeToolbarFixture())
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        @MainActor func dragViews(_ view: NSView) -> [WindowDragView] {
            (view as? WindowDragView).map { [$0] } ?? view.subviews.flatMap(dragViews)
        }
        for width in [980.0, 320.0] {
            window.setContentSize(NSSize(width: width, height: 200))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let areas = dragViews(host).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 20 }
            guard let area = areas.first(where: {
                let midpoint = $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: host.superview)
                return host.hitTest(midpoint) === $0
            }) else { throw NSError(domain: "WindowChrome", code: 1, userInfo: [NSLocalizedDescriptionKey: "wide/compact toolbar has no usable drag area"]) }
            area.doubleClickPreference = { "Maximize" }
            try chromeExpect(area.convert(area.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 0.5,
                             "custom toolbar escaped the content safe area into the native title-bar band")
            try chromeExpect(area.bounds.height >= 40, "only a thin strip of the toolbar is clickable")
            for fraction in [0.05, 0.5, 0.95] {
                let point = area.convert(NSPoint(x: area.bounds.width * fraction, y: area.bounds.midY), to: nil)
                let zooms = window.zooms
                area.mouseDown(with: chromeEvent(window, point))
                try chromeExpect(window.zooms == zooms + 1, "double-click in blank toolbar space did not zoom exactly once")
            }
            let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
            area.mouseDown(with: chromeEvent(window, point, clicks: 1))
            try chromeExpect(window.drags > 0, "toolbar blank space does not drag the window")
            let zooms = window.zooms
            area.mouseDown(with: chromeEvent(window, point, clicks: 3))
            try chromeExpect(window.zooms == zooms, "triple-click zoomed twice")
            let toolbarMidpoint = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: host)
            let menuPoint = host.convert(NSPoint(x: 20, y: toolbarMidpoint.y), to: host.superview)
            try chromeExpect(!(host.hitTest(menuPoint) is WindowDragView), "drag area intercepted a toolbar button")
        }
        print("Wide and compact toolbar: blank space zooms once, drags, and excludes buttons")
    }
}

func checkWindowTitlebarDoubleClick() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let window = ChromeProbeWindow(contentRect: NSRect(x: 20, y: 20, width: 980, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 200))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let y = (window.contentLayoutRect.maxY + window.frame.height) / 2
        for x in [140.0, 500.0, 950.0] {
            let before = window.zooms
            try chromeExpect(WindowTitlebarDoubleClick.handle(chromeEvent(window, NSPoint(x: x, y: y)), in: window, preference: "Maximize"),
                             "double-click did not cover the full native title bar")
            try chromeExpect(window.zooms == before + 1, "native title-bar click was not consumed exactly once")
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            try chromeExpect(!WindowTitlebarDoubleClick.handle(chromeEvent(window, point), in: window, preference: "Maximize"),
                             "title-bar handler intercepted a window control")
        }
        let contentPoint = NSPoint(x: 500, y: window.contentLayoutRect.midY)
        try chromeExpect(!WindowTitlebarDoubleClick.handle(chromeEvent(window, contentPoint), in: window, preference: "Maximize"),
                         "title-bar handler stole terminal/content double-clicks")
        try chromeExpect(!WindowTitlebarDoubleClick.handle(chromeEvent(window, NSPoint(x: 500, y: y), clicks: 1), in: window, preference: "Maximize"),
                         "title-bar handler stole ordinary window dragging")
        let other = ChromeProbeWindow(contentRect: NSRect(x: 30, y: 30, width: 980, height: 200),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        try chromeExpect(!WindowTitlebarDoubleClick.handle(chromeEvent(other, NSPoint(x: 500, y: y)), in: window, preference: "Maximize"),
                         "title-bar monitor handled a different window")
        print("Native title bar: full-width double-click coverage; controls, content and other windows excluded")
    }
}

func checkWindowTitlebarPreferences() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let window = ChromeProbeWindow(contentRect: NSRect(x: 20, y: 20, width: 600, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let area = WindowDragView(frame: NSRect(x: 100, y: 20, width: 300, height: 42))
        window.contentView?.addSubview(area)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let top = NSPoint(x: 300, y: (window.contentLayoutRect.maxY + window.frame.height) / 2)
        let toolbar = area.convert(NSPoint(x: 100, y: 21), to: nil)
        let cases: [(String?, Int, Int, Bool)] = [
            (nil, 1, 0, true), ("Maximize", 1, 0, true), ("Fill", 1, 0, true),
            ("Minimize", 0, 1, true), ("None", 0, 0, false), ("Unknown", 0, 0, false),
        ]
        for (preference, zooms, minimizes, handled) in cases {
            let oldZooms = window.zooms
            let oldMinimizes = window.minimizes
            let consumed = WindowTitlebarDoubleClick.handle(chromeEvent(window, top), in: window, preference: preference)
            try chromeExpect(consumed == handled && window.zooms - oldZooms == zooms && window.minimizes - oldMinimizes == minimizes,
                             "native title bar ignored the \(preference ?? "default") double-click preference")
            area.doubleClickPreference = { preference }
            let beforeToolbarZooms = window.zooms
            let beforeToolbarMinimizes = window.minimizes
            area.mouseDown(with: chromeEvent(window, toolbar))
            try chromeExpect(window.zooms - beforeToolbarZooms == zooms && window.minimizes - beforeToolbarMinimizes == minimizes,
                             "toolbar ignored the \(preference ?? "default") double-click preference")
        }
        print("Both chrome paths honour default, Maximize, Fill, Minimize and None without changing system preferences")
    }
}
