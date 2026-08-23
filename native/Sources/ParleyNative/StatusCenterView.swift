import ParleyCore
import SwiftUI

struct StatusCenterView: View {
    @ObservedObject var model: AppModel
    @State private var workspaceID = ""
    @State private var selectedHandoffID: String?
    @State private var showDismissed = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var snapshot: StatusCenterSnapshot {
        model.statusSnapshot(
            workspaceID: workspaceID.isEmpty ? nil : workspaceID,
            includeDismissed: showDismissed
        )
    }

    private var selectedHandoff: RelayHandoff? {
        snapshot.handoffs.first(where: { $0.id == selectedHandoffID })
    }

    var body: some View {
        VStack(spacing: 0) {
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
                            agents
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
            ensureSelection()
        }
        .onReceive(refresh) { _ in
            model.refreshStatusCenterQuietly()
            ensureSelection()
        }
        .onChange(of: workspaceID) { _, _ in
            selectedHandoffID = nil
            ensureSelection()
        }
        .onChange(of: showDismissed) { _, _ in
            selectedHandoffID = nil
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

    private var coreHealth: some View {
        statusGroup("CORE HEALTH") {
            VStack(spacing: 7) {
                healthRow("Coordination core", model.coreAvailable ? "CONNECTED" : "UNAVAILABLE", healthy: model.coreAvailable)
                healthRow("tmux workspace server", model.tmuxAvailable ? "CONNECTED" : "UNAVAILABLE", healthy: model.tmuxAvailable)
                healthRow("Shared pane protocol", "V\(AgentProtocol.version)", healthy: true)
                healthRow("Handoffs in scope", snapshot.handoffs.count.formatted(), healthy: true)
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let controller = model.controller {
                            Text("tmux socket: \(controller.socketPath.path)")
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
        if let handoff = selectedHandoff {
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
                if let consultation = model.consultation(for: handoff) {
                    Button("Return Manually…") { model.returnConsultation(consultation) }
                    Button("Cancel Wait…", role: .destructive) { model.cancel(consultation) }
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
            }
        }
        .controlSize(.small)
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
        if let selectedHandoffID,
           let selected = snapshot.handoffs.first(where: { $0.id == selectedHandoffID }) {
            if selected.hasUnreadResult { model.markRead(selected) }
            return
        }
        if let first = snapshot.handoffs.first { select(first) }
    }

    private func select(_ handoff: RelayHandoff) {
        selectedHandoffID = handoff.id
        if handoff.hasUnreadResult { model.markRead(handoff) }
    }
}
