import AppKit
import ParleyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarVisible = true

    var body: some View {
        HSplitView {
            if sidebarVisible {
                sidebar
                    .frame(minWidth: 170, idealWidth: 220, maxWidth: 290, maxHeight: .infinity)
                    .background(EdgeToEdgeSidebarMaterial())
            }
            VStack(spacing: 0) {
                workspaceTabs
                if model.runtime.visibleMarker != nil {
                    Divider()
                    RuntimeBanner(runtime: model.runtime)
                }
                Divider()
                toolbar
                if let collision = model.activeWorktreeWriterCollisions.first {
                    Divider()
                    worktreeWriterNotice(collision, additional: model.activeWorktreeWriterCollisions.count - 1)
                }
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
                if let workflow = model.activeSupervisedWorkflow {
                    Divider()
                    supervisedWorkflowStrip(workflow)
                }
                if let activity = model.primaryActivity {
                    Divider()
                    activityStrip(activity)
                }
                if model.visiblePanes.count > 1, !sidebarVisible {
                    Divider()
                    paneFocusStrip
                }
                Divider()
                terminal
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            }
        }
        .parleyFlatWindowToolbar()
        .sheet(isPresented: $model.commandPalettePresented) {
            CommandPaletteView(model: model)
        }
        .sheet(isPresented: $model.setupPresented) {
            SetupView(model: model)
        }
        .sheet(item: $model.panePermissionRequest) { request in
            PermissionProfilePickerView(model: model, request: request)
        }
        .sheet(isPresented: $model.askManyComparisonPresented) {
            AskManyComparisonView(model: model)
        }
        .sheet(isPresented: $model.contextPackPresented) {
            ContextPackView(model: model)
        }
        .sheet(isPresented: $model.workspaceBriefPresented) {
            WorkspaceBriefView(model: model)
        }
        .sheet(isPresented: $model.pinnedContextSnippetsPresented) {
            PinnedContextSnippetLibraryView(model: model)
        }
        .sheet(isPresented: $model.supervisedWorkflowPresented) {
            SupervisedWorkflowView(model: model)
        }
        .sheet(isPresented: $model.worktreeBrowserPresented) {
            WorktreeBrowserView(model: model)
        }
        .sheet(isPresented: $model.releaseLifecyclePresented) {
            ReleaseLifecycleView(model: model)
        }
        .alert(
            "Parley needs attention",
            isPresented: Binding(
                get: { model.startupError != nil },
                set: { if !$0 { model.dismissStartupError() } }
            ),
            actions: {
                Button(model.startupRequiresQuit ? "Quit" : "OK") {
                    model.dismissStartupError()
                }
            },
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
                            latestFailure: model.latestFailure(for: pane.id),
                            permissionProfileName: model.permissionProfileName(for: pane)
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
                                if let workspace = model.workspaces.first(where: { $0.workspaceID == pane.workspaceID }) {
                                    model.clearWorkspaceLead(workspace)
                                }
                            }
                        } else {
                            Button("Make Workspace Lead") { model.setWorkspaceLead(pane) }
                        }
                        Divider()
                        Button(pane.role == nil ? "Set Routing Role…" : "Change Routing Role…") {
                            model.setRole(pane)
                        }
                        if pane.role != nil {
                            Button("Clear Routing Role") { model.clearRole(pane) }
                        }
                        Divider()
                        Button("Browser & Tool Capability…") {
                            model.showPaneToolCapabilitySummary(pane)
                        }
                    }
                    if pane.kind.isAgent && !pane.isStarted {
                        Button("Start") { model.start(pane) }
                    } else {
                        Button("Restart…") { model.restart(pane) }
                    }
                    let mobilityDestinations = model.mobilityDestinations(for: pane)
                    if !mobilityDestinations.isEmpty {
                        Divider()
                        Menu("Move to Workspace") {
                            ForEach(mobilityDestinations) { workspace in
                                Button(workspace.name) { model.movePane(pane, to: workspace) }
                            }
                        }
                        Menu("Clone Configuration to Workspace") {
                            ForEach(mobilityDestinations) { workspace in
                                Button(workspace.name) {
                                    model.clonePaneConfiguration(pane, to: workspace)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Close Pane…", role: .destructive) { model.close(pane) }
                }
            }
            .scrollContentBackground(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("FAVOURITE FOLDERS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: model.addFavouriteFolder) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add a favourite folder without changing this workspace")
                    .accessibilityLabel("Add favourite folder")
                    .accessibilityHint("Choose a folder to bookmark for opening as a workspace")
                }
                if model.favouriteFolders.isEmpty {
                    Text("Add folders for quick workspace access")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView(.vertical, showsIndicators: model.favouriteFolders.count > 5) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.favouriteFolders, id: \.self) { folder in
                                favouriteFolderRow(folder)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.favouriteFolders.count) * 26, 130))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("NEW PANE FOLDER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Menu {
                    Button("Choose New Pane Folder…", action: model.chooseFolder)
                    Button(model.isFavouriteFolder(model.defaultFolder) ? "Remove This Folder from Favourites" : "Add This Folder to Favourites") {
                        model.toggleFavouriteFolder(model.defaultFolder)
                    }
                    let favouriteAlternatives = model.favouriteFolders.filter {
                        !WorkspaceFolderIdentity.matches($0, model.defaultFolder)
                    }
                    if !favouriteAlternatives.isEmpty {
                        Divider()
                        Section("Favourites") {
                            ForEach(favouriteAlternatives, id: \.self) { folder in
                                Button("Use \(WorkspaceFolderIdentity.displayName(for: folder)) for New Panes") {
                                    model.setWorkspaceFolder(folder)
                                }
                                .help(folder)
                            }
                        }
                    }
                    let recentAlternatives = model.recentFolders.filter {
                        !WorkspaceFolderIdentity.matches($0, model.defaultFolder)
                            && !model.favouriteFolders.contains($0)
                    }
                    if !recentAlternatives.isEmpty {
                        Divider()
                        Section("Recent") {
                            ForEach(recentAlternatives, id: \.self) { folder in
                                Button("Use \(WorkspaceFolderIdentity.displayName(for: folder)) for New Panes") {
                                    model.setWorkspaceFolder(folder)
                                }
                                .help(folder)
                            }
                        }
                    }
                } label: {
                    Label(WorkspaceFolderIdentity.displayName(for: model.defaultFolder), systemImage: "folder")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("New pane folder")
                .accessibilityValue(model.defaultFolder)
                .accessibilityHint("Choose where newly opened toolbar panes start")
                .help("New panes in this workspace open in \(model.defaultFolder). Running panes keep their own folders.")
            }
            .padding(12)
        }
    }

    private func favouriteFolderRow(_ folder: String) -> some View {
        let name = WorkspaceFolderIdentity.displayName(for: folder)
        let matchingWorkspaces = WorkspaceFolderRouting.matches(folder: folder, in: model.workspaces)
        let activeWorkspace = matchingWorkspaces.first(where: \.isActive)
        let isActive = activeWorkspace != nil
        let actionDescription = if isActive {
            "Already active: \(activeWorkspace?.name ?? "this workspace") at \(folder)"
        } else if matchingWorkspaces.count == 1 {
            "Switch to \(matchingWorkspaces[0].name) at \(folder)"
        } else if matchingWorkspaces.count > 1 {
            "Choose from \(matchingWorkspaces.count) workspaces at \(folder)"
        } else {
            "Open a new workspace at \(folder)"
        }
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
                } else if matchingWorkspaces.count > 1 {
                    Text("\(matchingWorkspaces.count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .accessibilityHidden(true)
                } else if matchingWorkspaces.count == 1 {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
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
        .help(actionDescription)
        .accessibilityLabel("Favourite folder \(name)")
        .accessibilityValue(
            isActive
                ? "Active workspace"
                : (matchingWorkspaces.isEmpty ? "Not open" : "\(matchingWorkspaces.count) open workspace\(matchingWorkspaces.count == 1 ? "" : "s")")
        )
        .accessibilityHint(actionDescription)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            Button("Open New Workspace Here") {
                model.createNewWorkspace(folder: folder)
            }
            Divider()
            Button("Remove from Favourites") {
                model.toggleFavouriteFolder(folder)
            }
        }
    }

    private func workspaceTabHelp(_ workspace: TmuxWorkspace) -> String {
        let folders = WorkspaceFolderIdentity.matches(workspace.homeFolder, workspace.defaultFolder)
            ? ["Home and new panes: \(workspace.homeFolder)"]
            : [
                "Home: \(workspace.homeFolder)",
                "New panes: \(workspace.defaultFolder)",
            ]
        return (folders + workspaceTabStatusDetails(workspace) + ["Control-Tab switches workspaces"])
            .joined(separator: "\n")
    }

    private func workspaceTabAccessibilityValue(_ workspace: TmuxWorkspace) -> String {
        ([workspace.isActive ? "Selected" : "Not selected"] + workspaceTabStatusDetails(workspace))
            .joined(separator: ", ")
    }

    private func workspaceTabStatusDetails(_ workspace: TmuxWorkspace) -> [String] {
        var details = ["Automation \(workspace.automationPolicy.label)"]
        let waiting = model.waitingCount(for: workspace.id)
        if waiting > 0 { details.append("\(waiting) waiting") }
        let failures = model.failureCount(for: workspace.id)
        if failures > 0 {
            details.append(
                model.requiresHumanAttention(workspace.id)
                    ? "\(failures) need human attention"
                    : "\(failures) failed"
            )
        }
        let unread = model.unreadResultCount(forWorkspace: workspace.id)
        if unread > 0 { details.append("\(unread) unread") }
        if model.hasWorktreeWriterCollision(workspaceID: workspace.id) {
            details.append("Shared worktree writer warning")
        }
        return details
    }

    private func paneAccessibilityValue(_ pane: TmuxPane) -> String {
        let folder = WorkspaceFolderIdentity.displayName(for: pane.cwd)
        if pane.isInCopyMode {
            return "copy mode, \(folder)"
        }
        let state: String = switch WorkbenchStateProjection.pane(pane) {
        case .empty: "empty"
        case .running: pane.isActive ? "selected" : "running"
        case .stopped: "stopped"
        case let .exited(status): status.map { "exited with status \($0)" } ?? "exited"
        case .protocolStale: "protocol restart required"
        case .relayUnavailable: "relay restart required"
        }
        let lead = pane.isWorkspaceLead ? ", workspace lead" : ""
        let role = pane.role.map { ", routing role \($0)" } ?? ""
        return "\(state)\(lead)\(role), \(folder)"
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
                                let waiting = model.waitingCount(for: workspace.id)
                                let failures = model.failureCount(for: workspace.id)
                                let requiresAttention = model.requiresHumanAttention(workspace.id)
                                let unread = model.unreadResultCount(forWorkspace: workspace.id)
                                Text(workspace.automationPolicy == .off ? "OFF" : (workspace.automationPolicy == .askAnswer ? "ASK" : "DELEGATE"))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(workspace.automationPolicy == .off ? Color.secondary : Color.accentColor)
                                if waiting > 0 {
                                    Label("\(waiting)", systemImage: "clock")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .labelStyle(.titleAndIcon)
                                }
                                if failures > 0 {
                                    Label(
                                        "\(failures)",
                                        systemImage: requiresAttention ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
                                    )
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(requiresAttention ? Color.orange : Color.red)
                                        .labelStyle(.titleAndIcon)
                                }
                                if unread > 0 {
                                    Label("\(unread)", systemImage: "envelope.badge")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .labelStyle(.titleAndIcon)
                                }
                                if model.hasWorktreeWriterCollision(workspaceID: workspace.id) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.orange)
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
                        .help(workspaceTabHelp(workspace))
                        .accessibilityLabel("Workspace \(workspace.name)")
                        .accessibilityValue(workspaceTabAccessibilityValue(workspace))
                        .accessibilityHint("Open workspace with home folder \(workspace.homeFolder)")
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
                            if model.panes.contains(where: { $0.workspaceID == workspace.workspaceID && $0.isWorkspaceLead }) {
                                Button("Clear Workspace Lead") { model.clearWorkspaceLead(workspace) }
                            }
                            Button(model.isFavouriteFolder(workspace.homeFolder) ? "Remove Home from Favourites" : "Add Home to Favourites") {
                                model.toggleFavouriteFolder(workspace.homeFolder)
                            }
                            Button("Open New Workspace Here") {
                                model.createNewWorkspace(folder: workspace.homeFolder)
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
                Button("Open or Focus Folder…", action: model.createWorkspace)
                Button("Open New Workspace…", action: model.createAdditionalWorkspace)
                Button("Open Existing Worktree as Workspace…", action: model.showWorktreeBrowser)
                Button("Save Current Layout…", action: model.saveActiveWorkspaceLayout)
                Button("Save Current as Team Template…", action: model.saveActiveWorkspaceAsTeamTemplate)
                if !model.favouriteFolders.isEmpty {
                    Divider()
                    Section("Favourite Folders") {
                        ForEach(model.favouriteFolders, id: \.self) { folder in
                            Button(WorkspaceFolderIdentity.displayName(for: folder)) {
                                model.createWorkspace(folder: folder)
                            }
                            .help(folder)
                        }
                    }
                }
                let nonFavouriteRecents = model.recentFolders.filter { !model.isFavouriteFolder($0) }
                if !nonFavouriteRecents.isEmpty {
                    Divider()
                    Section("Recent Folders") {
                        ForEach(nonFavouriteRecents, id: \.self) { folder in
                            Button(WorkspaceFolderIdentity.displayName(for: folder)) {
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
                if !model.teamTemplates.isEmpty {
                    Divider()
                    Section("Team Templates") {
                        ForEach(model.teamTemplates) { template in
                            Menu(template.name) {
                                Button("Apply to Folder…") { model.apply(template) }
                                Divider()
                                Button("Delete Team Template…", role: .destructive) { model.delete(template) }
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
            .accessibilityHint("Choose a folder, existing Git worktree, favourite, recent folder, or saved layout")
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
            contextPackMenu
            recipeMenu
            returnMenu

            if hasWaitingWork {
                Divider().frame(height: 18)
                waitingMenu
            }

            Spacer()
            activePaneContext(maxWidth: 240)
            Button(action: model.toggleCopyMode) {
                Image(systemName: model.activePane?.isInCopyMode == true ? "xmark.square" : "doc.on.doc")
            }
            .disabled(model.activePane == nil)
            .accessibilityLabel(model.activePane?.isInCopyMode == true ? "Exit copy mode" : "Enter copy mode")
            .help(model.activePane?.isInCopyMode == true ? "Exit pane history copy mode" : "Select and copy from pane history")
            .accessibilityHint("Use tmux-owned scrollback; drag to select and release to copy to the macOS clipboard")
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
            if model.askManyComparisonRun != nil || model.canCompareAskMany {
                Divider()
                if let comparison = model.askManyComparisonRun {
                    Button(comparison.isRunning ? "Open Active Comparison" : "Open Last Comparison") {
                        model.presentAskManyComparison()
                    }
                }
                Button("Compare Independently…") { model.compareAskMany() }
                    .disabled(!model.canCompareAskMany)
            }
        } label: {
            Label("Ask", systemImage: "arrow.turn.up.right")
        }
        .accessibilityLabel("Ask another vendor")
        .accessibilityValue("\(model.askTargets.count) available target\(model.askTargets.count == 1 ? "" : "s")")
        .accessibilityHint("Choose another agent pane for a correlated question")
        .disabled(model.askTargets.isEmpty && model.askManyComparisonRun == nil)
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

    private var contextPackMenu: some View {
        Menu {
            if !model.pendingContextReviews.isEmpty {
                Section("Agent Drafts Awaiting Review") {
                    ForEach(model.pendingContextReviews) { review in
                        Button {
                            model.presentContextReview(review)
                        } label: {
                            let target = review.requestedTargetName.map { " → \($0)" } ?? ""
                            Label(
                                "\(review.sourcePaneName)\(target) · \(review.state == .awaitingReview ? "awaiting review" : "draft")",
                                systemImage: review.state == .awaitingReview ? "person.crop.circle.badge.clock" : "doc.badge.ellipsis"
                            )
                        }
                    }
                }
                Divider()
            }
            if let draft = model.contextPackDraft {
                Button("Open Context Pack “\(draft.pack.name)”") { model.presentContextPack() }
                Divider()
            }
            Button("New Context Pack…") { model.newContextPack() }
                .disabled(!model.canCreateContextPack)
            if model.activeWorkspace != nil {
                Divider()
                Section("Workspace Brief") {
                    Button(model.activeWorkspaceBrief == nil ? "Create Workspace Brief…" : "Edit Workspace Brief…") {
                        model.editWorkspaceBrief()
                    }
                    if model.activeWorkspaceBrief != nil {
                        Button("New Context Pack with Workspace Brief…") {
                            model.newContextPackWithWorkspaceBrief()
                        }
                        .disabled(!model.canCreateContextPack)
                    }
                }
            }
            Divider()
            Section("Reusable Context") {
                Button("Manage Pinned Snippets…") {
                    model.presentPinnedContextSnippets()
                }
            }
            Divider()
            Button {
                model.requestHelp(topicID: "context-model")
                openWindow(id: "help")
            } label: {
                Label("How Context Works", systemImage: "questionmark.circle")
            }
        } label: {
            Label(
                model.pendingContextReviews.isEmpty ? "Context" : "Context \(model.pendingContextReviews.count)",
                systemImage: model.pendingContextReviews.isEmpty ? "shippingbox" : "shippingbox.fill"
            )
        }
        .accessibilityLabel("Context packs and references")
        .accessibilityValue(
            model.pendingContextReviews.isEmpty
                ? (model.contextPackDraft.map { "\($0.pack.parts.count) sources" } ?? "No draft")
                : "\(model.pendingContextReviews.count) agent draft\(model.pendingContextReviews.count == 1 ? "" : "s") awaiting review"
        )
        .help("Manage reusable context, edit the workspace brief or assemble explicit attributed sources before a cross-vendor handoff")
        .accessibilityHint("Manage pinned context and the workspace brief, or open an editable attributed context pack")
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
            Section("Bounded Sequence") {
                if model.activeSupervisedWorkflow != nil {
                    Button("Open Active Workflow…") { model.presentSupervisedWorkflow() }
                } else {
                    Button("Plan → Review → Implement → Verify…") {
                        model.startSupervisedWorkflow()
                    }
                    .disabled(!model.canStartSupervisedWorkflow)
                }
                if !model.recentSupervisedWorkflows.isEmpty {
                    Menu("Recent Workflows") {
                        ForEach(model.recentSupervisedWorkflows.prefix(8)) { run in
                            Button {
                                model.presentSupervisedWorkflow(run)
                            } label: {
                                Text("\(run.phase.label) · \(run.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }
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
        .help("Run a one-shot recipe or a bounded human-checkpointed cross-vendor sequence")
        .accessibilityHint("Choose a recipe or the Plan, Review, Implement, Verify sequence")
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
            contextPackMenu
            recipeMenu
            returnMenu
            if hasWaitingWork {
                waitingMenu
            }
            Divider()
            Button(model.activePane?.isInCopyMode == true ? "Exit Copy Mode" : "Enter Copy Mode", action: model.toggleCopyMode)
                .disabled(model.activePane == nil)
            Button("Zoom Active Pane", action: model.zoom)
            Button("Balance Panes", action: model.balance)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Pane actions")
        .accessibilityHint("Review, return, inspect waiting work, copy pane history, zoom, or balance panes")
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
            Text("\(active.displayName) · \(WorkspaceFolderIdentity.displayName(for: active.cwd))")
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

    private func supervisedWorkflowStrip(_ run: SupervisedWorkflowRun) -> some View {
        HStack(spacing: 8) {
            Text("WORKFLOW")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(run.phase.label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            if run.phase == .awaitingImplementationApproval || run.phase == .awaitingCompletionApproval {
                Text("HUMAN CHECKPOINT")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Button("Open") { model.presentSupervisedWorkflow() }
            Button("End…", role: .destructive) { model.interruptSupervisedWorkflow() }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Color.accentColor.opacity(0.055))
        .help("\(run.name) · \(run.phase.label)")
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
                        if item.attention == .permissionRequired {
                            Button("Open Permission Guide") {
                                model.requestHelp(topicID: "cli-permissions")
                                openWindow(id: "help")
                            }
                        }
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

    private func worktreeWriterNotice(
        _ collision: WorktreeWriterCollision,
        additional: Int
    ) -> some View {
        let writers = collision.writers.map {
            let enforcement = $0.enforcement?.label ?? "enforcement unknown"
            return "\($0.paneName) (\($0.permissionProfileName), \(enforcement))"
        }.joined(separator: ", ")
        let suffix = additional > 0 ? " · \(additional) more shared worktree\(additional == 1 ? "" : "s")" : ""
        return workbenchNotice(
            icon: "exclamationmark.triangle",
            title: "Shared worktree writers\(suffix)",
            detail: "\(writers) have profiles that explicitly allow project writes at \(collision.worktree.path). Permission evidence only; Parley has not inferred file activity.",
            color: .orange,
            actionLabel: "Worktrees…",
            action: { model.showWorktreeBrowser(sourceFolder: collision.worktree.path) }
        )
        .help("Exact canonical worktree: \(collision.worktree.path)\nA quiet pane does not prove that concurrent writes are safe.")
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

    private var paneFocusStrip: some View {
        HStack(spacing: 8) {
            Text(model.activeWorkspace?.isZoomed == true ? "ZOOMED PANE" : "PANES")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.visiblePanes) { pane in
                        paneFocusButton(pane)
                    }
                }
                .padding(.vertical, 3)
            }

            if model.activeWorkspace?.isZoomed == true {
                Button("Show Grid", action: model.zoom)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Return to the full pane grid")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.secondary.opacity(0.035))
        .accessibilityElement(children: .contain)
    }

    private func paneFocusButton(_ pane: TmuxPane) -> some View {
        Button {
            model.select(pane)
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(paneFocusColor(pane.kind))
                    .frame(width: 3, height: 16)
                    .accessibilityHidden(true)
                Text(pane.displayName)
                    .font(.system(size: 10, weight: pane.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let role = pane.role {
                    Text("@\(role)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
                if let state = paneFocusState(pane) {
                    Text(state.label)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(state.color)
                }
            }
            .foregroundStyle(pane.isActive ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(pane.isActive ? Color.accentColor.opacity(0.08) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(pane.isActive ? Color.accentColor : Color.clear)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .help(paneFocusHelp(pane))
        .accessibilityLabel("Focus \(pane.displayName), \(pane.kind.label) pane")
        .accessibilityValue(paneAccessibilityValue(pane))
        .accessibilityHint(
            model.activeWorkspace?.isZoomed == true
                ? "Show this pane while keeping the workspace zoomed"
                : "Focus this pane in the visible grid"
        )
    }

    private func paneFocusState(_ pane: TmuxPane) -> (label: String, color: Color)? {
        if pane.isInCopyMode { return ("COPY", .accentColor) }
        if let failure = model.latestFailure(for: pane.id) {
            return failure.attention == nil ? ("FAILED", .red) : ("ATTENTION", .orange)
        }
        let awaiting = model.awaitingAnswerCount(for: pane.id)
        if pane.returnToPaneID != nil || awaiting > 0 {
            return (awaiting > 1 ? "RETURN \(awaiting)" : "RETURN", .accentColor)
        }
        let unread = model.unreadResultCount(forPane: pane.id)
        if unread > 0 { return (unread > 1 ? "RESULT \(unread)" : "RESULT", .accentColor) }
        return switch WorkbenchStateProjection.pane(pane) {
        case .empty, .running: nil
        case .stopped: ("STOPPED", .secondary)
        case let .exited(status): (status.map { "EXITED \($0)" } ?? "EXITED", .red)
        case .protocolStale: ("PROTOCOL", .orange)
        case .relayUnavailable: ("RELAY OFF", .orange)
        }
    }

    private func paneFocusColor(_ kind: PaneKind) -> Color {
        switch kind {
        case .claude: .orange
        case .codex: .blue
        case .agy: .purple
        case .copilot: .green
        case .shell: .secondary
        }
    }

    private func paneFocusHelp(_ pane: TmuxPane) -> String {
        let action = model.activeWorkspace?.isZoomed == true
            ? "Focus while keeping the workspace zoomed"
            : "Focus in the visible pane grid"
        let state = pane.isInCopyMode
            ? "Copy mode: drag to select, scroll through history, and release to copy"
            : "Enter Copy Mode when a mouse-aware CLI captures normal dragging"
        return [action, pane.cwd, state].joined(separator: "\n")
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
        } else if model.windowsAsPanesPreview, !model.previewWindowViewers.isEmpty {
            previewViewerSplit
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

    /// Windows-as-panes preview: one confined viewer client per member window,
    /// split natively. The active pane's viewer shares the legacy terminal
    /// handle so focus and selection call sites keep working.
    private var previewViewerSplit: some View {
        HSplitView {
            ForEach(model.previewWindowViewers) { viewer in
                previewViewerLeaf(viewer)
                    .background(Color(nsColor: NSColor(white: 0.085, alpha: 1)))
            }
        }
    }

    @ViewBuilder
    private func previewViewerLeaf(_ viewer: AppModel.PreviewWindowViewer) -> some View {
        let handle = viewer.containsActivePane
            ? model.terminalHandle
            : model.viewerHandle(forWindow: viewer.windowID)
        if viewer.isSinglePane {
            // Native scrollback and selection; no pty client, no copy mode.
            ControlTerminalHost(
                paneID: viewer.representativePaneID,
                windowID: viewer.windowID,
                model: model,
                handle: handle
            )
        } else if let configuration = model.viewerAttachConfiguration(
            representativePaneID: viewer.representativePaneID
        ) {
            // Legacy multi-pane grids keep the confined pty viewer until the
            // marked break-pane migration retires them.
            TerminalHost(configuration: configuration, handle: handle)
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
        Section("New Pane Folder") {
            Button("Split Right") { model.create(kind, direction: .horizontal) }
            Button("Split Below") { model.create(kind, direction: .vertical) }
        }
        if let activePane = model.activePane,
           !WorkspaceFolderIdentity.matches(activePane.cwd, model.defaultFolder) {
            Divider()
            Section("Active Pane Folder") {
                Button("Split Right Here") {
                    model.createInActivePaneFolder(kind, direction: .horizontal)
                }
                Button("Split Below Here") {
                    model.createInActivePaneFolder(kind, direction: .vertical)
                }
            }
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
    let permissionProfileName: String?

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
                    if let role = pane.role {
                        Text("@\(role)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                    if let permissionProfileName {
                        Text(permissionProfileName.uppercased())
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
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
                    if pane.isInCopyMode {
                        stateLabel("COPY", color: .accentColor)
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
        WorkspaceFolderIdentity.displayName(for: pane.cwd)
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
        let permission = permissionProfileName.map { name in
            let enforcement = pane.permissionEnforcement?.label ?? "not recorded"
            return "Permissions: \(name) · \(enforcement)"
        }
        let role = pane.role.map { "Routing role: \($0)" }
        guard let projectContext else {
            return [pane.cwd, role, permission].compactMap { $0 }.joined(separator: "\n")
        }
        let state = projectContext.isDirty ? "dirty" : "clean"
        return [
            pane.cwd,
            "Git: \(projectContext.branch) · \(state)",
            role,
            permission,
        ].compactMap { $0 }.joined(separator: "\n")
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

private struct EdgeToEdgeSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private extension View {
    @ViewBuilder
    func parleyFlatWindowToolbar() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
