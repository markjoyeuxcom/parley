import AppKit
import ParleyCore
import SwiftUI

struct AboutView: View {
    let runtime: ParleyRuntime
    let information: ParleyBuildInformation
    let updateChannel: UpdateChannel

    @State private var copied = false

    init(runtime: ParleyRuntime, updateChannel: UpdateChannel) {
        self.runtime = runtime
        self.updateChannel = updateChannel
        information = .current(runtime: runtime)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBanner(runtime: runtime)

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 68, height: 68)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Parley")
                            .font(.system(size: 26, weight: .semibold))
                        Text("A native macOS workbench for cross-vendor AI CLI collaboration.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    buildRow("Version", information.applicationVersion)
                    buildRow("Build", information.buildNumber)
                    buildRow("Source", information.sourceSummary)
                    buildRow("Runtime", runtime.mode.label)
                    buildRow("Data", runtime.applicationDirectory.path)
                    buildRow("tmux", runtime.tmuxSessionName)
                    buildRow("Architecture", information.architecture)
                    buildRow("macOS", information.operatingSystem)
                    buildRow("Agent protocol", "v\(AgentProtocol.version)")
                    buildRow("Core contract", "v\(CoreServiceIdentity.currentContractVersion)")
                    buildRow("Update channel", updateChannel.label)
                    buildRow("Executable", information.executablePath)
                }
                .textSelection(.enabled)

                Divider()

                HStack {
                    Text("Copyright © 2026 Mark Joyeux")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if copied {
                        Text("Copied")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Button("Copy Build Info") { copyBuildInformation() }
                }
            }
            .padding(24)
        }
        .frame(width: 650)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.title == "About Parley" })?
                    .makeKeyAndOrderFront(nil)
            }
        }
    }

    @ViewBuilder
    private func buildRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyBuildInformation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            information.copyableText + "\nUpdate channel: \(updateChannel.label)",
            forType: .string
        )
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
