import ParleyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    // Default-mode timers pause while AppKit is tracking a menu. Publishing in
    // `.common` rebuilds SwiftUI menu content under the pointer once per second,
    // which repeatedly drops and restores the highlighted item.
    private let refresh = Timer.publish(
        every: 1,
        on: .main,
        in: MenuTrackingRefreshPolicy.runLoopMode
    ).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 290)
        } detail: {
            VStack(spacing: 0) {
                workspaceTabs
                Divider()
                toolbar
                if model.connectionState == .coreDisconnected {
                    Divider()
                    connectionNotice
                }
                if model.tmuxAvailable, model.activePaneState != .running, model.activePaneState != .empty {
                    Divider()
                    paneNotice
                }
                if let recipe = model.activeRecipeRun {
                    Divider()
                    recipeRunStrip(recipe)
                }
                if let activity = model.primaryActivity {
                    Divider()
                    activityStrip(activity)
                }
                Divider()
                terminal
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .onReceive(refresh) { _ in model.refreshQuietly() }
        .sheet(isPresented: $model.commandPalettePresented) {
            CommandPaletteView(model: model)
        }
        .sheet(isPresented: $model.setupPresented) {
            SetupView(model: model)
        }
        .alert(
            "Parley needs attention",
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
                    .accessibilityLabel("\(pane.displayName), \(pane.kind.label) pane")
                    .accessibilityValue(paneAccessibilityValue(pane))
                    .accessibilityHint("Focus this pane")
                    paneRecoveryButton(pane)
                }
                .listRowBackground(pane.isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .contextMenu {
                    Button("Rename…") { model.rename(pane) }
                    if pane.kind.isAgent {
                        if pane.isWorkspaceLead {
                            Button("Remove as Workspace Lead") {
                                if let workspace = model.workspaces.first(where: { $0.id == pane.windowID }) {
                                    model.clearWorkspaceLead(workspace)
                                }
                            }
                        } else {
                            Button("Make Workspace Lead") { model.setWorkspaceLead(pane) }
                        }
                    }
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
                .accessibilityLabel("Workspace folder")
                .accessibilityValue(model.defaultFolder)
                .accessibilityHint("Choose where newly opened toolbar panes start")
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
                    .truncationMode(.middle)
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

    private func paneAccessibilityValue(_ pane: TmuxPane) -> String {
        let folder = URL(fileURLWithPath: pane.cwd).lastPathComponent
        let state: String = switch WorkbenchStateProjection.pane(pane) {
        case .empty: "empty"
        case .running: pane.isActive ? "selected" : "running"
        case .stopped: "stopped"
        case let .exited(status): status.map { "exited with status \($0)" } ?? "exited"
        case .protocolStale: "protocol restart required"
        case .relayUnavailable: "relay restart required"
        }
        let lead = pane.isWorkspaceLead ? ", workspace lead" : ""
        return "\(state)\(lead), \(folder.isEmpty ? pane.cwd : folder)"
    }

    @ViewBuilder
    private func paneRecoveryButton(_ pane: TmuxPane) -> some View {
        switch WorkbenchStateProjection.pane(pane) {
        case .stopped:
            Button("Start") { model.start(pane) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Start \(pane.displayName)")
                .accessibilityHint("Start a new \(pane.kind.label) CLI session in \(pane.cwd)")
                .help("Start a new \(pane.kind.label) CLI session in \(pane.cwd)")
        case .exited, .protocolStale, .relayUnavailable:
            Button("Restart") { model.restart(pane) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("Restart \(pane.displayName)")
                .accessibilityHint("Restart this \(pane.kind.label) pane in \(pane.cwd)")
                .help("Restart \(pane.displayName) in \(pane.cwd)")
        case .empty, .running:
            EmptyView()
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
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 150)
                                Text(workspace.automationPolicy == .off ? "OFF" : (workspace.automationPolicy == .askAnswer ? "ASK" : "DELEGATE"))
                                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(workspace.automationPolicy == .off ? Color.secondary : Color.accentColor)
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
                        .help("\(workspace.defaultFolder)\nControl-Tab switches workspaces")
                        .accessibilityLabel("Workspace \(workspace.name)")
                        .accessibilityValue("\(workspace.isActive ? "Selected" : "Not selected"), automation \(workspace.automationPolicy.label)")
                        .accessibilityHint("Open workspace at \(workspace.defaultFolder)")
                        .contextMenu {
                            Button("Rename…") { model.rename(workspace) }
                            Button("Save Layout…") { model.saveLayout(of: workspace) }
                            Menu("Automation: \(workspace.automationPolicy.label)") {
                                ForEach(WorkspaceAutomationPolicy.allCases, id: \.rawValue) { policy in
                                    Button {
                                        model.setAutomationPolicy(policy, for: workspace)
                                    } label: {
                                        Label(policy.label, systemImage: policy == workspace.automationPolicy ? "checkmark" : "")
                                    }
                                }
                            }
                            if model.panes.contains(where: { $0.windowID == workspace.id && $0.isWorkspaceLead }) {
                                Button("Clear Workspace Lead") { model.clearWorkspaceLead(workspace) }
                            }
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
            .accessibilityLabel("Open workspace")
            .help("Open workspace")
            .accessibilityHint("Choose a folder, favourite, recent folder, or saved layout")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            wideToolbar
            compactToolbar
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var wideToolbar: some View {
        HStack(spacing: 8) {
            paneMenu(kind: .claude)
            paneMenu(kind: .codex)
            paneMenu(kind: .agy)
            paneMenu(kind: .copilot)
            paneMenu(kind: .shell)
            Divider().frame(height: 18)
            askMenu
            reviewMenu
            recipeMenu
            returnMenu

            if hasWaitingWork {
                Divider().frame(height: 18)
                waitingMenu
            }

            Spacer()
            activePaneContext(maxWidth: 240)
            Button(action: model.zoom) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("Zoom active pane")
                .help("Zoom active pane")
                .accessibilityHint("Toggle between the active pane and the full pane grid")
            Button(action: model.balance) { Image(systemName: "rectangle.grid.2x2") }
                .accessibilityLabel("Balance panes")
                .help("Balance panes")
                .accessibilityHint("Make panes in the active workspace equal size")
            Divider().frame(height: 18)
            Button {
                openWindow(id: "status-center")
            } label: {
                Label("Status", systemImage: "waveform.path.ecg")
            }
            .accessibilityLabel("Open Status Center")
            .help("Open Status Center")
            .accessibilityHint("Inspect collaboration state, returned results, agents, and activity")
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            newPaneMenu
            askMenu
            compactActionsMenu
            Spacer(minLength: 6)
            activePaneContext(maxWidth: 130)
            Button {
                openWindow(id: "status-center")
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityLabel("Open Status Center")
            .help("Open Status Center")
            .accessibilityHint("Inspect collaboration state, returned results, agents, and activity")
        }
    }

    private var newPaneMenu: some View {
        Menu {
            ForEach(PaneKind.allCases, id: \.rawValue) { kind in
                Menu(kind.label) {
                    paneCreationItems(kind: kind)
                }
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .accessibilityLabel("New pane")
        .help("Open a new agent or shell pane")
        .accessibilityHint("Choose an agent or shell and where to split the active workspace")
    }

    private var askMenu: some View {
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
        .accessibilityLabel("Ask another vendor")
        .accessibilityValue("\(model.askTargets.count) available target\(model.askTargets.count == 1 ? "" : "s")")
        .accessibilityHint("Choose a different vendor pane for a correlated question")
        .disabled(model.askTargets.isEmpty)
    }

    private var reviewMenu: some View {
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
        .accessibilityLabel("Review with another vendor")
        .disabled(model.askTargets.isEmpty)
        .help("Preview repository changes or a selected file, then ask another vendor to review it")
        .accessibilityHint("Preview current changes, a plan, or a file before asking another vendor")
    }

    private var recipeMenu: some View {
        Menu {
            if model.workspaceLead == nil {
                Text("Mark an agent pane as workspace lead")
            }
            Section("Run with Workspace Lead") {
                ForEach(model.recipes) { recipe in
                    Button(recipe.name) { model.run(recipe) }
                        .disabled(!model.canRun(recipe))
                }
            }
            Divider()
            Menu("Edit Recipes") {
                ForEach(model.recipes) { recipe in
                    Button(recipe.name) { model.edit(recipe) }
                }
                Divider()
                Button("Restore Defaults…") { model.restoreDefaultRecipes() }
            }
        } label: {
            Label("Recipes", systemImage: "list.bullet.rectangle")
        }
        .accessibilityLabel("Supervised workflow recipes")
        .accessibilityValue(model.workspaceLead.map { "Lead: \($0.displayName)" } ?? "No workspace lead")
        .help("Run or edit a visible cross-vendor workflow instruction for the workspace lead")
        .accessibilityHint("Choose a plan review, implementation review, bug hunt, or comparison recipe")
    }

    private var returnMenu: some View {
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
        .accessibilityLabel("Return answer")
        .accessibilityValue(model.canReturn ? "Answer destination available" : "No answer destination")
        .accessibilityHint("Return the active pane's answer to its waiting requester")
        .disabled(!model.canReturn)
    }

    private var compactActionsMenu: some View {
        Menu {
            reviewMenu
            recipeMenu
            returnMenu
            if hasWaitingWork {
                waitingMenu
            }
            Divider()
            Button("Zoom Active Pane", action: model.zoom)
            Button("Balance Panes", action: model.balance)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Pane actions")
        .accessibilityHint("Review, return, inspect waiting work, zoom, or balance panes")
    }

    private var hasWaitingWork: Bool {
        !model.consultations.isEmpty || !model.activeDelegations.isEmpty
    }

    private var waitingMenu: some View {
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
                            Divider()
                            Button("Cancel Tracking…", role: .destructive) { model.cancel(handoff) }
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
        .accessibilityLabel("Waiting collaboration")
        .accessibilityValue("\(model.consultations.count) questions, \(model.activeDelegations.count) delegations")
        .help("Inspect questions and delegated work awaiting a result")
        .accessibilityHint("Inspect work awaiting an answer or completion")
    }

    @ViewBuilder
    private func activePaneContext(maxWidth: CGFloat) -> some View {
        if let active = model.activePane {
            Text("\(active.displayName) · \(URL(fileURLWithPath: active.cwd).lastPathComponent)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth)
                .accessibilityLabel("Active pane")
                .accessibilityValue("\(active.displayName), \(active.cwd)")
                .help("\(active.displayName) · \(active.cwd)")
        }
    }

    private func recipeRunStrip(_ run: ActiveRecipeRun) -> some View {
        HStack(spacing: 8) {
            Text("LEAD")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text("\(run.recipeName) → \(run.leadName)")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Text("SUBMITTED")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 8)
            Button("Stop…") { model.interruptActiveRecipeRun() }
                .accessibilityLabel("Interrupt workspace lead")
                .accessibilityHint("Send Control-C after explicit confirmation")
            Button {
                model.dismissActiveRecipeRun()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Dismiss submitted recipe notice")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Color.accentColor.opacity(0.055))
        .help(run.instructions)
        .accessibilityElement(children: .contain)
    }

    private func activityStrip(_ handoff: RelayHandoff) -> some View {
        ViewThatFits(in: .horizontal) {
            wideActivityStrip(handoff)
            compactActivityStrip(handoff)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Color.secondary.opacity(0.045))
    }

    private func wideActivityStrip(_ handoff: RelayHandoff) -> some View {
        HStack(spacing: 7) {
            Text("ACTIVITY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Button(handoff.sourceName) { model.focus(handoff, target: false) }
                .accessibilityLabel("Focus source pane \(handoff.sourceName)")
                .accessibilityHint("Move to the pane that initiated this \(handoff.kind.rawValue)")
                .disabled(!model.canFocus(handoff.sourcePaneID))
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Button(handoff.targetName) { model.focus(handoff, target: true) }
                .accessibilityLabel("Focus target pane \(handoff.targetName)")
                .accessibilityHint("Move to the pane receiving this \(handoff.kind.rawValue)")
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
            .accessibilityRepresentation {
                Text("\(handoff.kind.rawValue.capitalized): \(WorkbenchAccessibility.subject(handoff.text))")
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(activityTiming(handoff, at: context.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Timing \(activityTiming(handoff, at: context.date))")
            }
            Text(activityStateLabel(handoff))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(activityColor(handoff))
                .accessibilityLabel("State \(activityStateLabel(handoff))")

            activityHistoryMenu
        }
    }

    private func compactActivityStrip(_ handoff: RelayHandoff) -> some View {
        HStack(spacing: 7) {
            Text("ACTIVITY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            Menu {
                Text(activitySubject(handoff.text))
                Divider()
                Button("Focus \(handoff.sourceName)") { model.focus(handoff, target: false) }
                    .disabled(!model.canFocus(handoff.sourcePaneID))
                Button("Focus \(handoff.targetName)") { model.focus(handoff, target: true) }
                    .disabled(!model.canFocus(handoff.targetPaneID))
            } label: {
                Text("\(handoff.sourceName) → \(handoff.targetName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }
            .accessibilityLabel(WorkbenchAccessibility.handoff(handoff))
            .help(activitySubject(handoff.text))
            .accessibilityHint("Open actions for this collaboration")

            Spacer(minLength: 6)

            Text(activityStateLabel(handoff))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(activityColor(handoff))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("State \(activityStateLabel(handoff))")

            activityHistoryMenu
        }
    }

    private var activityHistoryMenu: some View {
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
        .accessibilityLabel("Recent collaboration history")
        .accessibilityValue("\(min(model.workspaceHandoffs.count, 12)) recent item\(min(model.workspaceHandoffs.count, 12) == 1 ? "" : "s")")
        .help("Recent collaboration in this workspace")
        .accessibilityHint("Inspect recent handoffs in this workspace")
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

    private var connectionNotice: some View {
        workbenchNotice(
            icon: "bolt.horizontal.circle",
            title: "Relay disconnected",
            detail: "Terminal panes remain available. Ask, Return and agent-initiated handoffs are paused until the local core reconnects.",
            color: .orange,
            actionLabel: "Reconnect",
            action: model.retryConnections
        )
        .help(model.coreError ?? "The local Parley core is unavailable.")
    }

    @ViewBuilder
    private var paneNotice: some View {
        if let pane = model.activePane {
            switch model.activePaneState {
            case .empty, .running:
                EmptyView()
            case .stopped:
                workbenchNotice(
                    icon: "pause.circle",
                    title: "\(pane.displayName) is stopped",
                    detail: "This restored seat has not started a subscription CLI session.",
                    color: .secondary,
                    actionLabel: "Start \(pane.kind.label)",
                    action: { model.start(pane) }
                )
            case let .exited(status):
                workbenchNotice(
                    icon: "xmark.circle",
                    title: exitedTitle(pane: pane, status: status),
                    detail: "Final terminal output is preserved below. Restarting begins a new CLI process in the same pane and folder.",
                    color: status == 0 ? .secondary : .red,
                    actionLabel: "Restart…",
                    action: { model.restart(pane) }
                )
            case let .protocolStale(reportedVersion):
                workbenchNotice(
                    icon: "arrow.triangle.2.circlepath.circle",
                    title: "\(pane.displayName) has an older relay protocol",
                    detail: "This pane reports \(reportedVersion.map { "protocol v\($0)" } ?? "no protocol version"); Parley expects v\(AgentProtocol.version). Its terminal remains usable, but cross-vendor actions are disabled until restart.",
                    color: .orange,
                    actionLabel: "Restart…",
                    action: { model.restart(pane) }
                )
            case .relayUnavailable:
                workbenchNotice(
                    icon: "link.badge.plus",
                    title: "\(pane.displayName) is not connected to the relay",
                    detail: "Its terminal remains usable, but cross-vendor Ask and Return are disabled until the pane is restarted with relay credentials.",
                    color: .orange,
                    actionLabel: "Restart…",
                    action: { model.restart(pane) }
                )
            }
        }
    }

    private func workbenchNotice(
        icon: String,
        title: String,
        detail: String,
        color: Color,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.07))
    }

    private func exitedTitle(pane: TmuxPane, status: Int?) -> String {
        guard let status else { return "\(pane.displayName) exited" }
        return "\(pane.displayName) exited with status \(status)"
    }

    @ViewBuilder
    private var terminal: some View {
        if model.connectionState == .tmuxDisconnected {
            ContentUnavailableView {
                Label("Terminal server disconnected", systemImage: "terminal.fill")
            } description: {
                Text(model.tmuxError ?? "Parley cannot reach its isolated tmux server.")
            } actions: {
                Button("Reconnect", action: model.retryConnections)
                    .disabled(!model.canRetryConnections)
            }
        } else if model.activePaneState == .empty {
            ContentUnavailableView {
                Label("No pane in this workspace", systemImage: "rectangle.split.2x1")
            } description: {
                Text("Open another workspace or restore a saved layout to continue.")
            } actions: {
                Button("Open Workspace…", action: model.createWorkspace)
            }
        } else if let configuration = model.attachConfiguration {
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
            paneCreationItems(kind: kind)
        } label: {
            Label(kind.label, systemImage: kind == .shell ? "terminal" : "bubble.left.and.text.bubble.right")
        }
        .accessibilityLabel("New \(kind.label) pane")
        .accessibilityHint("Choose a split direction and folder")
    }

    @ViewBuilder
    private func paneCreationItems(kind: PaneKind) -> some View {
        Section("Workspace Folder") {
            Button("Split Right") { model.create(kind, direction: .horizontal) }
            Button("Split Below") { model.create(kind, direction: .vertical) }
        }
        Divider()
        Section("Another Folder") {
            Button("Split Right in Folder…") {
                model.createInChosenFolder(kind, direction: .horizontal)
            }
            Button("Split Below in Folder…") {
                model.createInChosenFolder(kind, direction: .vertical)
            }
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
                    Text(pane.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if pane.isWorkspaceLead {
                        Text("LEAD")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
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
                    switch WorkbenchStateProjection.pane(pane) {
                    case .empty, .running:
                        EmptyView()
                    case .stopped:
                        stateLabel("STOPPED", color: .secondary)
                    case let .exited(status):
                        stateLabel(status.map { "EXITED \($0)" } ?? "EXITED", color: .red)
                    case .protocolStale:
                        stateLabel("PROTOCOL STALE", color: .orange)
                    case .relayUnavailable:
                        stateLabel("RELAY OFF", color: .orange)
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
                    Text(processLabel)
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

    private var processLabel: String {
        switch WorkbenchStateProjection.pane(pane) {
        case .stopped: "not started"
        case let .exited(status): status.map { "exited \($0)" } ?? "exited"
        case .empty, .running, .protocolStale, .relayUnavailable: pane.currentCommand
        }
    }

    private func stateLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
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
