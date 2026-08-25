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
        return "Parley attention inbox\(runtime), \(summary.headline)"
    }
}

struct AttentionInboxMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var summary: MenuBarAttentionSummary { model.menuBarAttentionSummary }

    var body: some View {
        Text(summary.headline)

        if !summary.coreAvailable {
            Text(summary.items.isEmpty
                ? "The coordination core is disconnected."
                : "Showing last known content-free items.")
        }

        if summary.items.isEmpty {
            Text(summary.coreAvailable
                ? "Nothing currently needs review."
                : "No last known attention items are available.")
        } else {
            Divider()
            ForEach(summary.items) { item in
                Button {
                    openStatusCenter(handoffID: item.handoffID)
                } label: {
                    Label(
                        "\(item.label) · \(item.workspaceName)",
                        systemImage: item.reason.systemImage
                    )
                }
            }
            if summary.hiddenItemCount > 0 {
                Button("View \(summary.hiddenItemCount) more in Status Center…") {
                    openStatusCenter()
                }
            }
        }

        Divider()
        Button("Open Parley") { presentWindow(id: "main", title: "Parley") }
        Button("Open Status Center") { openStatusCenter() }
        Divider()
        Button("Quit Parley") { NSApp.terminate(nil) }
    }

    private func openStatusCenter(handoffID: String? = nil) {
        if let handoffID,
           !model.openExternalNavigation(.handoff(handoffID)) {
            return
        } else if handoffID == nil {
            model.refreshStatusCenterQuietly()
        }
        presentWindow(id: "status-center", title: "Status Center")
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

private extension ExternalAttentionReason {
    var systemImage: String {
        switch self {
        case .returnedResult: "checkmark.circle"
        case .humanInputRequired: "hand.raised"
        case .interrupted: "exclamationmark.triangle"
        }
    }
}
