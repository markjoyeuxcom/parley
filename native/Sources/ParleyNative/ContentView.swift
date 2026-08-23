import ParleyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 290)
        } detail: {
            VStack(spacing: 0) {
                workspaceTabs
                Divider()
                toolbar
                if let activity = model.primaryActivity {
                    Divider()
                    activityStrip(activity)
                }
                Divider()
                terminal
            }
        }
        .frame(minWidth: 1_040, minHeight: 680)
        .onReceive(refresh) { _ in model.refreshQuietly() }
        .alert(
            "Parley could not start",
            isPresented: Binding(
                get: { model.startupError != nil },
                set: { if !$0 { model.startupError = nil } }
            ),
            actions: { Button("OK") { model.startupError = nil } },
            message: { Text(model.startupError ?? "Unknown error") }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(model.visiblePanes) { pane in
                HStack(spacing: 6) {
                    Button {
                        model.select(pane)
                    } label: {
                        PaneRow(
                            pane: pane,
                            projectContext: model.projectContext(for: pane),
                            awaitingAnswerCount: model.awaitingAnswerCount(for: pane.id),
                            unreadResultCount: model.unreadResultCount(forPane: pane.id),
                            latestFailure: model.latestFailure(for: pane.id)
                        )
                    }
                    .buttonStyle(.plain)
                    if pane.kind.isAgent && !pane.isStarted {
                        Button("Start") { model.start(pane) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Start a new \(pane.kind.label) CLI session in \(pane.cwd)")
                    }
                }
                .listRowBackground(pane.isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .contextMenu {
                    Button("Rename…") { model.rename(pane) }
                    if pane.kind.isAgent && !pane.isStarted {
                        Button("Start") { model.start(pane) }
                    } else {
                        Button("Restart…") { model.restart(pane) }
                    }
                    Divider()
                    Button("Close Pane…", role: .destructive) { model.close(pane) }
                }
            }
            if !model.favouriteFolders.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("FAVOURITE FOLDERS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.vertical, showsIndicators: model.favouriteFolders.count > 5) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.favouriteFolders, id: \.self) { folder in
                                favouriteFolderRow(folder)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.favouriteFolders.count) * 26, 130))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("WORKSPACE FOLDER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Choose Folder…", action: model.chooseFolder)
                    Button(model.isFavouriteFolder(model.defaultFolder) ? "Remove from Favourites" : "Add to Favourites") {
                        model.toggleFavouriteFolder(model.defaultFolder)
                    }
                    let favouriteAlternatives = model.favouriteFolders.filter { $0 != model.defaultFolder }
                    if !favouriteAlternatives.isEmpty {
                        Divider()
                        Section("Favourites") {
                            ForEach(favouriteAlternatives, id: \.self) { folder in
                                Button(URL(fileURLWithPath: folder).lastPathComponent) {
                                    model.setWorkspaceFolder(folder)
                                }
                                .help(folder)
                            }
                        }
                    }
                    let recentAlternatives = model.recentFolders.filter {
                        $0 != model.defaultFolder && !model.favouriteFolders.contains($0)
                    }
                    if !recentAlternatives.isEmpty {
                        Divider()
                        Section("Recent") {
                            ForEach(recentAlternatives, id: \.self) { folder in
                                Button(URL(fileURLWithPath: folder).lastPathComponent) {
                                    model.setWorkspaceFolder(folder)
                                }
                                .help(folder)
                            }
                        }
                    }
                } label: {
                    Label(URL(fileURLWithPath: model.defaultFolder).lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .help("New panes in this workspace open in \(model.defaultFolder). Running panes keep their own folders.")
            }
            .padding(12)
        }
    }

    private func favouriteFolderRow(_ folder: String) -> some View {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        let isActive = model.workspaces.contains { $0.isActive && $0.defaultFolder == folder }
        return Button {
            model.createWorkspace(folder: folder)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("Open workspace at \(folder)")
        .accessibilityLabel("Open favourite folder \(name)")
        .accessibilityHint(folder)
        .contextMenu {
            Button("Remove from Favourites") {
                model.toggleFavouriteFolder(folder)
            }
        }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.workspaces) { workspace in
                        Button {
                            model.select(workspace)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                Text(workspace.name)
                                    .lineLimit(1)
                                let waiting = model.waitingCount(for: workspace.id)
                                if waiting > 0 {
                                    Label("\(waiting)", systemImage: "clock")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .labelStyle(.titleAndIcon)
                                }
                                let failures = model.failureCount(for: workspace.id)
                                if failures > 0 {
                                    Label("\(failures)", systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(model.requiresHumanAttention(workspace.id) ? Color.orange : Color.red)
                                        .labelStyle(.titleAndIcon)
                                }
                                let unread = model.unreadResultCount(forWorkspace: workspace.id)
                                if unread > 0 {
                                    Label("\(unread)", systemImage: "envelope.badge")
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            .font(.system(size: 11, weight: workspace.isActive ? .semibold : .regular))
                            .foregroundStyle(workspace.isActive ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(workspace.isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(workspace.defaultFolder)
                        .contextMenu {
                            Button("Rename…") { model.rename(workspace) }
                            Button("Save Layout…") { model.saveLayout(of: workspace) }
                            Button(model.isFavouriteFolder(workspace.defaultFolder) ? "Remove Folder from Favourites" : "Add Folder to Favourites") {
                                model.toggleFavouriteFolder(workspace.defaultFolder)
                            }
                            Divider()
                            Button("Move Tab Left") { model.move(workspace, by: -1) }
                                .disabled(!model.canMove(workspace, by: -1))
                            Button("Move Tab Right") { model.move(workspace, by: 1) }
                                .disabled(!model.canMove(workspace, by: 1))
                            Divider()
                            Button("Close Workspace…", role: .destructive) { model.close(workspace) }
                                .disabled(model.workspaces.count == 1)
                        }
                    }
                }
            }

            Menu {
                Button("Choose Folder…", action: model.createWorkspace)
                Button("Save Current Layout…", action: model.saveActiveWorkspaceLayout)
                if !model.favouriteFolders.isEmpty {
                    Divider()
                    Section("Favourite Folders") {
                        ForEach(model.favouriteFolders, id: \.self) { folder in
                            Button(URL(fileURLWithPath: folder).lastPathComponent) {
                                model.createWorkspace(folder: folder)
                            }
                            .help(folder)
                        }
                    }
                }
                let nonFavouriteRecents = model.recentFolders.filter { !model.favouriteFolders.contains($0) }
                if !nonFavouriteRecents.isEmpty {
                    Divider()
                    Section("Recent Folders") {
                        ForEach(nonFavouriteRecents, id: \.self) { folder in
                            Button(URL(fileURLWithPath: folder).lastPathComponent) {
                                model.createWorkspace(folder: folder)
                            }
                            .help(folder)
                        }
                    }
                }
                if !model.savedLayouts.isEmpty {
                    Divider()
                    Section("Saved Layouts") {
                        ForEach(model.savedLayouts) { layout in
                            Menu(layout.name) {
                                Button("Open Over Current Workspace…") { model.open(layout) }
                                Divider()
                                Button("Delete Saved Layout…", role: .destructive) { model.delete(layout) }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open workspace")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            paneMenu(kind: .claude)
            paneMenu(kind: .codex)
            paneMenu(kind: .agy)
            paneMenu(kind: .copilot)
            paneMenu(kind: .shell)
            Divider().frame(height: 18)
            Menu {
                if model.askTargets.isEmpty {
                    Text("Focus an agent pane with another vendor open")
                } else {
                    if !model.localAskTargets.isEmpty {
                        Section("This Workspace") {
                            ForEach(model.localAskTargets) { target in
                                Button("Ask \(target.displayName)") { model.ask(target) }
                            }
                        }
                    }
                    ForEach(model.otherWorkspaceAskGroups) { group in
                        Menu(group.workspace.name) {
                            ForEach(group.panes) { target in
                                Button("Ask \(target.displayName)") { model.ask(target) }
                            }
                        }
                    }
                }
            } label: {
                Label("Ask", systemImage: "arrow.turn.up.right")
            }
            .disabled(model.askTargets.isEmpty)

            Menu {
                Menu("Current Changes") {
                    reviewTargetItems { model.reviewChanges(with: $0) }
                }
                Menu("Plan or File…") {
                    reviewTargetItems { model.reviewFile(with: $0) }
                }
            } label: {
                Label("Review", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(model.askTargets.isEmpty)
            .help("Preview repository changes or a selected file, then ask another vendor to review it")

            Menu {
                ForEach(model.activePaneConsultations) { consultation in
                    Button("Answer \(consultation.sourceName)") {
                        model.returnConsultation(consultation)
                    }
                }
                if let legacyTarget = model.legacyReturnTarget {
                    if !model.activePaneConsultations.isEmpty { Divider() }
                    Button("Return to \(legacyTarget.displayName)") { model.returnAnswer() }
                }
            } label: {
                Label("Return", systemImage: "arrow.turn.down.left")
            }
            .disabled(!model.canReturn)

            if !model.consultations.isEmpty || !model.activeDelegations.isEmpty {
                Divider().frame(height: 18)
                Menu {
                    if !model.consultations.isEmpty {
                        Section("Questions") {
                            ForEach(model.consultations) { consultation in
                                Button(
                                    "Cancel \(consultation.sourceName) → \(consultation.targetName)…",
                                    role: .destructive
                                ) {
                                    model.cancel(consultation)
                                }
                            }
                        }
                    }
                    if !model.activeDelegations.isEmpty {
                        Section("Delegated Work") {
                            ForEach(model.activeDelegations) { handoff in
                                Menu("\(handoff.sourceName) → \(handoff.targetName)") {
                                    Text(activitySubject(handoff.text))
                                    Divider()
                                    Button("Focus \(handoff.sourceName)") { model.focus(handoff, target: false) }
                                        .disabled(!model.canFocus(handoff.sourcePaneID))
                                    Button("Focus \(handoff.targetName)") { model.focus(handoff, target: true) }
                                        .disabled(!model.canFocus(handoff.targetPaneID))
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        "Waiting \(model.consultations.count + model.activeDelegations.count)",
                        systemImage: "clock"
                    )
                }
                .help("Inspect questions and delegated work awaiting a result")
            }

            Spacer()
            if let active = model.activePane {
                Text("\(active.displayName) · \(URL(fileURLWithPath: active.cwd).lastPathComponent)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: model.zoom) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom active pane")
            Button(action: model.balance) { Image(systemName: "rectangle.grid.2x2") }
                .help("Balance panes")
            Divider().frame(height: 18)
            Button {
                openWindow(id: "status-center")
            } label: {
                Label("Status", systemImage: "waveform.path.ecg")
            }
            .help("Open Status Center")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private func activityStrip(_ handoff: RelayHandoff) -> some View {
        HStack(spacing: 7) {
            Text("ACTIVITY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            Button(handoff.sourceName) { model.focus(handoff, target: false) }
                .disabled(!model.canFocus(handoff.sourcePaneID))
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Button(handoff.targetName) { model.focus(handoff, target: true) }
                .disabled(!model.canFocus(handoff.targetPaneID))

            HStack(spacing: 5) {
                Text(handoff.kind.rawValue.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(activitySubject(handoff.text))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(activityTiming(handoff, at: context.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(activityStateLabel(handoff))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(activityColor(handoff))

            Menu {
                ForEach(Array(model.workspaceHandoffs.prefix(12))) { item in
                    Menu("\(item.sourceName) → \(item.targetName) · \(item.state.rawValue)") {
                        Text(activitySubject(item.text))
                        if (item.state == .failed || item.state == .interrupted),
                           let failure = item.transitions.last?.detail,
                           !failure.isEmpty {
                            Text(failure)
                        }
                        if let result = item.resultText, !result.isEmpty,
                           item.state == .completed || item.kind == .delegate {
                            Divider()
                            Text(result)
                            if item.hasUnreadResult {
                                Button("Mark Result Read") { model.markRead(item) }
                            }
                        }
                        Divider()
                        Button("Focus \(item.sourceName)") { model.focus(item, target: false) }
                            .disabled(!model.canFocus(item.sourcePaneID))
                        Button("Focus \(item.targetName)") { model.focus(item, target: true) }
                            .disabled(!model.canFocus(item.targetPaneID))
                        if item.attention != nil {
                            Divider()
                            Button(attentionActionLabel(item)) { model.focus(item, target: true) }
                                .disabled(!model.canFocus(item.targetPaneID))
                        }
                        if item.canRetrySafely {
                            Divider()
                            Button("Retry Original Delivery…") { model.retry(item) }
                        } else if item.state == .failed && item.kind == .delegate {
                            Divider()
                            Button("Delegated work cannot be delivery-retried") {}
                                .disabled(true)
                        } else if item.state == .failed && item.kind != .ask {
                            Divider()
                            Button("Retry unavailable — delivery may have started") {}
                                .disabled(true)
                        }
                        if let consultation = model.consultation(for: item) {
                            Divider()
                            Button("Cancel Ask…", role: .destructive) { model.cancel(consultation) }
                        }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuIndicator(.hidden)
            .help("Recent collaboration in this workspace")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Color.secondary.opacity(0.045))
    }

    private func activitySubject(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
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

    private func activityStateLabel(_ handoff: RelayHandoff) -> String {
        switch handoff.attention {
        case .permissionRequired: "PERMISSION REQUIRED"
        case .targetNotReady: "TARGET NOT READY"
        case .targetUnavailable: "TARGET UNAVAILABLE"
        case nil: handoff.state.rawValue.uppercased()
        }
    }

    private func attentionActionLabel(_ handoff: RelayHandoff) -> String {
        switch handoff.attention {
        case .permissionRequired: "Resolve Permission in \(handoff.targetName)"
        case .targetNotReady: "Make \(handoff.targetName) Ready"
        case .targetUnavailable: "Inspect Missing Target"
        case nil: "Focus \(handoff.targetName)"
        }
    }

    private func activityColor(_ handoff: RelayHandoff) -> Color {
        if handoff.attention != nil { return .orange }
        return switch handoff.state {
        case .created, .delivered, .waiting, .answered:
            .accentColor
        case .failed, .interrupted:
            .red
        case .completed, .cancelled:
            .secondary
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let configuration = model.attachConfiguration {
            TerminalHost(configuration: configuration, handle: model.terminalHandle)
                .background(Color(nsColor: NSColor(white: 0.085, alpha: 1)))
        } else {
            ContentUnavailableView(
                "tmux is unavailable",
                systemImage: "terminal",
                description: Text(model.startupError ?? "Parley could not create its isolated session.")
            )
        }
    }

    private func paneMenu(kind: PaneKind) -> some View {
        Menu {
            Button("Split Right") { model.create(kind, direction: .horizontal) }
            Button("Split Below") { model.create(kind, direction: .vertical) }
        } label: {
            Label(kind.label, systemImage: kind == .shell ? "terminal" : "bubble.left.and.text.bubble.right")
        }
    }

    @ViewBuilder
    private func reviewTargetItems(action: @escaping (TmuxPane) -> Void) -> some View {
        if !model.localAskTargets.isEmpty {
            Section("This Workspace") {
                ForEach(model.localAskTargets) { target in
                    Button(target.displayName) { action(target) }
                }
            }
        }
        ForEach(model.otherWorkspaceAskGroups) { group in
            Menu(group.workspace.name) {
                ForEach(group.panes) { target in
                    Button(target.displayName) { action(target) }
                }
            }
        }
    }
}

private struct PaneRow: View {
    let pane: TmuxPane
    let projectContext: GitProjectContext?
    let awaitingAnswerCount: Int
    let unreadResultCount: Int
    let latestFailure: RelayHandoff?

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(kindColor)
                .frame(width: 5, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(pane.displayName).font(.system(size: 12, weight: .medium))
                    if pane.returnToPaneID != nil || awaitingAnswerCount > 0 {
                        Text(awaitingAnswerCount > 1 ? "RETURN \(awaitingAnswerCount)" : "RETURN")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    if unreadResultCount > 0 {
                        Text(unreadResultCount > 1 ? "RESULT \(unreadResultCount)" : "RESULT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    if pane.kind.isAgent && !pane.isStarted {
                        Text("STOPPED")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    if pane.kind.isAgent && pane.isStarted && !pane.relayEnabled {
                        Text("RESTART FOR RELAY")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                    if pane.kind.isAgent && pane.isStarted && !pane.hasCurrentProtocol {
                        Text("RESTART FOR PROTOCOL")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                    if let latestFailure {
                        Text(failureLabel(latestFailure))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(latestFailure.attention != nil ? Color.orange : Color.red)
                    }
                }
                HStack(spacing: 4) {
                    Text(folderName)
                    if let projectContext {
                        Text("·")
                        Text(projectContext.branch)
                        if projectContext.isDirty {
                            Text("DIRTY")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.orange)
                        }
                    }
                    Text("·")
                    Text(pane.isStarted ? pane.currentCommand : "not started")
                }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .help(paneHelp)
    }

    private var folderName: String {
        let name = URL(fileURLWithPath: pane.cwd).lastPathComponent
        return name.isEmpty ? pane.cwd : name
    }

    private var paneHelp: String {
        guard let projectContext else { return pane.cwd }
        let state = projectContext.isDirty ? "dirty" : "clean"
        return "\(pane.cwd)\nGit: \(projectContext.branch) · \(state)"
    }

    private var kindColor: Color {
        switch pane.kind {
        case .claude: .orange
        case .codex: .blue
        case .agy: .purple
        case .copilot: .green
        case .shell: .secondary
        }
    }

    private func failureLabel(_ handoff: RelayHandoff) -> String {
        switch handoff.attention {
        case .permissionRequired: "NEEDS PERMISSION"
        case .targetNotReady: "NOT READY"
        case .targetUnavailable: "UNAVAILABLE"
        case nil: "DELIVERY FAILED"
        }
    }
}
