import Foundation

/// Periodic model refresh must pause while AppKit is tracking an open menu.
/// `.common` includes the event-tracking mode and causes SwiftUI to rebuild the
/// menu beneath the pointer, repeatedly dropping its highlighted item.
public enum MenuTrackingRefreshPolicy {
    public static let runLoopMode: RunLoop.Mode = .default
}
