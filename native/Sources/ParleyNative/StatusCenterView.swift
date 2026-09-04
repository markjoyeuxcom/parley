import ParleyCore
import SwiftUI

struct StatusCenterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var workspaceID = ""
    @State private var segment: StatusCenterSegment = .live
    @State private var selectedHandoffID: String?
    @State private var selectedBusyDraftID: String?
    @State private var showDismissed = false
    @State private var historyQuery = ""
    @State private var historyKind = CollaborationHistoryKindFilter.all
    @State private var historyOutcome = CollaborationHistoryOutcomeFilter.all
    @State private var historyExportSelection: Set<String> = []
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
        guard selectedBusyDraftID == nil else { return nil }
        return snapshot.handoffs.first(where: { $0.id == selectedHandoffID })
    }

    private var scopedBusyDrafts: [ReviewedBusyDraft] {
        model.statusReviewedBusyDrafts(workspaceID: workspaceID.isEmpty ? nil : workspaceID)
    }

    private var selectedBusyDraft: ReviewedBusyDraft? {
        guard let selectedBusyDraftID else { return nil }
        return scopedBusyDrafts.first(where: { $0.id == selectedBusyDraftID })
    }


    private var filteredHistory: [RelayHandoff] {
        CollaborationHistoryProjection.filter(
            snapshot.handoffs,
            using: CollaborationHistoryFilter(
                query: historyQuery,
                kind: historyKind,
                outcome: historyOutcome
            )
        )
    }

    private var selectedHistoryForExport: [RelayHandoff] {
        snapshot.handoffs.filter { historyExportSelection.contains($0.id) }
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
    private var selectedHandoffResultsForContextPack: [RelayHandoff] {
        selectedHistoryForExport.filter(\.hasReturnedResult)
    }

    private var contextPackPromotionHelp: String {
        if selectedHandoffResultsForContextPack.isEmpty {
            return "Select at least one returned Ask or Delegate result."
        }
        if selectedHandoffResultsForContextPack.contains(where: { $0.resultContextReviewID != nil }) {
            return "A selected file result has its own agent-provided review. Open it from that handoff's inspector."
        }
        if selectedHandoffResultsForContextPack.count > ContextPackBuilder.maximumParts {
            return "Choose at most \(ContextPackBuilder.maximumParts) returned results for one Context Pack."
        }
        if !model.canCreateContextPack {
            return "Select a running relay-ready agent pane to own the editable Context Pack draft."
        }
        return "Open the selected results as attributed, editable sources. Nothing is submitted."
    }

    private var runtimeLifecycle: RuntimeLifecycleSnapshot {
        RuntimeLifecycleProjection.snapshot(
            coreAvailable: model.coreAvailable,
            coreMessage: model.coreAvailable
                ? "The authenticated broker is running inside this Parley process."
                : nil,
            panes: model.panes
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBanner(runtime: model.runtime)
            if model.runtime.visibleMarker != nil { Divider() }
            header
            if let error = model.historyPersistenceError {
                Text("History could not be saved. \(error) Delivered messages may already have reached their target; do not resend them to repair history.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
            countStrip
            Divider()
            segmentBar
            Divider()
            HSplitView {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Color.clear.frame(height: 0).id("status-overview-top")
                            segmentContent
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
                    .onChange(of: segment) { _, _ in
                        reader.scrollTo("status-overview-top", anchor: .top)
                    }
                }
                .frame(minWidth: 520, idealWidth: 650)

                inspector
                    .frame(minWidth: 330, idealWidth: 430)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
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
            selectedBusyDraftID = nil
            historyExportSelection.removeAll()
            ensureSelection()
        }
        .onChange(of: showDismissed) { _, _ in
            selectedHandoffID = nil
            selectedBusyDraftID = nil
            historyExportSelection.formIntersection(snapshot.handoffs.map(\.id))
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
                openWindow(id: "task-manager")
            } label: {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Open Task Manager")
            .accessibilityHint("Inspect Parley-owned workspace, pane and process resource use")
            .help("Open Task Manager")
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
            Button {
                model.showSettings(.notifications)
            } label: {
                Image(systemName: model.notificationWorkspaceNames.isEmpty ? "bell.slash" : "bell.badge")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Workspace notifications")
            .accessibilityValue(
                model.notificationWorkspaceNames.isEmpty
                    ? "Off for all workspaces"
                    : "On for \(model.notificationWorkspaceNames.joined(separator: ", "))"
            )
            .help(
                model.notificationWorkspaceNames.isEmpty
                    ? "Notifications are off for every workspace. Opens Settings › Notifications."
                    : "Notifications on for \(model.notificationWorkspaceNames.joined(separator: ", ")). Opens Settings › Notifications."
            )
            .accessibilityHint("Opens the Notifications tab in Settings, where workspace notifications are enabled")
            Menu {
                Toggle("Show Dismissed", isOn: $showDismissed)
                Button("Restore All Dismissed") {
                    model.restoreAllStatusCenterDismissals()
                    showDismissed = false
                    selectedHandoffID = nil
                    ensureSelection()
                }
                .disabled(model.dismissedHandoffIDs.isEmpty)
                Divider()
                Section("Local retention · handoffs and activity") {
                    ForEach(CollaborationHistoryRetentionPolicy.allowedMaximumRecords, id: \.self) { limit in
                        Button {
                            model.setHistoryRetention(maximumRecords: limit)
                        } label: {
                            if model.historyRetentionPolicy.maximumRecords == limit {
                                Label("Up to \(limit) of each", systemImage: "checkmark")
                            } else {
                                Text("Up to \(limit) of each")
                            }
                        }
                    }
                }
                if let workspace = model.workspaces.first(where: { $0.id == workspaceID }) {
                    Divider()
                    Button("Export History for \(workspace.name)…") {
                        model.exportWorkspaceHistory(for: workspace)
                    }
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
            .accessibilityLabel("Dismissed records, retention, export, and deletion")
            .accessibilityValue(
                model.dismissedHandoffIDs.isEmpty
                    ? "No dismissed records"
                    : "\(model.dismissedHandoffIDs.count) dismissed record\(model.dismissedHandoffIDs.count == 1 ? "" : "s")"
            )
            .help("Dismissed records, local retention, and workspace history controls")
            .accessibilityHint("Show or restore dismissed records, change bounded local retention, or export and delete history for the selected workspace")
            Picker("Scope", selection: $workspaceID) {
                Text("All Workspaces").tag("")
                ForEach(model.workspaces) { workspace in
                    Text(workspace.name).tag(workspace.workspaceID)
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
            countCell("Running", snapshot.counts.runningAgents, kind: .runningAgents)
            countCell("Stopped", snapshot.counts.stoppedAgents, kind: .stoppedAgents)
            countCell("Questions", snapshot.counts.outstandingQuestions, kind: .outstandingQuestions)
            countCell("Delegations", snapshot.counts.trackedDelegations, kind: .trackedDelegations)
            countCell("Results", snapshot.counts.unreadResults, kind: .unreadResults)
            countCell("Failures", snapshot.counts.failures, kind: .failures, warning: snapshot.counts.failures > 0)
        }
        .background(Color.secondary.opacity(0.11))
        .frame(height: 58)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status Center totals. \(WorkbenchAccessibility.counts(snapshot.counts))")
    }

    /// Every count opens the section that explains it; the strip is
    /// navigation, not decoration.
    private func countCell(
        _ label: String,
        _ value: Int,
        kind: StatusCenterCountKind,
        warning: Bool = false
    ) -> some View {
        let destination = StatusCenterSegmentProjection.segment(for: kind)
        let isCurrent = segment == destination
        return Button {
            segment = destination
        } label: {
            VStack(spacing: 2) {
                Text(value.formatted())
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(warning ? Color.red : Color.primary)
                Text(label)
                    .font(ChromeFont.secondary)
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isCurrent ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(destination.label)")
        .accessibilityLabel("\(label): \(value.formatted())")
        .accessibilityHint("Show the \(destination.label) section")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var segmentBar: some View {
        HStack(spacing: 12) {
            Picker("Section", selection: $segment) {
                ForEach(StatusCenterSegment.allCases) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .accessibilityLabel("Status Center section")
            .accessibilityHint("Switch between live work, unread results, history, agents, and health")
            Spacer()
            Text(segmentSummary)
                .font(ChromeFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private var segmentSummary: String {
        switch segment {
        case .live: "Reviewed busy queue and active handoffs"
        case .results: "Returned results that have not been viewed"
        case .history: "Every recorded handoff in scope, with export"
        case .agents: "Pane readiness, protocol and process facts"
        case .health: "Recovery guidance, core lifecycle and the activity timeline"
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch segment {
        case .live:
            reviewedBusyQueue
            liveCollaboration
        case .results:
            returnedResults
        case .history:
            collaborationHistory
        case .agents:
            agents
        case .health:
            recovery
            coreHealth
            timeline
        }
    }

    private var reviewedBusyQueue: some View {
        statusGroup("REVIEWED BUSY QUEUE") {
            if scopedBusyDrafts.isEmpty {
                emptyRow("No reviewed drafts are waiting on busy targets in this scope")
            } else {
                VStack(spacing: 0) {
                    ForEach(scopedBusyDrafts) { draft in
                        Button {
                            select(draft)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(draft.sourceName)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                        Text(draft.targetName)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    Text(subject(draft.text))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("REVIEWED ASK")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(
                                        draft.state == .dispatching
                                            ? "SEND UNCERTAIN"
                                            : (model.reviewedBusyDraftTargetIsBusy(draft) ? "TARGET BUSY" : "READY TO REVIEW")
                                    )
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(
                                            draft.state == .dispatching || model.reviewedBusyDraftTargetIsBusy(draft)
                                                ? Color.orange : Color.accentColor
                                        )
                                    Text(draft.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(9)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selectedBusyDraftID == draft.id ? Color.accentColor.opacity(0.10) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Reviewed Ask from \(draft.sourceName) to \(draft.targetName). \(draft.state == .dispatching ? "Submission status uncertain" : (model.reviewedBusyDraftTargetIsBusy(draft) ? "Target busy and unsent" : "Ready for fresh review and unsent"))"
                        )
                        .accessibilityValue(selectedBusyDraftID == draft.id ? "Selected" : "Not selected")
                        .accessibilityHint("Inspect the exact queued text; Parley never sends it automatically")
                        if draft.id != scopedBusyDrafts.last?.id { Divider() }
                    }
                }
            }
        }
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
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(handoff.targetName)
                    }
                    .font(.system(size: 11, weight: .medium))
                    Text(subject(handoff.text))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if handoff.kind == .delegate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let facts = model.delegationVisibility(for: handoff, at: context.date) {
                                delegationFactsLine(facts)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let relationship = handoff.relationship {
                        ChromeChip(relationship.label, color: .accentColor)
                    }
                    if let verdict = handoff.humanVerdict {
                        ChromeChip(verdict.label, color: verdictColor(verdict))
                    }
                    HStack(spacing: 5) {
                        Text(handoff.kind.rawValue.capitalized)
                            .font(ChromeFont.secondary)
                            .foregroundStyle(.secondary)
                        ChromeChip(handoff.state.rawValue.capitalized, color: stateColor(handoff))
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(activityTiming(handoff, at: context.date))
                            .font(ChromeFont.meta)
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
            Button(handoffAccessibilityLabel(handoff)) {
                select(handoff)
            }
            .accessibilityValue(selectedHandoffID == handoff.id ? "Selected" : "Not selected")
            .accessibilityHint("Inspect this collaboration record")
        }
    }

    private func handoffAccessibilityLabel(_ handoff: RelayHandoff) -> String {
        let base = WorkbenchAccessibility.handoff(handoff)
        guard let facts = model.delegationVisibility(for: handoff, at: Date()) else { return base }
        return "\(base). \(facts.accessibilityDescription)"
    }

    private func delegationFactsLine(_ facts: DelegationVisibility) -> some View {
        HStack(spacing: 5) {
            Image(systemName: facts.quiet == nil ? "clock" : "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(facts.summary)
                .font(ChromeFont.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(facts.accessibilityDescription)
    }

    private var returnedResults: some View {
        let unread = snapshot.handoffs.filter(\.hasUnreadResult)
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

    private var collaborationHistory: some View {
        statusGroup("COLLABORATION HISTORY") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    TextField("Search questions, results, people, workspaces…", text: $historyQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search collaboration history")
                        .accessibilityHint("Every word must match somewhere in the same local handoff record")
                    Picker("Kind", selection: $historyKind) {
                        ForEach(CollaborationHistoryKindFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 125)
                    .accessibilityLabel("Collaboration kind filter")
                    Picker("Outcome", selection: $historyOutcome) {
                        ForEach(CollaborationHistoryOutcomeFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityLabel("Collaboration outcome filter")
                }

                HStack(spacing: 8) {
                    Text("\(filteredHistory.count) matching · \(selectedHistoryForExport.count) selected")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select Results") {
                        historyExportSelection.formUnion(
                            filteredHistory.filter(\.hasReturnedResult).map(\.id)
                        )
                    }
                    .disabled(!filteredHistory.contains(where: \.hasReturnedResult))
                    Button("Clear Selection") {
                        historyExportSelection.removeAll()
                    }
                    .disabled(selectedHistoryForExport.isEmpty)
                    Button("Context Pack from Selected Results…") {
                        model.promoteHandoffResultsToContextPack(selectedHandoffResultsForContextPack)
                    }
                    .disabled(!model.canPromoteHandoffResultsToContextPack(selectedHandoffResultsForContextPack))
                    .help(contextPackPromotionHelp)
                    Button("Export Selected…") {
                        model.exportCollaborationHistory(
                            selectedHistoryForExport,
                            scopeName: selectedHistoryScopeName
                        )
                    }
                    .disabled(selectedHistoryForExport.isEmpty)
                    .accessibilityHint("Save only the selected records, including their complete questions and returned results, to a local owner-only Markdown file")
                }
                .controlSize(.small)

                if filteredHistory.isEmpty {
                    emptyRow("No collaboration records match these filters")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredHistory) { handoff in
                            historyRow(handoff)
                            if handoff.id != filteredHistory.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(9)
        }
    }

    private func historyRow(_ handoff: RelayHandoff) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "Select \(handoff.sourceName) to \(handoff.targetName) for export or Context Pack review",
                isOn: Binding(
                    get: { historyExportSelection.contains(handoff.id) },
                    set: { selected in
                        if selected {
                            historyExportSelection.insert(handoff.id)
                        } else {
                            historyExportSelection.remove(handoff.id)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            Button {
                select(handoff)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(handoff.sourceName) → \(handoff.targetName)")
                            .font(.system(size: 10, weight: .medium))
                        Text(subject(handoff.text))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let relationship = handoff.relationship {
                        ChromeChip(relationship.label, color: .accentColor)
                    }
                    if let verdict = handoff.humanVerdict {
                        ChromeChip(verdict.label, color: verdictColor(verdict))
                    }
                    Text(handoff.kind.rawValue.capitalized)
                        .font(ChromeFont.secondary)
                        .foregroundStyle(.secondary)
                    ChromeChip(handoff.state.rawValue.capitalized, color: stateColor(handoff))
                    Text(handoff.updatedAt, style: .relative)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WorkbenchAccessibility.handoff(handoff))
            .accessibilityValue(selectedHandoffID == handoff.id ? "Selected for inspection" : "Not selected for inspection")
            .accessibilityHint("Inspect this collaboration record")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selectedHandoffID == handoff.id ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    private var selectedHistoryScopeName: String? {
        guard !workspaceID.isEmpty else { return nil }
        return model.workspaces.first(where: { $0.id == workspaceID })?.name ?? workspaceID
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

    private func agentRow(_ pane: WorkbenchPane) -> some View {
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
                        Text(pane.kind.label)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let role = pane.role {
                            Text("@\(role)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        if attention != nil {
                            Text("ATTENTION")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    Text(pane.workspaceName ?? pane.workspaceID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(protocolLabel(pane))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(protocolColor(pane))
                    Text(readiness(pane))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
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
        statusGroup("RUNTIME LIFECYCLE") {
            VStack(spacing: 7) {
                lifecycleRow(
                    name: "App UI",
                    value: "CURRENT",
                    color: .green,
                    detail: "Closing the window keeps app-resident panes and coordination running. Quitting Parley ends both."
                )
                coreLifecycleRow
                protocolLifecycleRow
                Divider()
                healthRow("Embedded Ghostty panes", model.terminalAvailable ? "CONNECTED" : "UNAVAILABLE", healthy: model.terminalAvailable)
                healthRow("Handoffs in scope", snapshot.handoffs.count.formatted(), healthy: true)
                Divider()
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.controller != nil {
                            Text("Terminal backend: embedded Ghostty · app-resident sessions")
                        }
                        Text("Coordination backend: authenticated broker in this Parley process")
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

    @ViewBuilder
    private var coreLifecycleRow: some View {
        switch runtimeLifecycle.core {
        case .unavailable:
            lifecycleRow(
                name: "Coordination core",
                value: "UNAVAILABLE",
                color: .red,
                detail: "Coordination is paused. Use Reconnect in Recovery; terminal panes remain running."
            )
        case .checking:
            lifecycleRow(
                name: "Coordination core",
                value: "APP-RESIDENT",
                color: .green,
                detail: "The authenticated broker is part of this running Parley build and shares its lifetime."
            )
        case let .current(detail):
            lifecycleRow(
                name: "Coordination core",
                value: "CURRENT",
                color: .green,
                detail: detail ?? "The running core matches this Parley build."
            )
        }
    }

    @ViewBuilder
    private var protocolLifecycleRow: some View {
        switch runtimeLifecycle.protocol {
        case let .current(version, runningPaneCount):
            lifecycleRow(
                name: "Agent pane protocol",
                value: "V\(version) CURRENT",
                color: .green,
                detail: runningPaneCount == 0
                    ? "No agent process currently carries the protocol. New starts receive v\(version)."
                    : "All \(runningPaneCount) running agent pane\(runningPaneCount == 1 ? "" : "s") carry the current launch stamp."
            )
        case let .restartRequired(version, paneIDs):
            lifecycleRow(
                name: "Agent pane protocol",
                value: "\(paneIDs.count) RESTART REQUIRED",
                color: .orange,
                detail: "Protocol v\(version) is installed for new starts. Restart only the marked panes from Recovery when you are ready to end those conversations."
            )
        }
    }

    private func lifecycleRow(
        name: String,
        value: String,
        color: Color,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(name)
                    .font(.system(size: 10))
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
        if let draft = selectedBusyDraft {
            reviewedBusyDraftInspector(draft)
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
                            if let relationship = handoff.relationship {
                                statusChip(relationship.rawValue.uppercased(), color: .accentColor)
                            }
                            if let verdict = handoff.humanVerdict {
                                statusChip(verdict.label.uppercased(), color: verdictColor(verdict))
                            }
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

                    if handoff.inReplyToHandoffID != nil {
                        lineageSection(handoff)
                    }
                    if threadMembers(handoff).count > 1 {
                        threadSection(handoff)
                    }
                    inspectorSection(handoff.kind == .delegate ? "INSTRUCTION" : "QUESTION OR MESSAGE", handoff.text)
                    if handoff.kind == .delegate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let facts = model.delegationVisibility(for: handoff, at: context.date) {
                                delegationFactsSection(facts)
                            }
                        }
                    }
                    if handoff.gitFactsAtDelegation != nil || handoff.gitFactsAtReturn != nil {
                        delegationGitSection(handoff)
                    }
                    if let progress = handoff.progressNote, !progress.isEmpty {
                        delegationProgressSection(handoff, progress: progress)
                    }
                    if let result = handoff.resultText, !result.isEmpty {
                        inspectorSection("RETURNED RESULT", result)
                    }
                    if let review = model.returnedFileReview(for: handoff) {
                        if let evidence = CompletionEvidenceProjection.evidence(for: handoff, review: review) {
                            completionEvidenceSection(evidence)
                        }
                        returnedFileReviewSection(review)
                    }
                    if handoff.hasReturnedResult {
                        HandoffHumanReviewEditor(model: model, handoff: handoff)
                            .id("\(handoff.id)-review-\(handoff.reviewRevision ?? 0)")
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
                                Text(transition.state.rawValue.capitalized)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                if let origin = transition.origin {
                                    Text(origin == .automation ? "AUTO" : "HUMAN")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
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

    private func reviewedBusyDraftInspector(_ draft: ReviewedBusyDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("REVIEWED BUSY QUEUE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(draft.sourceName) → \(draft.targetName)")
                        .font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 7) {
                        statusChip("ASK", color: .secondary)
                        statusChip("HUMAN REVIEWED", color: .accentColor)
                        statusChip(
                            draft.state == .dispatching
                                ? "SEND UNCERTAIN"
                                : (model.reviewedBusyDraftTargetIsBusy(draft) ? "TARGET BUSY" : "READY TO REVIEW"),
                            color: draft.state == .dispatching || model.reviewedBusyDraftTargetIsBusy(draft)
                                ? .orange : .accentColor
                        )
                        statusChip(draft.state == .queued ? "UNSENT" : "DO NOT RESEND", color: .secondary)
                    }
                }
                .accessibilityRepresentation {
                    Text(
                        draft.state == .queued
                            ? "Reviewed unsent Ask from \(draft.sourceName) to \(draft.targetName). Parley will not submit it automatically."
                            : "Reviewed Ask from \(draft.sourceName) to \(draft.targetName). Terminal submission is uncertain and Parley will not resend it."
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Button("Focus Source") {
                            model.focusReviewedBusyDraft(draft, target: false)
                        }
                        .disabled(!model.canFocusReviewedBusyDraftPane(draft.sourcePaneID))
                        Button("Focus Target") {
                            model.focusReviewedBusyDraft(draft, target: true)
                        }
                        .disabled(!model.canFocusReviewedBusyDraftPane(draft.targetPaneID))
                    }
                    HStack {
                        Button(
                            model.sendingReviewedBusyDraftID == draft.id
                                ? "Waiting on Sent Ask…"
                                : "Review and Send…"
                        ) {
                            model.sendReviewedBusyDraft(draft)
                        }
                        .disabled(
                            draft.state != .queued
                                || model.reviewedBusyDraftTargetIsBusy(draft)
                                || model.sendingReviewedBusyDraftID != nil
                        )
                        .help(
                            model.reviewedBusyDraftTargetIsBusy(draft)
                                ? "The target still has tracked work; the draft remains unsent"
                                : "Open the exact text in a fresh editable review before submitting"
                        )
                        Button(draft.state == .queued ? "Discard Draft…" : "Dismiss Record…", role: .destructive) {
                            if model.discardReviewedBusyDraft(draft) {
                                selectedBusyDraftID = nil
                                ensureSelection()
                            }
                        }
                        .disabled(model.sendingReviewedBusyDraftID == draft.id)
                    }
                }
                .controlSize(.small)

                inspectorSection(draft.state == .queued ? "REVIEWED UNSENT TEXT" : "REVIEWED TEXT", draft.text)
                if let detail = draft.detail, !detail.isEmpty {
                    inspectorSection("QUEUE RECEIPT", detail)
                }
                Text(
                    draft.state == .queued
                        ? "Becoming idle never sends this draft. Review and Send is a new human authorization and creates a normal tracked Ask with a fresh identity."
                        : "Parley cannot prove whether terminal submission occurred before the interruption. It keeps this non-resendable record visible until you dismiss it."
                )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
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
            if handoff.hasReturnedResult {
                HStack {
                    handoffReviewMenu(.challenge, handoff: handoff)
                    handoffReviewMenu(.verify, handoff: handoff)
                    if handoff.kind == .delegate {
                        handoffReviewMenu(.requestChanges, handoff: handoff)
                    }
                }
            }
            HStack {
                if let consultation = model.consultation(for: handoff) {
                    Button("Return Manually…") { model.returnConsultation(consultation) }
                    Button("Cancel Wait…", role: .destructive) { model.cancel(consultation) }
                } else if handoff.kind == .delegate,
                          [.created, .delivered, .waiting].contains(handoff.state) {
                    Button("Cancel Tracking…", role: .destructive) { model.cancel(handoff) }
                }
                if handoff.kind == .ask {
                    Button(
                        model.repeatingAskHandoffID == handoff.id
                            ? "Waiting on Repeated Ask…"
                            : "Ask This Again…"
                    ) {
                        model.askAgain(handoff)
                    }
                    .disabled(!model.canAskAgain(handoff))
                    .help(
                        model.canAskAgain(handoff)
                            ? "Open the recorded question in an editable preview and create a new tracked Ask"
                            : "Available after this Ask ends while its original source and target panes remain relay-ready"
                    )
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

    private func handoffReviewMenu(
        _ relationship: RelayHandoffRelationship,
        handoff: RelayHandoff
    ) -> some View {
        let source = model.handoffReviewSource(for: handoff)
        let targets = model.handoffReviewTargets(for: handoff)
        return Menu("\(relationship.label)...") {
            Section {
                if targets.isEmpty {
                    Text("No other relay-ready agent panes")
                } else {
                    ForEach(targets) { target in
                        let busy = model.handoffReviewTargetIsBusy(target)
                        let original = relationship == .requestChanges && target.id == handoff.targetPaneID
                        Button(
                            "\(target.displayName) - \(target.kind.label)\(original ? " (original)" : "")\(busy ? " (busy)" : "")"
                        ) {
                            model.beginHandoffReview(
                                relationship,
                                of: handoff,
                                with: target
                            )
                            openWindow(id: "main")
                        }
                        .disabled(busy)
                    }
                }
            } header: {
                Text(source.map { "From \($0.displayName)" } ?? "No relay-ready source pane")
            }
        }
        .disabled(!model.canOfferHandoffReview(handoff))
        .help(
            model.canOfferHandoffReview(handoff)
                ? (relationship == .requestChanges
                    ? "Choose the explicit pane that should revise this result, then edit the linked delegation before sending; it is never a verdict"
                    : "Choose one explicit reviewer pane, then edit the linked Ask before sending")
                : "A source pane and at least one other agent pane must be relay-ready, with no other handoff draft open"
        )
    }

    /// The full local history when Status Center has loaded it, so a dismissed
    /// parent still anchors its thread; otherwise the visible snapshot.
    private var threadHistory: [RelayHandoff] {
        model.statusHandoffs.isEmpty ? snapshot.handoffs : model.statusHandoffs
    }

    private func threadMembers(_ handoff: RelayHandoff) -> [RelayHandoff] {
        HandoffThreadProjection.members(containing: handoff.id, in: threadHistory)
    }

    private func threadSection(_ handoff: RelayHandoff) -> some View {
        let history = threadHistory
        let entries = HandoffThreadProjection.thread(containing: handoff.id, in: history)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("THREAD")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                statusChip("\(threadMembers(handoff).count) LINKED HANDOFFS", color: .secondary)
                Spacer()
            }
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.occurredAt.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ChromeChip(entry.label, color: entry.handoffID == handoff.id ? .accentColor : .secondary)
                    Text("\(entry.sourceName) → \(entry.targetName)")
                        .font(.system(size: 9, weight: .medium))
                    Text(subject(entry.text))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if entry.handoffID != handoff.id {
                        Button("Open") {
                            if let member = history.first(where: { $0.id == entry.handoffID }) { select(member) }
                        }
                        .controlSize(.mini)
                        .accessibilityLabel("Open the \(entry.label) handoff")
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Chronological receipts on the existing handoffs. A request for changes is a linked delegation, never a human verdict.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func lineageSection(_ handoff: RelayHandoff) -> some View {
        let parent = snapshot.handoffs.first {
            $0.id == handoff.inReplyToHandoffID
        }
        return VStack(alignment: .leading, spacing: 7) {
            Text("LINKED REVIEW")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                if let relationship = handoff.relationship {
                    statusChip(relationship.label.uppercased(), color: .accentColor)
                }
                Text("Parent \(String((handoff.inReplyToHandoffID ?? "").prefix(12)))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Parent") {
                    if let parent { select(parent) }
                }
                .disabled(parent == nil)
            }
            .padding(9)
            .background(Color.secondary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 5))
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

    private func delegationProgressSection(_ handoff: RelayHandoff, progress: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("LATEST PROGRESS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                statusChip("AGENT-DECLARED", color: .secondary)
                Spacer()
                if let reportedAt = handoff.progressUpdatedAt {
                    Text(reportedAt, style: .relative)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(progress)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.secondary.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("Not a completion claim. The target must still report done or failed.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func delegationFactsSection(_ facts: DelegationVisibility) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("DELEGATION FACTS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                statusChip("OWNED TIMESTAMPS", color: .secondary)
                Spacer()
            }
            delegationFact("clock", facts.elapsedLabel, at: facts.deliveredAt)
            delegationFact(
                "text.bubble",
                facts.progressLabel,
                at: facts.progress?.reportedAt,
                chip: facts.progress == nil ? nil : "AGENT-DECLARED"
            )
            delegationFact("checkmark.shield", facts.targetSignalLabel, at: facts.targetSignal?.reportedAt)
            if let detail = facts.quietDetail {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DelegationVisibility.quietTitle)
                            .font(.system(size: 10, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Owned timestamps only; nothing is inferred from silence.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facts.accessibilityDescription)
    }

    private func delegationGitSection(_ handoff: RelayHandoff) -> some View {
        let comparison = DelegationGitFacts.compare(
            delegation: handoff.gitFactsAtDelegation,
            returned: handoff.gitFactsAtReturn
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("GIT FACTS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                statusChip(DelegationGitSnapshot.label.uppercased(), color: .secondary)
                Spacer()
            }
            if let facts = handoff.gitFactsAtDelegation {
                delegationFact("arrow.triangle.branch", "At delegation · \(facts.summary)", at: facts.capturedAt)
            }
            if let facts = handoff.gitFactsAtReturn {
                delegationFact("arrow.triangle.branch", "At return · \(facts.summary)", at: facts.capturedAt)
            }
            if let comparison {
                Text(comparison.title)
                    .font(.system(size: 10, weight: .semibold))
                if !comparison.changedPaths.isEmpty {
                    ScrollView {
                        Text(comparison.displayPaths.joined(separator: "\n"))
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.secondary.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                if let detail = comparison.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Paths only. Other panes and the person edit this tree; nothing here says who changed a file.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
    }

    private func delegationFact(_ symbol: String, _ label: String, at time: Date?, chip: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 11)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 10))
            if let chip {
                statusChip(chip, color: .secondary)
            }
            Spacer()
            if let time {
                Text(time.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func completionEvidenceSection(_ evidence: CompletionEvidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("COMPLETION EVIDENCE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                statusChip(CompletionEvidence.label, color: .secondary)
                Spacer()
            }
            ForEach(evidence.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.section.heading)
                            .font(.system(size: 10, weight: .semibold))
                        Text("claimed")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if entry.body.isEmpty {
                        Text("Nothing declared under this heading.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(entry.body)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                            .background(Color.secondary.opacity(0.055))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(entry.section.heading), agent-declared: \(entry.body.isEmpty ? "nothing declared" : entry.body)")
            }
            if !evidence.missing.isEmpty {
                Text("Not declared: \(evidence.missing.map(\.heading).joined(separator: ", "))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(CompletionEvidence.disclaimer)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
    }

    private func returnedFileReviewSection(_ review: AgentContextReview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("RETURNED FILE REVIEW")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                statusChip("AGENT-PROVIDED", color: .secondary)
                statusChip(review.state.rawValue.uppercased(), color: review.state.needsHumanReview ? .orange : .secondary)
                Spacer()
            }
            Text("\(review.pack.parts.count) source · \(review.pack.sourceByteCount.formatted()) UTF-8 bytes")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Parley has not independently verified or forwarded this file. Review and edit the visible source before choosing whether to send it as a Context Pack.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if review.state.needsHumanReview {
                Button("Review Returned File…") {
                    model.presentContextReview(review)
                    openWindow(id: "main")
                }
                .help("Open the agent-provided file as an editable Context Pack; nothing is sent automatically")
            } else {
                Text(review.detail ?? "This returned-file review has been resolved.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
    }

    private var timeline: some View {
        let events = Array(snapshot.timeline.prefix(150))
        return statusGroup("ACTIVITY") {
            if events.isEmpty {
                emptyRow("No recorded activity in this scope")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(events) { event in
                        timelineRow(event)
                        if event.id != events.last?.id { Divider() }
                    }
                }
            }
        }
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
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(event.action)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
            if event.origin == .human {
                ChromeChip("Human", color: .accentColor)
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
            ChromeHeading(title)
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
        ChromeChip(text, color: color)
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
        let status = switch snapshot.condition {
        case .allClear: "No active or failed cross-vendor work in this scope."
        case .resultsAvailable: "One or more Ask or Delegate results have not been viewed."
        case .agentsWaiting: "One or more tracked handoffs are still active."
        case .humanInputRequired: "A known permission, readiness, or target issue needs attention."
        case .interruptedWork: "A handoff failed or was interrupted; inspect its recorded reason."
        case .coreUnavailable: "The last authoritative collaboration state remains visible while Parley reconnects."
        }
        guard !workspaceID.isEmpty,
              let workspace = model.workspaces.first(where: {
                  $0.id == workspaceID || $0.workspaceID == workspaceID
              }) else { return status }
        let folders = workspace.isFolderless
            ? "No folders attached."
            : "\(workspace.attachedFolders.count) folder\(workspace.attachedFolders.count == 1 ? "" : "s") attached."
        return "\(status) \(folders)"
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
        case .allClear: .secondary
        case .resultsAvailable: .accentColor
        case .agentsWaiting: .accentColor
        case .humanInputRequired: .orange
        case .interruptedWork, .coreUnavailable: .red
        }
    }

    private func stateColor(_ handoff: RelayHandoff) -> Color {
        ChromeColor.handoff(handoff)
    }

    private func verdictColor(_ verdict: RelayHandoffVerdict) -> Color {
        ChromeColor.verdict(verdict)
    }

    private func readiness(_ pane: WorkbenchPane) -> String {
        switch WorkbenchStateProjection.pane(pane) {
        case .empty: return "NO PANE"
        case .stopped: return "NOT STARTED"
        case let .exited(status): return status.map { "EXITED \($0)" } ?? "EXITED"
        case .protocolStale: return "PROTOCOL STALE"
        case .relayUnavailable: return "RELAY OFF"
        case .running:
            return pane.inputAvailable ? "INPUT AVAILABLE" : "INPUT UNAVAILABLE"
        }
    }

    private func readinessColor(_ pane: WorkbenchPane) -> Color {
        if pane.isDead { return .red }
        switch WorkbenchStateProjection.pane(pane) {
        case .protocolStale, .relayUnavailable: return .orange
        case .running: return pane.inputAvailable ? .primary : .secondary
        case .empty, .stopped, .exited: return .secondary
        }
    }

    private func protocolLabel(_ pane: WorkbenchPane) -> String {
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

    private func protocolColor(_ pane: WorkbenchPane) -> Color {
        switch WorkbenchStateProjection.protocolStatus(pane) {
        case .notAttached, .current: .secondary
        case .restartRequired: .orange
        }
    }

    private func processState(_ pane: WorkbenchPane) -> String {
        if pane.isDead { return "EXITED" }
        return pane.isStarted ? "RUNNING" : "STOPPED"
    }

    private func processColor(_ pane: WorkbenchPane) -> Color {
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
        if transition.origin == .automation { parts.append("Auto orchestration") }
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
        if let selectedBusyDraftID,
           scopedBusyDrafts.contains(where: { $0.id == selectedBusyDraftID }) {
            return
        }
        if let selectedHandoffID,
           let selected = snapshot.handoffs.first(where: { $0.id == selectedHandoffID }) {
            if selected.hasUnreadResult { model.markRead(selected) }
            return
        }
        if let firstDraft = scopedBusyDrafts.first {
            select(firstDraft)
        } else if let first = snapshot.handoffs.first {
            select(first)
        }
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
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        segment = StatusCenterSegmentProjection.segment(
            isActive: activeStates.contains(handoff.state),
            hasUnreadResult: handoff.hasUnreadResult
        )
        select(handoff)
        model.consumeRequestedStatusHandoffID()
    }

    private func select(_ handoff: RelayHandoff) {
        selectedBusyDraftID = nil
        selectedHandoffID = handoff.id
        if handoff.hasUnreadResult { model.markRead(handoff) }
    }


    private func select(_ draft: ReviewedBusyDraft) {
        selectedHandoffID = nil
        selectedBusyDraftID = draft.id
    }
}

private struct HandoffHumanReviewEditor: View {
    @ObservedObject var model: AppModel
    let handoff: RelayHandoff
    @State private var verdictValue: String
    @State private var note: String

    init(model: AppModel, handoff: RelayHandoff) {
        self.model = model
        self.handoff = handoff
        _verdictValue = State(initialValue: handoff.humanVerdict?.rawValue ?? "")
        _note = State(initialValue: handoff.humanReviewNote ?? "")
    }

    private var verdict: RelayHandoffVerdict? {
        RelayHandoffVerdict(rawValue: verdictValue)
    }

    private var normalizedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        verdictValue != (handoff.humanVerdict?.rawValue ?? "")
            || normalizedNote != (handoff.humanReviewNote ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("HUMAN REVIEW")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let reviewedAt = handoff.reviewedAt {
                    Text("Saved \(reviewedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Verdict", selection: $verdictValue) {
                Text("No verdict").tag("")
                ForEach(RelayHandoffVerdict.allCases, id: \.rawValue) { verdict in
                    Text(verdict.label).tag(verdict.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 250, alignment: .leading)

            TextEditor(text: $note)
                .font(.system(size: 10))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(minHeight: 64, maxHeight: 100)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityLabel("Human review note")

            HStack {
                Text("\(note.count) / 4000")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(note.count > 4_000 ? Color.red : Color.secondary)
                Text("Native control only; agent panes cannot set this review.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Review") {
                    verdictValue = ""
                    note = ""
                    model.saveHandoffReview(handoff, verdict: nil, note: "")
                }
                .disabled(handoff.humanVerdict == nil && handoff.humanReviewNote == nil)
                Button("Save Review") {
                    model.saveHandoffReview(handoff, verdict: verdict, note: note)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || note.count > 4_000)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
