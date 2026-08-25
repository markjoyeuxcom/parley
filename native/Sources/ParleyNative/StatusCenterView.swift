import ParleyCore
import SwiftUI

struct StatusCenterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var workspaceID = ""
    @State private var selectedHandoffID: String?
    @State private var selectedChainID: String?
    @State private var showDismissed = false
    // Do not rebuild an open AppKit menu while it is tracking the pointer.
    private let refresh = Timer.publish(
        every: 2,
        on: .main,
        in: MenuTrackingRefreshPolicy.runLoopMode
    ).autoconnect()

    private var snapshot: StatusCenterSnapshot {
        model.statusSnapshot(
            workspaceID: workspaceID.isEmpty ? nil : workspaceID,
            includeDismissed: showDismissed
        )
    }

    private var selectedHandoff: RelayHandoff? {
        guard selectedChainID == nil else { return nil }
        return snapshot.handoffs.first(where: { $0.id == selectedHandoffID })
    }

    private var scopedChains: [HandoffChain] {
        model.statusHandoffChains(workspaceID: workspaceID.isEmpty ? nil : workspaceID)
    }

    private var selectedChain: HandoffChain? {
        guard let selectedChainID else { return nil }
        return scopedChains.first(where: { $0.id == selectedChainID })
    }

    private var recoveryIssues: [RecoveryGuidanceIssue] {
        RecoveryGuidanceProjection.issues(
            coreAvailable: model.coreAvailable,
            readiness: model.runtimeReadiness,
            panes: model.panes,
            handoffs: snapshot.handoffs,
            workspaceID: workspaceID.isEmpty ? nil : workspaceID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBanner(runtime: model.runtime)
            if model.runtime.visibleMarker != nil { Divider() }
            header
            Divider()
            countStrip
            Divider()
            HSplitView {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Color.clear.frame(height: 0).id("status-overview-top")
                            liveCollaboration
                            returnedResults
                            handoffChains
                            agents
                            recovery
                            coreHealth
                        }
                        .padding(16)
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            reader.scrollTo("status-overview-top", anchor: .top)
                        }
                    }
                    .onChange(of: workspaceID) { _, _ in
                        reader.scrollTo("status-overview-top", anchor: .top)
                    }
                }
                .frame(minWidth: 520, idealWidth: 650)

                inspector
                    .frame(minWidth: 330, idealWidth: 430)
            }
            Divider()
            timeline
                .frame(minHeight: 170, idealHeight: 220, maxHeight: 280)
        }
        .frame(minWidth: 980, minHeight: 700)
        .onAppear {
            model.refreshStatusCenterQuietly()
            model.refreshRuntimeReadiness()
            applyExternalSelection()
            ensureSelection()
        }
        .onReceive(refresh) { _ in
            model.refreshStatusCenterQuietly()
            applyExternalSelection()
            ensureSelection()
        }
        .onChange(of: model.requestedStatusHandoffID) { _, _ in
            applyExternalSelection()
        }
        .onChange(of: workspaceID) { _, _ in
            selectedHandoffID = nil
            selectedChainID = nil
            ensureSelection()
        }
        .onChange(of: showDismissed) { _, _ in
            selectedHandoffID = nil
            selectedChainID = nil
            applyExternalSelection()
            ensureSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(conditionColor)
                .frame(width: 4, height: 36)
                .accessibilityHidden(true)
            Image(systemName: conditionIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(conditionColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(conditionTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(conditionDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityRepresentation {
                Text("Status Center condition. \(conditionTitle). \(conditionDetail)")
            }
            Spacer()
            Button {
                model.exportDiagnostics()
            } label: {
                if model.diagnosticsExporting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(model.diagnosticsExporting)
            .accessibilityLabel(model.diagnosticsExporting ? "Exporting diagnostics" : "Export diagnostics")
            .accessibilityHint("Save a local ZIP containing health and process state without prompts, answers, terminal contents, names, folders, credentials, journals, or logs")
            .help("Export privacy-bounded local diagnostics")
            Menu {
                if model.workspaces.isEmpty {
                    Text("No workspaces")
                } else {
                    Section("Notify when a result returns or attention is required") {
                        ForEach(model.workspaces) { workspace in
                            Toggle(
                                workspace.name,
                                isOn: Binding(
                                    get: { model.notificationsEnabled(for: workspace) },
                                    set: { model.setNotificationsEnabled($0, for: workspace) }
                                )
                            )
                        }
                    }
                }
            } label: {
                Image(systemName: model.notificationWorkspaceNames.isEmpty ? "bell" : "bell.badge")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Workspace notifications")
            .accessibilityValue(
                model.notificationWorkspaceNames.isEmpty
                    ? "Off for all workspaces"
                    : "On for \(model.notificationWorkspaceNames.joined(separator: ", "))"
            )
            .help("Workspace notifications are off until you enable them here")
            .accessibilityHint("Choose which workspaces may send local result and attention notifications")
            Menu {
                Toggle("Show Dismissed", isOn: $showDismissed)
                Button("Restore All Dismissed") {
                    model.restoreAllStatusCenterDismissals()
                    showDismissed = false
                    selectedHandoffID = nil
                    ensureSelection()
                }
                .disabled(model.dismissedHandoffIDs.isEmpty)
                if let workspace = model.workspaces.first(where: { $0.id == workspaceID }) {
                    Divider()
                    Button("Delete History for \(workspace.name)…", role: .destructive) {
                        if model.deleteStatusHistory(for: workspace) {
                            selectedHandoffID = nil
                            ensureSelection()
                        }
                    }
                }
            } label: {
                Image(systemName: model.dismissedHandoffIDs.isEmpty ? "archivebox" : "archivebox.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Dismissed records and history")
            .accessibilityValue(
                model.dismissedHandoffIDs.isEmpty
                    ? "No dismissed records"
                    : "\(model.dismissedHandoffIDs.count) dismissed record\(model.dismissedHandoffIDs.count == 1 ? "" : "s")"
            )
            .help("Dismissed records and workspace history controls")
            .accessibilityHint("Show or restore dismissed records, or delete history for the selected workspace")
            Picker("Scope", selection: $workspaceID) {
                Text("All Workspaces").tag("")
                ForEach(model.workspaces) { workspace in
                    Text(workspace.name).tag(workspace.id)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .accessibilityLabel("Status Center workspace scope")
            .accessibilityHint("Filter agents, collaboration, results, counts, and activity by workspace")
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(conditionColor.opacity(0.055))
    }

    private var countStrip: some View {
        HStack(spacing: 1) {
            countCell("RUNNING", snapshot.counts.runningAgents)
            countCell("STOPPED", snapshot.counts.stoppedAgents)
            countCell("QUESTIONS", snapshot.counts.outstandingQuestions)
            countCell("DELEGATIONS", snapshot.counts.trackedDelegations)
            countCell("RESULTS", snapshot.counts.unreadResults)
            countCell("FAILURES", snapshot.counts.failures, warning: snapshot.counts.failures > 0)
        }
        .background(Color.secondary.opacity(0.11))
        .frame(height: 58)
        .accessibilityRepresentation {
            Text("Status Center totals. \(WorkbenchAccessibility.counts(snapshot.counts))")
        }
    }

    private func countCell(_ label: String, _ value: Int, warning: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(warning ? Color.red : Color.primary)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var liveCollaboration: some View {
        statusGroup("LIVE COLLABORATION") {
            if snapshot.activeHandoffs.isEmpty {
                emptyRow("No active handoffs in this scope")
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.activeHandoffs) { handoff in
                        handoffRow(handoff)
                        if handoff.id != snapshot.activeHandoffs.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func handoffRow(_ handoff: RelayHandoff) -> some View {
        Button {
            select(handoff)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(handoff.sourceName)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(handoff.targetName)
                    }
                    .font(.system(size: 11, weight: .medium))
                    Text(subject(handoff.text))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(handoff.kind.rawValue.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(handoff.state.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(stateColor(handoff))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(activityTiming(handoff, at: context.date))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedHandoffID == handoff.id ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Button(WorkbenchAccessibility.handoff(handoff)) {
                select(handoff)
            }
            .accessibilityValue(selectedHandoffID == handoff.id ? "Selected" : "Not selected")
            .accessibilityHint("Inspect this collaboration record")
        }
    }

    private var returnedResults: some View {
        let unread = snapshot.handoffs.filter { handoff in
            handoff.hasUnreadResult
                && (workspaceID.isEmpty || handoff.sourceWorkspaceID == workspaceID)
        }
        return statusGroup("RETURNED RESULTS") {
            if unread.isEmpty {
                emptyRow("No unread returned results in this scope")
            } else {
                VStack(spacing: 0) {
                    ForEach(unread) { handoff in
                        handoffRow(handoff)
                        if handoff.id != unread.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var handoffChains: some View {
        statusGroup("HANDOFF CHAINS") {
            if scopedChains.isEmpty {
                emptyRow("No curated handoff chains in this scope")
            } else {
                VStack(spacing: 0) {
                    ForEach(scopedChains) { chain in
                        Button {
                            select(chain)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chain.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(chain.entries.count) handoff\(chain.entries.count == 1 ? "" : "s") · \(chain.bookmarks.count) bookmark\(chain.bookmarks.count == 1 ? "" : "s")")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(chain.updatedAt, style: .relative)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selectedChainID == chain.id ? Color.accentColor.opacity(0.10) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Handoff chain \(chain.title), \(chain.entries.count) handoffs, \(chain.bookmarks.count) bookmarks")
                        .accessibilityValue(selectedChainID == chain.id ? "Selected" : "Not selected")
                        if chain.id != scopedChains.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var agents: some View {
        statusGroup("AGENTS") {
            if snapshot.agents.isEmpty {
                emptyRow("No agent panes in this scope")
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.agents) { pane in
                        agentRow(pane)
                        if pane.id != snapshot.agents.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func agentRow(_ pane: TmuxPane) -> some View {
        let work = snapshot.activeHandoffs.first(where: { $0.targetPaneID == pane.id })
        let attention = snapshot.handoffs.first(where: { $0.targetPaneID == pane.id && $0.attention != nil })
        return HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(processColor(pane))
                    .frame(width: 4, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(pane.displayName)
                            .font(.system(size: 11, weight: .medium))
                        Text(pane.kind.label.uppercased())
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let role = pane.role {
                            Text("@\(role)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        if attention != nil {
                            Text("ATTENTION")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    Text(work.map { subject($0.text) } ?? "No tracked work")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(processState(pane))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    Text(pane.workspaceName ?? pane.windowID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(protocolLabel(pane))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(protocolColor(pane))
                    Text(readiness(pane))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(readinessColor(pane))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityRepresentation {
                Text(
                    "\(WorkbenchAccessibility.agent(pane)). \(agentAccessibilityValue(work: work, needsAttention: attention != nil))"
                )
            }
            Button("Focus") { model.select(pane) }
                .controlSize(.small)
                .accessibilityLabel("Focus \(pane.displayName)")
                .accessibilityHint("Open this pane in the main Parley window")
        }
        .padding(9)
    }

    private func agentAccessibilityValue(work: RelayHandoff?, needsAttention: Bool) -> String {
        var parts = [work.map { "Tracked work: \(subject($0.text))" } ?? "No tracked work"]
        if needsAttention { parts.append("Attention required") }
        return parts.joined(separator: ". ")
    }

    private var recovery: some View {
        statusGroup("RECOVERY") {
            VStack(spacing: 0) {
                if recoveryIssues.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Color.green)
                            .accessibilityHidden(true)
                        Text("No active recovery is required in this scope")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(10)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(Array(recoveryIssues.enumerated()), id: \.element.id) { index, issue in
                        recoveryRow(issue)
                        if index < recoveryIssues.count - 1 { Divider() }
                    }
                }
                Divider()
                recoveryPlaybook
            }
        }
    }

    private func recoveryRow(_ issue: RecoveryGuidanceIssue) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: recoveryIcon(issue.topic))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(recoveryColor(issue.topic))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(issue.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button(issue.actionLabel) {
                performRecovery(issue.action)
            }
            .controlSize(.small)
            .disabled(!canPerformRecovery(issue.action))
            .accessibilityHint(recoveryActionHint(issue.action))
        }
        .padding(9)
        .accessibilityElement(children: .contain)
    }

    private var recoveryPlaybook: some View {
        DisclosureGroup("Recovery playbook · 5 known cases") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(RecoveryGuidanceProjection.playbook.enumerated()), id: \.element.id) { index, entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Image(systemName: recoveryIcon(entry.topic))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Text(entry.title)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(entry.symptom)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(entry.steps.enumerated()), id: \.offset) { step, text in
                            Text("\(step + 1). \(text)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    if index < RecoveryGuidanceProjection.playbook.count - 1 { Divider() }
                }
            }
            .padding(.leading, 4)
            .padding(.top, 5)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(10)
        .accessibilityHint("Expand to read safe recovery steps that do not require repository or development commands")
    }

    private func performRecovery(_ action: RecoveryGuidanceAction) {
        switch action {
        case .reconnect:
            model.retryConnections()
        case .refreshEnvironment:
            model.showEnvironmentCheck()
        case let .restartPane(paneID):
            guard let pane = model.panes.first(where: { $0.id == paneID }) else { return }
            model.restart(pane)
        case let .inspectHandoff(handoffID):
            guard let handoff = snapshot.handoffs.first(where: { $0.id == handoffID }) else { return }
            select(handoff)
        }
    }

    private func canPerformRecovery(_ action: RecoveryGuidanceAction) -> Bool {
        switch action {
        case .reconnect:
            model.canRetryConnections
        case .refreshEnvironment:
            !model.runtimeReadinessChecking
        case let .restartPane(paneID):
            model.panes.contains(where: { $0.id == paneID })
        case let .inspectHandoff(handoffID):
            snapshot.handoffs.contains(where: { $0.id == handoffID })
        }
    }

    private func recoveryActionHint(_ action: RecoveryGuidanceAction) -> String {
        switch action {
        case .reconnect:
            "Reconnect the existing UI to Parley's local core without restarting terminal panes"
        case .refreshEnvironment:
            "Open the quota-free environment check for local tools and vendor sign-in"
        case .restartPane:
            "Confirm before ending and relaunching only this pane's process"
        case .inspectHandoff:
            "Show the durable handoff and its final delivery receipt in the inspector"
        }
    }

    private func recoveryIcon(_ topic: RecoveryGuidanceTopic) -> String {
        switch topic {
        case .damagedSocket: "link.badge.plus"
        case .missingCLI: "terminal"
        case .staleProtocol: "arrow.triangle.2.circlepath.circle"
        case .deadPane: "xmark.circle"
        case .interruptedConsultation: "bolt.horizontal.circle"
        }
    }

    private func recoveryColor(_ topic: RecoveryGuidanceTopic) -> Color {
        switch topic {
        case .missingCLI: .secondary
        case .damagedSocket, .staleProtocol, .deadPane, .interruptedConsultation: .orange
        }
    }

    private var coreHealth: some View {
        statusGroup("CORE HEALTH") {
            VStack(spacing: 7) {
                healthRow("Coordination core", model.coreAvailable ? "CONNECTED" : "UNAVAILABLE", healthy: model.coreAvailable)
                if model.coreUpgradePending {
                    HStack {
                        Text("Core upgrade").font(.system(size: 10))
                        Spacer()
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("PENDING")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityRepresentation { Text("Core upgrade, pending") }
                }
                healthRow("tmux workspace server", model.tmuxAvailable ? "CONNECTED" : "UNAVAILABLE", healthy: model.tmuxAvailable)
                healthRow("Shared pane protocol", "V\(AgentProtocol.version)", healthy: true)
                healthRow("Handoffs in scope", snapshot.handoffs.count.formatted(), healthy: true)
                Divider()
                coreLoginItemControl
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let controller = model.controller {
                            Text("tmux socket: \(controller.socketPath.path)")
                        }
                        if let message = model.coreUpgradeMessage {
                            Text("core upgrade: \(message)")
                        }
                        Text("Only local, owner-authenticated state is shown. Prompt bodies and credentials are never exported from this window.")
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                }
                .font(.system(size: 10))
            }
            .padding(9)
        }
    }

    private var coreLoginItemControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle(
                    "Keep coordination core available at login",
                    isOn: Binding(
                        get: { model.coreLoginItemRequested },
                        set: { requested in model.setCoreLoginItemRequested(requested) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.canChangeCoreLoginItem)
                Spacer()
                if model.coreLoginItemChanging {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Changing launch at login")
                }
                Text(coreLoginItemLabel)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(coreLoginItemColor)
            }
            Text(coreLoginItemDetail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.coreLoginItemState == .requiresApproval {
                Button("Open Login Items Settings…") {
                    model.openCoreLoginItemSettings()
                }
                .controlSize(.small)
                .accessibilityHint("Open macOS System Settings to approve or disable Parley's background core")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var coreLoginItemLabel: String {
        if model.coreLoginItemChanging { return "CHANGING" }
        return switch model.coreLoginItemState {
        case .disabled: "OFF"
        case .enabled: "ENABLED"
        case .requiresApproval: "APPROVAL REQUIRED"
        case .unavailable: "PACKAGED APP ONLY"
        }
    }

    private var coreLoginItemDetail: String {
        switch model.coreLoginItemState {
        case .disabled:
            "Off by default. Enabling starts only Parley's local coordination core at login; the window, tmux workspace and vendor CLIs remain closed."
        case .enabled:
            "macOS may start the bundled coordination core at login. It waits without creating a workspace until you open Parley."
        case .requiresApproval:
            "The service is registered, but macOS requires approval in Login Items before it may run."
        case .unavailable:
            "Install and open the packaged Parley.app to manage its bundled core LaunchAgent."
        }
    }

    private var coreLoginItemColor: Color {
        switch model.coreLoginItemState {
        case .enabled: .green
        case .requiresApproval: .orange
        case .disabled, .unavailable: .secondary
        }
    }

    private func healthRow(_ name: String, _ value: String, healthy: Bool) -> some View {
        HStack {
            Text(name).font(.system(size: 10))
            Spacer()
            Circle()
                .fill(healthy ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityRepresentation {
            Text("\(name), \(value)")
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let chain = selectedChain {
            chainInspector(chain)
        } else if let handoff = selectedHandoff {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SELECTED ITEM")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(handoff.sourceName) → \(handoff.targetName)")
                            .font(.system(size: 16, weight: .semibold))
                        HStack(spacing: 7) {
                            statusChip(handoff.kind.rawValue.uppercased(), color: .secondary)
                            statusChip(handoff.state.rawValue.uppercased(), color: stateColor(handoff))
                            if handoff.attention != nil {
                                statusChip("ATTENTION", color: .orange)
                            }
                            if handoff.hasUnreadResult {
                                statusChip("UNREAD RESULT", color: .accentColor)
                            }
                            if model.isDismissed(handoff) {
                                statusChip("DISMISSED", color: .secondary)
                            }
                        }
                    }
                    .accessibilityRepresentation {
                        Text(
                            "\(WorkbenchAccessibility.handoff(handoff)). \(model.isDismissed(handoff) ? "Dismissed" : "In Status Center")"
                        )
                    }

                    actionControls(handoff)

                    inspectorSection(handoff.kind == .delegate ? "INSTRUCTION" : "QUESTION OR MESSAGE", handoff.text)
                    if let result = handoff.resultText, !result.isEmpty {
                        inspectorSection("RETURNED RESULT", result)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("DELIVERY RECEIPTS")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(handoff.transitions.enumerated()), id: \.offset) { _, transition in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(transition.occurredAt.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(transition.state.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                if transition.origin == .human {
                                    Text("HUMAN")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                }
                                if let detail = transition.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityRepresentation {
                                Text(receiptAccessibility(transition))
                            }
                        }
                        if let readAt = handoff.readAt {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(readAt.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("VIEWED")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            }
                            .accessibilityRepresentation {
                                Text("Result viewed at \(readAt.formatted(date: .omitted, time: .standard))")
                            }
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "No collaboration selected",
                systemImage: "arrow.left.arrow.right",
                description: Text("Choose a live handoff or timeline event to inspect its authoritative record.")
            )
        }
    }

    @ViewBuilder
    private func actionControls(_ handoff: RelayHandoff) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button("Focus Source") { model.focus(handoff, target: false) }
                    .disabled(!model.canFocus(handoff.sourcePaneID))
                Button("Focus Target") { model.focus(handoff, target: true) }
                    .disabled(!model.canFocus(handoff.targetPaneID))
            }
            HStack {
                Menu("Add to Chain") {
                    Button("Start New Chain…") {
                        if let chain = model.createHandoffChain(from: handoff) {
                            select(chain)
                        }
                    }
                    let accepting = model.chainsAccepting(handoff)
                    if !accepting.isEmpty {
                        Divider()
                        ForEach(accepting) { chain in
                            Button(chain.title) {
                                model.addHandoff(handoff, to: chain)
                                select(chain)
                            }
                        }
                    }
                }
                if handoff.hasReturnedResult {
                    let containing = model.chains(containing: handoff)
                    Menu("Bookmark Result") {
                        if containing.isEmpty {
                            Text("Add this handoff to a chain first")
                        } else {
                            ForEach(containing) { chain in
                                Menu(chain.title) {
                                    Button("As Answer") {
                                        model.bookmarkResult(from: handoff, in: chain, as: .answer)
                                        select(chain)
                                    }
                                    Button("As Objection") {
                                        model.bookmarkResult(from: handoff, in: chain, as: .objection)
                                        select(chain)
                                    }
                                }
                            }
                        }
                    }
                    .disabled(containing.isEmpty)
                }
                if let consultation = model.consultation(for: handoff) {
                    Button("Return Manually…") { model.returnConsultation(consultation) }
                    Button("Cancel Wait…", role: .destructive) { model.cancel(consultation) }
                } else if handoff.kind == .delegate,
                          [.created, .delivered, .waiting].contains(handoff.state) {
                    Button("Cancel Tracking…", role: .destructive) { model.cancel(handoff) }
                }
                if handoff.canRetrySafely {
                    Button("Retry Delivery…") { model.retry(handoff) }
                }
                if model.isDismissed(handoff) {
                    Button("Restore to Status Center") {
                        model.restoreToStatusCenter(handoff)
                    }
                } else if StatusCenterVisibility.isDismissible(handoff) {
                    Button("Dismiss Completed") {
                        model.dismissFromStatusCenter(handoff)
                        selectedHandoffID = nil
                        ensureSelection()
                    }
                }
                if let target = model.panes.first(where: { $0.id == handoff.targetPaneID }),
                   target.kind.isAgent,
                   target.isStarted,
                   !target.hasCurrentProtocol {
                    Button("Restart for Protocol…") { model.restart(target) }
                }
                if handoff.attention == .permissionRequired {
                    Button("Permission Guide") {
                        model.requestHelp(topicID: "cli-permissions")
                        openWindow(id: "help")
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func chainInspector(_ chain: HandoffChain) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("HANDOFF CHAIN")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(chain.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(chain.workspaceName) · person curated · no inferred verdict")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Add Human Decision…") {
                        model.addDecision(to: chain)
                        if let refreshed = model.handoffChains.first(where: { $0.id == chain.id }) {
                            select(refreshed)
                        }
                    }
                    Button("Delete Chain…", role: .destructive) {
                        if model.deleteHandoffChain(chain) {
                            selectedChainID = nil
                            ensureSelection()
                        }
                    }
                }
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 9) {
                    Text("RELATED HANDOFFS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(chain.entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("\(entry.sourceName) → \(entry.targetName)")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                statusChip(entry.kind.rawValue.uppercased(), color: .secondary)
                                statusChip(entry.state.rawValue.uppercased(), color: .secondary)
                            }
                            chainText("QUESTION OR INSTRUCTION", entry.prompt)
                            if let result = entry.result, !result.isEmpty {
                                chainText("RETURNED RESULT", result)
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.055))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("BOOKMARKED EVIDENCE AND DECISIONS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    if chain.bookmarks.isEmpty {
                        Text("No answers, objections or human decisions bookmarked yet.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(chain.bookmarks) { bookmark in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(bookmark.kind.label.uppercased())
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    if bookmark.origin == .human {
                                        Text("HUMAN")
                                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.accentColor)
                                    } else if let entryID = bookmark.entryID,
                                              let entry = chain.entries.first(where: { $0.id == entryID }) {
                                        Text(entry.targetName.uppercased())
                                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text(bookmark.text)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.055))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func chainText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inspectorSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.secondary.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ACTIVITY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if snapshot.timeline.isEmpty {
                emptyRow("No recorded activity in this scope")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.timeline.prefix(150)) { event in
                            timelineRow(event)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func timelineRow(_ event: StatusTimelineEvent) -> some View {
        if let handoffID = event.handoffID {
            Button {
                if let handoff = snapshot.handoffs.first(where: { $0.id == handoffID }) {
                    select(handoff)
                }
            } label: {
                timelineRowContent(event)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(timelineAccessibility(event))
            .accessibilityHint("Inspect this collaboration record")
        } else {
            timelineRowContent(event)
                .accessibilityRepresentation {
                    Text(timelineAccessibility(event))
                }
        }
    }

    private func timelineRowContent(_ event: StatusTimelineEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.occurredAt.formatted(date: .omitted, time: .standard))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(event.title)
                .font(.system(size: 10, weight: .medium))
            Text(event.category)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(event.action)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
            if event.origin == .human {
                Text("HUMAN")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func statusGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var conditionTitle: String {
        switch snapshot.condition {
        case .allClear: "All clear"
        case .resultsAvailable: "Returned results available"
        case .agentsWaiting: "Agents waiting"
        case .humanInputRequired: "Human input required"
        case .interruptedWork: "Interrupted work"
        case .coreUnavailable: "Coordination core unavailable"
        }
    }

    private var conditionDetail: String {
        switch snapshot.condition {
        case .allClear: "No active or failed cross-vendor work in this scope."
        case .resultsAvailable: "One or more Ask or Delegate results have not been viewed."
        case .agentsWaiting: "One or more tracked handoffs are still active."
        case .humanInputRequired: "A known permission, readiness, or target issue needs attention."
        case .interruptedWork: "A handoff failed or was interrupted; inspect its recorded reason."
        case .coreUnavailable: "The last authoritative collaboration state remains visible while Parley reconnects."
        }
    }

    private var conditionIcon: String {
        switch snapshot.condition {
        case .allClear: "checkmark.circle"
        case .resultsAvailable: "envelope.badge"
        case .agentsWaiting: "clock"
        case .humanInputRequired: "exclamationmark.triangle"
        case .interruptedWork: "bolt.horizontal.circle"
        case .coreUnavailable: "network.slash"
        }
    }

    private var conditionColor: Color {
        switch snapshot.condition {
        case .allClear: .green
        case .resultsAvailable: .accentColor
        case .agentsWaiting: .accentColor
        case .humanInputRequired: .orange
        case .interruptedWork, .coreUnavailable: .red
        }
    }

    private func stateColor(_ handoff: RelayHandoff) -> Color {
        if handoff.attention != nil { return .orange }
        return switch handoff.state {
        case .created, .delivered, .waiting, .answered: .accentColor
        case .failed, .interrupted: .red
        case .completed, .cancelled: .secondary
        }
    }

    private func readiness(_ pane: TmuxPane) -> String {
        switch WorkbenchStateProjection.pane(pane) {
        case .empty: return "NO PANE"
        case .stopped: return "NOT STARTED"
        case let .exited(status): return status.map { "EXITED \($0)" } ?? "EXITED"
        case .protocolStale: return "PROTOCOL STALE"
        case .relayUnavailable: return "RELAY OFF"
        case .running:
            return pane.bracketedPasteActive ? "RELAY READY" : "NOT AT PROMPT"
        }
    }

    private func readinessColor(_ pane: TmuxPane) -> Color {
        if pane.isDead { return .red }
        return WorkbenchStateProjection.pane(pane) == .running && pane.bracketedPasteActive
            ? .green : .orange
    }

    private func protocolLabel(_ pane: TmuxPane) -> String {
        switch WorkbenchStateProjection.protocolStatus(pane) {
        case .notAttached:
            return "PROTOCOL — · NOT ATTACHED"
        case let .current(version):
            return "PROTOCOL V\(version) · CURRENT"
        case let .restartRequired(reportedVersion):
            return reportedVersion.map { "PROTOCOL V\($0) · RESTART REQUIRED" }
                ?? "PROTOCOL UNKNOWN · RESTART REQUIRED"
        }
    }

    private func protocolColor(_ pane: TmuxPane) -> Color {
        switch WorkbenchStateProjection.protocolStatus(pane) {
        case .notAttached, .current: .secondary
        case .restartRequired: .orange
        }
    }

    private func processState(_ pane: TmuxPane) -> String {
        if pane.isDead { return "EXITED" }
        return pane.isStarted ? "RUNNING" : "STOPPED"
    }

    private func processColor(_ pane: TmuxPane) -> Color {
        if pane.isDead { return .red }
        return pane.isStarted ? .green : .secondary
    }

    private func subject(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private func receiptAccessibility(_ transition: RelayHandoffTransition) -> String {
        var parts = [
            transition.state.rawValue.capitalized,
            "at \(transition.occurredAt.formatted(date: .omitted, time: .standard))",
        ]
        if transition.origin == .human { parts.append("human initiated") }
        if let detail = transition.detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ". ")
    }

    private func timelineAccessibility(_ event: StatusTimelineEvent) -> String {
        "\(WorkbenchAccessibility.timeline(event)). At \(event.occurredAt.formatted(date: .omitted, time: .standard))"
    }

    private func activityTiming(_ handoff: RelayHandoff, at now: Date) -> String {
        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        let origin = terminalStates.contains(handoff.state)
            ? handoff.updatedAt
            : handoff.transitions.first?.occurredAt ?? handoff.updatedAt
        let seconds = max(0, Int(now.timeIntervalSince(origin)))
        let amount: String
        if seconds < 60 {
            amount = "\(seconds)s"
        } else if seconds < 3_600 {
            amount = "\(seconds / 60)m"
        } else {
            amount = "\(seconds / 3_600)h"
        }
        return terminalStates.contains(handoff.state) ? "\(amount) ago" : "for \(amount)"
    }

    private func ensureSelection() {
        if let selectedChainID,
           scopedChains.contains(where: { $0.id == selectedChainID }) {
            return
        }
        if let selectedHandoffID,
           let selected = snapshot.handoffs.first(where: { $0.id == selectedHandoffID }) {
            if selected.hasUnreadResult { model.markRead(selected) }
            return
        }
        if let first = snapshot.handoffs.first { select(first) }
    }

    private func applyExternalSelection() {
        guard let requested = model.requestedStatusHandoffID else { return }
        if !showDismissed {
            showDismissed = true
            return
        }
        guard let handoff = model.statusSnapshot(
                workspaceID: nil,
                includeDismissed: true
              ).handoffs.first(where: { $0.id == requested }) else { return }
        workspaceID = ""
        select(handoff)
        model.consumeRequestedStatusHandoffID()
    }

    private func select(_ handoff: RelayHandoff) {
        selectedChainID = nil
        selectedHandoffID = handoff.id
        if handoff.hasUnreadResult { model.markRead(handoff) }
    }

    private func select(_ chain: HandoffChain) {
        selectedHandoffID = nil
        selectedChainID = chain.id
    }
}
