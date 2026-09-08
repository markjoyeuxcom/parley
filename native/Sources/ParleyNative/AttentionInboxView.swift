import AppKit
import ParleyCore
import SwiftUI

struct AttentionInboxMenuBarLabel: View {
    @ObservedObject var model: AppModel

    private var summary: MenuBarAttentionSummary { model.menuBarAttentionSummary }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if let marker = model.runtime.visibleMarker {
                Text(marker)
            }
            if summary.totalCount > 0 {
                Text(summary.totalCount > 999 ? "999+" : "\(summary.totalCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        if !summary.coreAvailable { return "bell.slash" }
        return summary.totalCount > 0 ? "bell.badge" : "bell"
    }

    private var accessibilityLabel: String {
        let runtime = model.runtime.visibleMarker.map { ", \($0) runtime" } ?? ""
        return "Parley attention indicator\(runtime), \(summary.headline)"
    }
}

struct AttentionInboxMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var summary: MenuBarAttentionSummary { model.menuBarAttentionSummary }

    var body: some View {
        Text(summary.headline)
        if !summary.coreAvailable {
            Text("The coordination core is disconnected.")
        }
        Divider()
        Button("Open Parley") { presentWindow(id: "main", title: "Parley") }
        Button("Open Status Center") {
            model.refreshStatusCenterQuietly()
            presentWindow(id: "status-center", title: "Status Center")
        }
        Divider()
        Button("Quit Parley") { NSApp.terminate(nil) }
    }

    private func presentWindow(id: String, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == title && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: id)
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.title == title && $0.canBecomeKey })?
                .makeKeyAndOrderFront(nil)
        }
    }
}
