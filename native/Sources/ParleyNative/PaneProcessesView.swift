import AppKit
import Combine
import ParleyCore
import ParleyUI
import SwiftUI

/// Pane-to-process attribution and basic resource figures inside Status
/// Center's Health section. Sampling runs only while this content is mounted
/// in an active auxiliary window; switching section or closing the window
/// stops it.
struct PaneProcessesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showProcesses = true
    @State private var autoRefresh = true
    // Owned by this mounted content; invalidated when the section or window closes.
    @StateObject private var refreshClock = AuxiliaryWindowClock(interval: 2)
    @Environment(\.auxiliaryWindowActive) private var windowActive

    private var snapshot: TaskManagerSnapshot? { model.taskManagerSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            Divider()
            columnHeader
            Divider()
            processList
                .frame(minHeight: 220, maxHeight: 440)
            Divider()
            footer
        }
        .onAppear {
            model.setPaneProcessSamplingActive(windowActive)
            if windowActive { refreshClock.start { if autoRefresh { model.refreshTaskManager() } } }
        }
        .onChange(of: windowActive) { _, active in
            model.setPaneProcessSamplingActive(active)
            if active { refreshClock.start { if autoRefresh { model.refreshTaskManager() } } } else { refreshClock.stop() }
        }
        .onDisappear {
            refreshClock.stop()
            model.setPaneProcessSamplingActive(false)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("Parley-owned panes and their live process trees")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Processes", isOn: $showProcesses)
                .toggleStyle(.checkbox)
                .help("Show each pane's live process tree beneath its row")
                .accessibilityLabel("Show process trees")
            Toggle("Auto Refresh", isOn: $autoRefresh)
                .toggleStyle(.checkbox)
                .help("Resample process facts on a timer while this section is visible")
                .accessibilityLabel("Refresh automatically")
            Button {
                model.refreshTaskManagerManually()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Resample pane processes now and refresh sidebar listeners immediately")
            .accessibilityLabel("Refresh now")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var summary: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
            metric("CPU", cpuText(snapshot?.totalCPUPercent), "Sampled total")
            metric("App RSS", bytes(snapshot?.application?.residentBytes), "Parley UI")
            metric("Pane RSS", bytes(snapshot?.childResidentBytes), "Owned processes")
            metric("Processes", snapshot.map { String($0.processCount) } ?? "—", "App + panes")
            metric("Updated", snapshot.map { timeText($0.sampledAt) } ?? "—", autoRefresh ? "Every 2 seconds" : "Manual")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func metric(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU")
                .frame(width: 60, alignment: .trailing)
            Text("Memory")
                .frame(width: 80, alignment: .trailing)
            Text("PID / Proc")
                .frame(width: 60, alignment: .trailing)
            Color.clear.frame(width: 28, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var processList: some View {
        if let snapshot {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    sectionLabel("PARLEY")
                    if let application = snapshot.application {
                        applicationRow(application)
                    } else {
                        unavailableRow("The Parley process sample is unavailable.")
                    }

                    sectionLabel("PROGRAM TOTALS")
                    if snapshot.programTotals.isEmpty {
                        unavailableRow("No live pane processes are currently attributed.")
                    } else {
                        ForEach(snapshot.programTotals) { total in
                            programRow(total)
                        }
                    }

                    sectionLabel("WORKSPACE HIERARCHY")
                    if snapshot.workspaces.isEmpty {
                        unavailableRow("No workspaces are open.")
                    } else {
                        ForEach(snapshot.workspaces) { workspace in
                            workspaceRow(workspace)
                            ForEach(workspace.panes) { pane in
                                paneRow(pane)
                                if showProcesses {
                                    ForEach(pane.processes) { process in
                                        processRow(process)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Collecting Process Information",
                systemImage: "gauge.with.dots.needle.50percent",
                description: Text("CPU becomes available after the second sample.")
            )
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func applicationRow(_ application: TaskManagerApplicationSnapshot) -> some View {
        taskRow(
            icon: "macwindow",
            iconColor: .accentColor,
            title: application.name,
            subtitle: "Parley application process",
            cpu: application.cpuPercent,
            memory: application.residentBytes,
            trailing: String(application.pid),
            leadingPadding: 12
        )
    }

    private func programRow(_ total: TaskManagerProgramTotal) -> some View {
        taskRow(
            icon: "gearshape.2",
            iconColor: .accentColor,
            title: total.name,
            subtitle: "\(total.processCount) \(total.processCount == 1 ? "process" : "processes")",
            cpu: total.cpuPercent,
            memory: total.residentBytes,
            trailing: String(total.processCount),
            leadingPadding: 12
        )
    }

    private func workspaceRow(_ workspace: TaskManagerWorkspaceSnapshot) -> some View {
        taskRow(
            icon: "square.stack.3d.up",
            iconColor: workspace.isSelected ? .accentColor : .secondary,
            title: workspace.name,
            subtitle: "\(workspace.panes.count) \(workspace.panes.count == 1 ? "pane" : "panes")",
            cpu: workspace.cpuPercent,
            memory: workspace.residentBytes,
            trailing: String(workspace.processCount),
            leadingPadding: 12,
            emphasized: true
        )
    }

    private func paneRow(_ pane: TaskManagerPaneSnapshot) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: paneIcon(pane.kind))
                    .foregroundStyle(pane.isStarted ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(pane.paneName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if pane.isSelected {
                            Text("SELECTED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        if !pane.isStarted {
                            Text("STOPPED")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(paneSubtitle(pane))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(cpuText(pane.cpuPercent))
                .frame(width: 60, alignment: .trailing)
            Text(bytes(pane.residentBytes))
                .frame(width: 80, alignment: .trailing)
            Text(String(pane.processCount))
                .frame(width: 60, alignment: .trailing)
            Menu {
                Button("Focus Pane") { focus(pane) }
                Button("Copy Diagnostics") { model.copyTaskManagerDiagnostics(pane) }
                Divider()
                Button("Send Control-C…") { model.interruptFromTaskManager(pane.paneID) }
                    .disabled(!pane.isStarted)
                if let livePane = model.panes.first(where: { $0.id == pane.paneID }) {
                    Button("Restart Pane…") { model.restart(livePane) }
                    Button("Close Pane…", role: .destructive) { model.close(livePane) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .accessibilityLabel("Actions for \(pane.paneName)")
            .help("Focus, copy diagnostics, interrupt, restart or close this pane")
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(pane.isSelected ? Color.accentColor.opacity(0.09) : Color.clear)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 28) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { focus(pane) }
        .contextMenu {
            Button("Focus Pane") { focus(pane) }
            Button("Copy Diagnostics") { model.copyTaskManagerDiagnostics(pane) }
            Divider()
            Button("Send Control-C…") { model.interruptFromTaskManager(pane.paneID) }
                .disabled(!pane.isStarted)
        }
    }

    private func processRow(_ process: TaskManagerProcessSample) -> some View {
        taskRow(
            icon: "terminal",
            iconColor: .secondary,
            title: process.name,
            subtitle: "PID \(process.pid) · parent \(process.parentPID)",
            cpu: process.cpuPercent,
            memory: process.residentBytes,
            trailing: String(process.pid),
            leadingPadding: CGFloat(44 + process.depth * 12)
        )
    }

    private func unavailableRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func taskRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        cpu: Double?,
        memory: UInt64,
        trailing: String,
        leadingPadding: CGFloat,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(emphasized ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(cpuText(cpu))
                .frame(width: 60, alignment: .trailing)
            Text(bytes(memory))
                .frame(width: 80, alignment: .trailing)
            Text(trailing)
                .frame(width: 60, alignment: .trailing)
            Color.clear.frame(width: 28, height: 1)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.leading, leadingPadding)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().padding(.leading, leadingPadding) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("Only processes owned by Parley or attributed to a live Ghostty pane are shown. CPU requires two samples; RSS totals can include shared memory pages.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func focus(_ paneSnapshot: TaskManagerPaneSnapshot) {
        guard let pane = model.panes.first(where: { $0.id == paneSnapshot.paneID }) else { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { model.select(pane) }
    }

    private func paneSubtitle(_ pane: TaskManagerPaneSnapshot) -> String {
        let folder = URL(fileURLWithPath: pane.workingDirectory).lastPathComponent
        if let ttyName = pane.ttyName {
            return "\(pane.kind.label) · \(folder) · \(URL(fileURLWithPath: ttyName).lastPathComponent)"
        }
        switch pane.anchorSource {
        case .paneMarker:
            return "\(pane.kind.label) · \(folder) · anchored by pane marker"
        case .ghostty, .unavailable:
            return "\(pane.kind.label) · \(folder)"
        }
    }

    private func paneIcon(_ kind: PaneKind) -> String {
        switch kind {
        case .shell: "terminal"
        case .claude, .codex, .agy, .copilot: "cpu"
        }
    }

    private func cpuText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
