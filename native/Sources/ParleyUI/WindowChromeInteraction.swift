import AppKit
import SwiftUI

/// An explicit empty toolbar region, separate from buttons and terminal input.
public struct WindowDragArea: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> WindowDragView {
        let view = WindowDragView()
        view.setAccessibilityElement(false)
        return view
    }
    public func updateNSView(_ view: WindowDragView, context: Context) {}
}

@MainActor
public final class WindowDragView: NSView {
    public var doubleClickPreference: () -> String? = {
        UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        guard let window, event.window === window, event.type == .leftMouseDown,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if event.clickCount == 2 {
            guard window.styleMask.contains(.resizable),
                  !window.styleMask.contains(.fullScreen) else { return }
            _ = WindowTitlebarAction.perform(in: window, preference: doubleClickPreference())
        } else if event.clickCount == 1, window.isMovable {
            window.performDrag(with: event)
        }
    }
}

/// Handles only unused native title-bar space, using public window geometry.
/// The caller consumes a handled event so AppKit cannot apply a second zoom.
@MainActor
public enum WindowTitlebarDoubleClick {
    public static func handle(_ event: NSEvent, in window: NSWindow,
                              preference: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) -> Bool {
        guard event.window === window, event.type == .leftMouseDown, event.clickCount == 2,
              window.styleMask.contains(.resizable), !window.styleMask.contains(.fullScreen),
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        let point = event.locationInWindow
        guard NSRect(origin: .zero, size: window.frame.size).contains(point),
              point.y >= window.contentLayoutRect.maxY else { return false }

        func contains(_ view: NSView?) -> Bool {
            guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton, .toolbarButton] {
            if contains(window.standardWindowButton(kind)) { return false }
        }
        // A SwiftUI-backed toolbar control need not be an NSControl. Exclude
        // each complete public toolbar item and accessory view as well.
        for item in window.toolbar?.visibleItems ?? [] {
            if contains(item.view) { return false }
        }
        for accessory in window.titlebarAccessoryViewControllers {
            if contains(accessory.view) { return false }
        }
        var hit = window.contentView?.superview?.hitTest(point)
        while let view = hit {
            if view is NSControl || view is NSTextView { return false }
            hit = view.superview
        }
        return WindowTitlebarAction.perform(in: window, preference: preference)
    }
}


/// Read at each double-click so a Settings change applies without relaunching.
/// Unknown settings are left to AppKit; no preference is ever written here.
@MainActor
public enum WindowTitlebarAction {
    public static func perform(in window: NSWindow, preference: String?) -> Bool {
        switch preference?.lowercased() {
        case nil, "maximize", "zoom", "fill":
            // Fill uses the public zoom action here; frame sizing and restore
            // stay with AppKit rather than recreating the system tiling action.
            window.performZoom(nil)
            return true
        case "minimize":
            guard window.styleMask.contains(.miniaturizable) else { return false }
            window.performMiniaturize(nil)
            return true
        default:
            return false
        }
    }
}
