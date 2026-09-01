import AppKit
import ParleyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarVisible = true
    @State private var sidebarQuery = ""
    @State private var workspacesExpanded = true
    @State private var participantsExpanded = true
    @State private var favouritesExpanded = true
    @State private var collapsedWorkspaceFolderIDs: Set<String> = []

    var body: some View {
        HSplitView {
            if sidebarVisible {
                sidebar
                    .frame(minWidth: 184, idealWidth: 218, maxWidth: 276, maxHeight: .infinity)
                    .background(EdgeToEdgeSidebarMaterial())
            }
            VStack(spacing: 0) {
                if !sidebarVisible {
                    workspaceTabs
                    Divider()
                }
                toolbar
                Divider()
                if model.focusCanvasPaneID != nil {
                    focusCanvasStrip
                    Divider()
                }
                if let collision = model.activeWorktreeWriterCollisions.first {
                    worktreeWriterNotice(collision, additional: model.activeWorktreeWriterCollisions.count - 1)
                    Divider()
                }
                if model.connectionState == .coreDisconnected {
                    connectionNotice
                    Divider()
                }
                if model.terminalAvailable, model.activePaneState != .running, model.activePaneState != .empty {
                    paneNotice
                    Divider()
                }
                if let recipe = model.activeRecipeRun {
                    recipeRunStrip(recipe)
                    Divider()
                }
                if let workflow = model.activeSupervisedWorkflow {
                    supervisedWorkflowStrip(workflow)
                    Divider()
                }
                if let activity = model.primaryActivity {
                    activityStrip(activity)
                    Divider()
                }
                if model.handoffComposerDraft != nil {
                    handoffComposer
                    Divider()
                }
                if model.visiblePanes.count > 1, !sidebarVisible {
                    paneFocusStrip
                    Divider()
                }
                terminal
                Divider()
                workbenchStatusBar
            }
            if model.collaborationDockVisible {
                collaborationDock
                    .frame(minWidth: 220, idealWidth: 252, maxWidth: 310, maxHeight: .infinity)
            }
        }
        .frame(minWidth: model.collaborationDockVisible ? 980 : 760, minHeight: 620)
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
        .sheet(isPresented: $model.terminalFontSettingsPresented) {
            TerminalFontSettingsView(model: model)
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
            if model.workspaces.count + model.visiblePanes.count > 8 {
                TextField("Filter workspaces and panes", text: $sidebarQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .padding(.horizontal, 9)
                    .padding(.top, 8)
                    .accessibilityLabel("Filter sidebar")
            }
            List {
                Section {
                    if workspacesExpanded {
                        ForEach(filteredWorkspaces) { workspace in
                            workspaceSidebarRow(workspace)
                        }
                        .onMove { offsets, destination in
                            guard sidebarQuery.isEmpty else { return }
                            model.moveWorkspaces(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Button {
                            workspacesExpanded.toggle()
                        } label: {
                            Label("WORKSPACES", systemImage: workspacesExpanded ? "chevron.down" : "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(workspacesExpanded ? "Collapse workspaces" : "Expand workspaces")
                        Spacer()
                        workspaceActionsMenu
                    }
                }

                Section {
                    if participantsExpanded {
                        ForEach(filteredVisiblePanes) { pane in
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
                            .listRowBackground(pane.isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                            .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
                            .contextMenu {
                                paneContextMenu(pane)
                            }
                        }
                    }
                } header: {
                    Button {
                        participantsExpanded.toggle()
                    } label: {
                        Label("PARTICIPANTS", systemImage: participantsExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(participantsExpanded ? "Collapse participants" : "Expand participants")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Button {
                        favouritesExpanded.toggle()
                    } label: {
                        Label("FAVOURITE FOLDERS", systemImage: favouritesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favouritesExpanded ? "Collapse favourite folders" : "Expand favourite folders")
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
                if favouritesExpanded, !model.favouriteFolders.isEmpty {
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
                    if model.activeWorkspace?.newPaneFolder != nil {
                        Button("Clear New Pane Folder", action: model.clearWorkspaceNewPaneFolder)
                    }
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
                    Label(
                        model.activeWorkspace?.newPaneFolder.map(WorkspaceFolderIdentity.displayName(for:))
                            ?? "Follows Active Pane",
                        systemImage: model.activeWorkspace?.newPaneFolder == nil ? "arrow.turn.down.right" : "folder"
                    )
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("New pane folder")
                .accessibilityValue(model.activeWorkspace?.newPaneFolder ?? "Follows active pane")
                .accessibilityHint("Choose where newly opened toolbar panes start")
                .help(model.activeWorkspace?.newPaneFolder.map {
                    "New panes in this workspace open in \($0). Running panes keep their own folders."
                } ?? "No fixed New Pane Folder. Shell panes follow the active pane; creating an agent asks for its working folder.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var filteredWorkspaces: [WorkbenchWorkspace] {
        let query = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.workspaces }
        return model.workspaces.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.attachedFolders.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var filteredVisiblePanes: [WorkbenchPane] {
        let query = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.layoutOrderedVisiblePanes }
        return model.layoutOrderedVisiblePanes.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.kind.label.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
                || ($0.role?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func workspaceSidebarRow(_ workspace: WorkbenchWorkspace) -> some View {
        let paneCount = model.panes.count { $0.workspaceID == workspace.workspaceID }
        let waiting = model.waitingCount(for: workspace.id)
        let failures = model.failureCount(for: workspace.id)
        let unread = model.unreadResultCount(forWorkspace: workspace.id)
        let foldersExpanded = !collapsedWorkspaceFolderIDs.contains(workspace.workspaceID)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                if workspace.isFolderless {
                    Color.clear
                        .frame(width: 17, height: 22)
                        .accessibilityHidden(true)
                } else {
                    Button {
                        if foldersExpanded {
                            collapsedWorkspaceFolderIDs.insert(workspace.workspaceID)
                        } else {
                            collapsedWorkspaceFolderIDs.remove(workspace.workspaceID)
                        }
                    } label: {
                        Image(systemName: foldersExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(foldersExpanded ? "Hide attached folders" : "Show attached folders")
                    .accessibilityLabel(
                        foldersExpanded
                            ? "Collapse folders attached to \(workspace.name)"
                            : "Expand folders attached to \(workspace.name)"
                    )
                }
                Button {
                    model.select(workspace)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: workspace.isFolderless
                            ? "square.stack.3d.up"
                            : (workspace.isActive ? "folder.fill" : "folder"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(workspace.isActive ? Color.accentColor : Color.secondary)
                            .frame(width: 15)
                        Text(workspace.name)
                            .font(.system(size: 11, weight: workspace.isActive ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if failures > 0 {
                            Image(systemName: model.requiresHumanAttention(workspace.id) ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(model.requiresHumanAttention(workspace.id) ? Color.orange : Color.red)
                        } else if unread > 0 {
                            Image(systemName: "envelope.badge.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        } else if waiting > 0 {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("\(paneCount)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(workspace.isActive ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(workspaceTabHelp(workspace))
                .accessibilityLabel("Workspace \(workspace.name)")
                .accessibilityValue(workspaceTabAccessibilityValue(workspace))
                .accessibilityHint(workspace.isFolderless
                    ? "Open folderless workspace"
                    : "Open workspace with \(workspace.attachedFolders.count) attached folder\(workspace.attachedFolders.count == 1 ? "" : "s")")
                .contextMenu {
                    workspaceContextMenu(workspace)
                }
            }

            if foldersExpanded {
                if workspace.isFolderless {
                    folderlessWorkspaceRow(workspace)
                } else {
                    ForEach(workspace.attachedFolders, id: \.self) { folder in
                        workspaceFolderRow(folder, workspace: workspace)
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
        .listRowBackground(Color.clear)
    }

    private func folderlessWorkspaceRow(_ workspace: WorkbenchWorkspace) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text("No folders attached")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Attach…") {
                model.attachFolder(to: workspace)
            }
            .font(.system(size: 9, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Attach a folder to \(workspace.name)")
        }
        .padding(.leading, 35)
        .padding(.trailing, 7)
        .frame(minHeight: 24)
    }

    private func workspaceFolderRow(_ folder: String, workspace: WorkbenchWorkspace) -> some View {
        let name = WorkspaceFolderIdentity.displayName(for: folder)
        let displayPath = (WorkspaceFolderIdentity.normalized(folder) as NSString).abbreviatingWithTildeInPath
        let isNewPaneFolder = workspace.newPaneFolder.map {
            WorkspaceFolderIdentity.matches($0, folder)
        } ?? false

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isNewPaneFolder {
                        Text("NEW PANES")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(displayPath)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 35)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(folder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Attached folder \(name)")
        .accessibilityValue(isNewPaneFolder ? "\(displayPath), used for new panes" : displayPath)
        .contextMenu {
            Button("Use for New Panes") { model.setWorkspaceFolder(folder) }
            Button(model.isFavouriteFolder(folder) ? "Remove from Favourites" : "Add to Favourites") {
                model.toggleFavouriteFolder(folder)
            }
            Button("Open New Workspace Here") {
                model.createNewWorkspace(folder: folder)
            }
            Divider()
            Button("Detach from Workspace", role: .destructive) {
                model.detachFolder(folder, from: workspace)
            }
        }
    }

    private var workspaceActionsMenu: some View {
        Menu {
            workspaceCreationMenuItems
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Create workspace")
        .help("Create workspace")
        .accessibilityHint("Create a folderless workspace or create one from a saved layout or team template")
    }

    @ViewBuilder
    private var workspaceCreationMenuItems: some View {
        Button("New Workspace", action: model.createWorkspace)
        if !model.savedLayouts.isEmpty {
            Menu("From Saved Layout") {
                ForEach(model.savedLayouts) { layout in
                    Button(layout.name) { model.createWorkspace(from: layout) }
                }
            }
        }
        if !model.teamTemplates.isEmpty {
            Menu("From Team Template") {
                ForEach(model.teamTemplates) { template in
                    Button(template.name) { model.apply(template) }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(_ workspace: WorkbenchWorkspace) -> some View {
        Button("Rename…") { model.rename(workspace) }
        Button("Save Layout…") { model.saveLayout(of: workspace) }
        Button("Save as Team Template…") { model.saveActiveWorkspaceAsTeamTemplate() }
            .disabled(!workspace.isActive)
        if !model.savedLayouts.isEmpty {
            Menu("Saved Layouts") {
                ForEach(model.savedLayouts) { layout in
                    Menu(layout.name) {
                        Button("Create New Workspace") { model.createWorkspace(from: layout) }
                        Button("Replace This Workspace…") {
                            model.open(layout, replacing: workspace)
                        }
                        Divider()
                        Button("Delete Saved Layout…", role: .destructive) { model.delete(layout) }
                    }
                }
            }
        }
        if !model.teamTemplates.isEmpty {
            Menu("Team Templates") {
                ForEach(model.teamTemplates) { template in
                    Menu(template.name) {
                        Button("Create Workspace…") { model.apply(template) }
                        Divider()
                        Button("Delete Team Template…", role: .destructive) { model.delete(template) }
                    }
                }
            }
        }
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
        Button("Attach Folder…") { model.attachFolder(to: workspace) }
        if !workspace.attachedFolders.isEmpty {
            Menu("Attached Folders") {
                ForEach(Array(workspace.attachedFolders.enumerated()), id: \.element) { index, folder in
                    Menu(WorkspaceFolderIdentity.displayName(for: folder)) {
                        Button("Use for New Panes") { model.setWorkspaceFolder(folder) }
                        Button(model.isFavouriteFolder(folder) ? "Remove from Favourites" : "Add to Favourites") {
                            model.toggleFavouriteFolder(folder)
                        }
                        Button("Open New Workspace Here") {
                            model.createNewWorkspace(folder: folder)
                        }
                        Divider()
                        Button("Move Earlier") {
                            model.moveAttachedFolder(folder, in: workspace, by: -1)
                        }
                        .disabled(index == 0)
                        Button("Move Later") {
                            model.moveAttachedFolder(folder, in: workspace, by: 1)
                        }
                        .disabled(index == workspace.attachedFolders.count - 1)
                        Divider()
                        Button("Detach from Workspace", role: .destructive) {
                            model.detachFolder(folder, from: workspace)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Move Workspace Up") { model.move(workspace, by: -1) }
            .disabled(!model.canMove(workspace, by: -1))
        Button("Move Workspace Down") { model.move(workspace, by: 1) }
            .disabled(!model.canMove(workspace, by: 1))
        Divider()
        Button("Close Workspace…", role: .destructive) { model.close(workspace) }
            .disabled(model.workspaces.count == 1)
    }

    @ViewBuilder
    private func paneContextMenu(_ pane: WorkbenchPane) -> some View {
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
            if pane.isStarted {
                Button("Folder Access…") {
                    model.showFolderAccess(pane)
                }
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
        Button("Terminal Font…") { model.showTerminalFontSettings() }
        Divider()
        Button("Close Pane…", role: .destructive) { model.close(pane) }
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

    private func workspaceTabHelp(_ workspace: WorkbenchWorkspace) -> String {
        var folders = workspace.attachedFolders.isEmpty
            ? ["No folders attached"]
            : ["Attached: \(workspace.attachedFolders.joined(separator: ", "))"]
        folders.append(workspace.newPaneFolder.map { "New panes: \($0)" } ?? "New panes: follows active pane")
        return (folders + workspaceTabStatusDetails(workspace) + ["Control-Tab switches workspaces"])
            .joined(separator: "\n")
    }

    private func workspaceTabAccessibilityValue(_ workspace: WorkbenchWorkspace) -> String {
        ([workspace.isActive ? "Selected" : "Not selected"] + workspaceTabStatusDetails(workspace))
            .joined(separator: ", ")
    }

    private func workspaceTabStatusDetails(_ workspace: WorkbenchWorkspace) -> [String] {
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

    private func paneAccessibilityValue(_ pane: WorkbenchPane) -> String {
        let folder = WorkspaceFolderIdentity.displayName(for: pane.cwd)
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
    private func paneRecoveryButton(_ pane: WorkbenchPane) -> some View {
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
                        .accessibilityHint(workspace.isFolderless
                            ? "Open folderless workspace"
                            : "Open workspace with \(workspace.attachedFolders.count) attached folder\(workspace.attachedFolders.count == 1 ? "" : "s")")
                        .contextMenu {
                            workspaceContextMenu(workspace)
                        }
                    }
                }
            }

            Menu {
                workspaceCreationMenuItems
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Create or open workspace")
            .help("Create or open workspace")
            .accessibilityHint("Create a folderless workspace or open a folder, worktree, favourite, recent folder, or saved layout")
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
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var wideToolbar: some View {
        HStack(spacing: 7) {
            workspaceIdentity(maxWidth: 210)
            Divider().frame(height: 18)
            newPaneMenu
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
            Button(action: { model.toggleFocusCanvas() }) {
                Label(
                    model.focusCanvasPaneID == nil ? "Focus" : "Grid",
                    systemImage: model.focusCanvasPaneID == nil ? "rectangle.inset.filled" : "rectangle.grid.2x2"
                )
            }
            .disabled(model.activePane == nil)
            .accessibilityLabel(model.focusCanvasPaneID == nil ? "Enter Focus Canvas" : "Return to pane grid")
            .help(model.focusCanvasPaneID == nil ? "Enlarge the selected pane while keeping peers visible" : "Restore persisted pane proportions")
            Button(action: model.balance) { Image(systemName: "rectangle.grid.2x2") }
                .accessibilityLabel("Balance panes")
                .help("Balance panes")
                .accessibilityHint("Make panes in the active workspace equal size")
            Button {
                openWindow(id: "status-center")
            } label: {
                Label("Status", systemImage: "waveform.path.ecg")
            }
            .accessibilityLabel("Open Status Center")
            .help("Open Status Center")
            .accessibilityHint("Inspect collaboration state, returned results, agents, and activity")
            Button(action: model.toggleCollaborationDock) {
                Image(systemName: "sidebar.trailing")
            }
            .accessibilityLabel(model.collaborationDockVisible ? "Hide Collaboration Dock" : "Show Collaboration Dock")
            .help(model.collaborationDockVisible ? "Hide Collaboration Dock" : "Show Collaboration Dock")
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 7) {
            workspaceIdentity(maxWidth: 140)
            Divider().frame(height: 18)
            newPaneMenu
            askMenu
            compactActionsMenu
            Spacer(minLength: 6)
            Button(action: { model.toggleFocusCanvas() }) {
                Image(systemName: model.focusCanvasPaneID == nil ? "rectangle.inset.filled" : "rectangle.grid.2x2")
            }
            .disabled(model.activePane == nil)
            .accessibilityLabel(model.focusCanvasPaneID == nil ? "Enter Focus Canvas" : "Return to pane grid")
            Button {
                openWindow(id: "status-center")
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityLabel("Open Status Center")
            .help("Open Status Center")
            .accessibilityHint("Inspect collaboration state, returned results, agents, and activity")
            Button(action: model.toggleCollaborationDock) {
                Image(systemName: "sidebar.trailing")
            }
            .accessibilityLabel(model.collaborationDockVisible ? "Hide Collaboration Dock" : "Show Collaboration Dock")
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
            Label("Pane", systemImage: "plus")
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
            Section("Smart Orchestration") {
                if model.activeSupervisedWorkflow != nil {
                    Button("Open Active Orchestration…") { model.presentSupervisedWorkflow() }
                } else {
                    Button("New Plan → Review → Implement → Verify…") {
                        model.startSupervisedWorkflow()
                    }
                    .disabled(!model.canStartSupervisedWorkflow)
                }
                if !model.recentSupervisedWorkflows.isEmpty {
                    Menu("Recent Orchestration") {
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
        .accessibilityLabel("Recipes and smart orchestration")
        .accessibilityValue(model.workspaceLead.map { "Lead: \($0.displayName)" } ?? "No workspace lead")
        .help("Run a one-shot recipe or a bounded supervised or Auto cross-vendor sequence")
        .accessibilityHint("Choose a recipe or configure smart Plan, Review, Implement, Verify orchestration")
    }

    private var returnMenu: some View {
        Menu {
            ForEach(model.activePaneConsultations) { consultation in
                Button("Answer \(consultation.sourceName)") {
                    model.returnConsultation(consultation)
                }
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
            Button("Balance Panes", action: model.balance)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Pane actions")
        .accessibilityHint("Review, return, inspect waiting work, or balance panes")
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
    private func workspaceIdentity(maxWidth: CGFloat) -> some View {
        if let workspace = model.activeWorkspace {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(workspace.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let marker = model.runtime.visibleMarker {
                    Text(marker)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .help(workspaceTabHelp(workspace))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Workspace \(workspace.name)\(model.runtime.visibleMarker.map { ", \($0) runtime" } ?? "")")
        }
    }

    private var workbenchStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connectionStatusColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(WorkbenchChromeProjection.connectionLabel(model.connectionState))
                .foregroundStyle(connectionStatusColor)
            Text("Protocol \(AgentProtocol.version)")
            Text("\(model.visiblePanes.count) pane\(model.visiblePanes.count == 1 ? "" : "s")")
            if let pane = model.activePane {
                Rectangle()
                    .fill(paneFocusColor(pane.kind))
                    .frame(width: 3, height: 13)
                    .accessibilityHidden(true)
                Text(pane.displayName)
                    .foregroundStyle(.primary)
                if let role = pane.role {
                    Text("@\(role)")
                        .foregroundStyle(Color.accentColor)
                }
                Text("selected")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("⌘K Actions", action: model.showCommandPalette)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the Command Palette")
                .accessibilityLabel("Open Command Palette")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced).monospacedDigit())
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var connectionStatusColor: Color {
        switch model.connectionState {
        case .connected: .green
        case .coreDisconnected: .orange
        case .terminalDisconnected: .red
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
            Text("ORCHESTRATION")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(run.mode.label.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(run.mode == .automatic ? Color.accentColor : Color.secondary)
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

    private var focusCanvasStrip: some View {
        FocusCanvasStrip(model: model)
    }

    private var handoffComposer: some View {
        HandoffComposerView(model: model)
    }

    private var collaborationDock: some View {
        CollaborationDockView(model: model) {
            openWindow(id: "status-center")
        }
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
        .background(activityColor(handoff).opacity(0.065))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(activityColor(handoff))
                .frame(width: 3)
                .accessibilityHidden(true)
        }
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

    private func exitedTitle(pane: WorkbenchPane, status: Int?) -> String {
        guard let status else { return "\(pane.displayName) exited" }
        return "\(pane.displayName) exited with status \(status)"
    }

    private var paneFocusStrip: some View {
        HStack(spacing: 8) {
            Text("PANES")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.layoutOrderedVisiblePanes) { pane in
                        paneFocusButton(pane)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.secondary.opacity(0.035))
        .accessibilityElement(children: .contain)
    }

    private func paneFocusButton(_ pane: WorkbenchPane) -> some View {
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
        .accessibilityHint("Focus this pane in the native workspace layout")
    }

    private func paneFocusState(_ pane: WorkbenchPane) -> (label: String, color: Color)? {
        if let failure = model.latestFailure(for: pane.id) {
            return failure.attention == nil ? ("FAILED", .red) : ("ATTENTION", .orange)
        }
        let awaiting = model.awaitingAnswerCount(for: pane.id)
        if awaiting > 0 {
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

    private func paneFocusHelp(_ pane: WorkbenchPane) -> String {
        [
            "Focus in the native pane layout",
            pane.cwd,
            "Drag to select and release to copy; scroll normally inside the vendor terminal",
        ].joined(separator: "\n")
    }

    @ViewBuilder
    private var terminal: some View {
        if model.connectionState == .terminalDisconnected {
            ContentUnavailableView {
                Label("Terminal workbench unavailable", systemImage: "terminal.fill")
            } description: {
                Text(model.terminalError ?? "Parley cannot initialise its embedded Ghostty workbench.")
            } actions: {
                Button("Reconnect", action: model.retryConnections)
                    .disabled(!model.canRetryConnections)
            }
        } else if model.activePaneState == .empty {
            ContentUnavailableView {
                Label("No pane in this workspace", systemImage: "rectangle.split.2x1")
            } description: {
                Text("Create another workspace or restore a saved layout to continue.")
            } actions: {
                Button("New Workspace", action: model.createWorkspace)
            }
        } else if !model.nativePaneSurfaces.isEmpty {
            nativePaneSplit
        } else {
            ContentUnavailableView(
                "Native panes are unavailable",
                systemImage: "terminal",
                description: Text(model.startupError ?? "Parley could not construct this workspace's native layout.")
            )
        }
    }

    /// The sole workbench renderer: one native terminal per retained pane,
    /// arranged by the durable SwiftUI split tree.
    @ViewBuilder
    private var nativePaneSplit: some View {
        if let tree = model.nativeLayoutTree {
            NativeLayoutSplitView(
                node: tree,
                path: "root",
                focusPaneID: model.focusCanvasPaneID,
                fractionForPath: model.nativeSplitFraction,
                onFractionCommit: model.persistNativeSplitFraction
            ) { paneID in
                nativePaneLeaf(representativePaneID: paneID)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func nativePaneLeaf(representativePaneID: String) -> some View {
        if let paneSurface = model.nativePaneSurfaces.first(where: {
            $0.representativePaneID == representativePaneID
        }), let pane = model.visiblePanes.first(where: { $0.id == representativePaneID }) {
            VStack(spacing: 0) {
                paneChromeHeader(pane)
                nativeTerminalLeaf(paneSurface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: NSColor(white: 0.075, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        paneSurface.containsActivePane
                            ? Color.accentColor
                            : Color(nsColor: .separatorColor).opacity(0.9),
                        lineWidth: paneSurface.containsActivePane ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: paneSurface.containsActivePane ? Color.accentColor.opacity(0.22) : Color.clear,
                radius: 4
            )
            .padding(4)
        }
    }

    private func paneChromeHeader(_ pane: WorkbenchPane) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(paneFocusColor(pane.kind))
                .frame(width: 3, height: 15)
                .accessibilityHidden(true)
            Text(pane.displayName)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            if let role = pane.role {
                Text("@\(role)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            ViewThatFits(in: .horizontal) {
                Text(WorkspaceFolderIdentity.displayName(for: pane.cwd))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                EmptyView()
            }
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(WorkbenchChromeProjection.processLabel(pane))
                        .foregroundStyle(paneProcessColor(pane))
                    if let selection = WorkbenchChromeProjection.selectionLabel(pane) {
                        Text(selection)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if let selection = WorkbenchChromeProjection.selectionLabel(pane) {
                    Text(selection)
                        .foregroundStyle(Color.accentColor)
                }
                Text(WorkbenchChromeProjection.processLabel(pane))
                    .foregroundStyle(paneProcessColor(pane))
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .lineLimit(1)
            Menu {
                Button(model.focusCanvasPaneID == pane.id ? "Return to Grid" : "Focus Canvas") {
                    model.toggleFocusCanvas(paneID: pane.id)
                }
                Divider()
                paneContextMenu(pane)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Pane actions for \(pane.displayName)")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .background(pane.isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .onTapGesture(count: 2) {
            model.toggleFocusCanvas(paneID: pane.id)
        }
        .onTapGesture {
            model.select(pane)
        }
        .focusable()
        .accessibilityLabel("Focus \(pane.displayName), \(pane.kind.label) pane")
        .accessibilityValue(paneAccessibilityValue(pane))
        .accessibilityHint("Select this terminal; double-click to toggle Focus Canvas")
        .help("\(pane.displayName) · \(pane.cwd)\nClick to select; double-click to toggle Focus Canvas")
    }

    private func paneProcessColor(_ pane: WorkbenchPane) -> Color {
        switch WorkbenchStateProjection.pane(pane) {
        case .empty, .running: .secondary
        case .stopped: .secondary
        case .exited: .red
        case .protocolStale, .relayUnavailable: .orange
        }
    }

    @ViewBuilder
    private func nativeTerminalLeaf(_ paneSurface: AppModel.NativePaneSurface) -> some View {
        NativeTerminalHost(
            paneID: paneSurface.representativePaneID,
            model: model,
            focusOnAttach: paneSurface.containsActivePane
        )
        .id(
            "native-terminal-\(paneSurface.representativePaneID)-\(model.panes.first(where: { $0.id == paneSurface.representativePaneID })?.launchGeneration ?? 0)"
        )
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
    private func reviewTargetItems(action: @escaping (WorkbenchPane) -> Void) -> some View {
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

/// Renders a native layout tree: horizontal splits sit side by side,
/// vertical splits stack, and dividers stay AppKit-draggable.
private struct NativeLayoutSplitView<Leaf: View>: View {
    let node: NativeLayoutNode
    let path: String
    let focusPaneID: String?
    let fractionForPath: (String) -> Double?
    let onFractionCommit: (Double, String) -> Void
    let leaf: (String) -> Leaf

    @State private var dragStartFraction: Double?
    @State private var draggedFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            splitContent(size: geometry.size)
        }
    }

    @ViewBuilder
    private func splitContent(size: CGSize) -> some View {
        switch node {
        case let .leaf(paneID):
            leaf(paneID)
        case let .split(direction, first, second):
            let dividerLength: CGFloat = 7
            let availableLength = max(
                (direction == .horizontal ? size.width : size.height) - dividerLength,
                1
            )
            let minimumLeafLength: CGFloat = direction == .horizontal ? 180 : 120
            let stored = draggedFraction
                ?? fractionForPath(path)
                ?? NativeSplitGeometry.proportionalFraction(
                    firstLeafCount: first.leaves.count,
                    secondLeafCount: second.leaves.count
                )
            let focused = focusAdjustedFraction(
                stored,
                first: first,
                second: second
            )
            let fraction = NativeSplitGeometry.clampedFraction(
                focused,
                availableLength: availableLength,
                minimumLeafLength: minimumLeafLength
            )
            let firstLength = availableLength * fraction
            let secondLength = availableLength - firstLength
            if direction == .horizontal {
                HStack(spacing: 0) {
                    child(first, path: "\(path).first")
                        .frame(width: firstLength)
                    divider(
                        direction: direction,
                        availableLength: availableLength,
                        fraction: fraction
                    )
                    child(second, path: "\(path).second")
                        .frame(width: secondLength)
                }
            } else {
                VStack(spacing: 0) {
                    child(first, path: "\(path).first")
                        .frame(height: firstLength)
                    divider(
                        direction: direction,
                        availableLength: availableLength,
                        fraction: fraction
                    )
                    child(second, path: "\(path).second")
                        .frame(height: secondLength)
                }
            }
        }
    }

    private func child(_ childNode: NativeLayoutNode, path childPath: String) -> some View {
        NativeLayoutSplitView(
            node: childNode,
            path: childPath,
            focusPaneID: focusPaneID,
            fractionForPath: fractionForPath,
            onFractionCommit: onFractionCommit,
            leaf: leaf
        )
    }

    private func focusAdjustedFraction(
        _ stored: Double,
        first: NativeLayoutNode,
        second: NativeLayoutNode
    ) -> Double {
        guard let focusPaneID else { return stored }
        if first.leaves.contains(focusPaneID), !second.leaves.contains(focusPaneID) { return 0.78 }
        if second.leaves.contains(focusPaneID), !first.leaves.contains(focusPaneID) { return 0.22 }
        return stored
    }

    private func divider(
        direction: SplitDirection,
        availableLength: CGFloat,
        fraction: Double
    ) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.72))
            .frame(
                width: direction == .horizontal ? 7 : nil,
                height: direction == .vertical ? 7 : nil
            )
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.34))
                    .frame(
                        width: direction == .horizontal ? 1 : 28,
                        height: direction == .vertical ? 1 : 28
                    )
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                guard focusPaneID == nil else { return }
                if hovering {
                    (direction == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard focusPaneID == nil else { return }
                        if dragStartFraction == nil { dragStartFraction = fraction }
                        let translation = direction == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let candidate = (dragStartFraction ?? fraction) + Double(translation / availableLength)
                        draggedFraction = NativeSplitGeometry.clampedFraction(
                            candidate,
                            availableLength: availableLength,
                            minimumLeafLength: direction == .horizontal ? 180 : 120
                        )
                    }
                    .onEnded { _ in
                        guard focusPaneID == nil else { return }
                        let committed = draggedFraction ?? fraction
                        onFractionCommit(committed, path)
                        dragStartFraction = nil
                        draggedFraction = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize terminal panes")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            .accessibilityAdjustableAction { directionAction in
                guard focusPaneID == nil else { return }
                let delta = directionAction == .increment ? 0.05 : -0.05
                let adjusted = NativeSplitGeometry.clampedFraction(
                    fraction + delta,
                    availableLength: availableLength,
                    minimumLeafLength: direction == .horizontal ? 180 : 120
                )
                onFractionCommit(adjusted, path)
            }
    }
}

private struct PaneRow: View {
    let pane: WorkbenchPane
    let projectContext: GitProjectContext?
    let awaitingAnswerCount: Int
    let unreadResultCount: Int
    let latestFailure: RelayHandoff?
    let permissionProfileName: String?

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(kindColor)
                .frame(width: 3, height: 30)
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
                Text(monogram)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(pane.displayName)
                        .font(.system(size: 11, weight: pane.isActive ? .semibold : .medium))
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
                    if awaitingAnswerCount > 0 {
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
                    if pane.kind.isAgent, let rootCount = pane.permissionSelection?.approvedRoots.count,
                       rootCount > 1 {
                        Text("·")
                        Text("\(rootCount) folders")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("·")
                    Text(processLabel)
                }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(processColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .help(paneHelp)
    }

    private var monogram: String {
        switch pane.kind {
        case .claude: "CL"
        case .codex: "CX"
        case .agy: "AG"
        case .copilot: "CP"
        case .shell: "SH"
        }
    }

    private var processColor: Color {
        switch WorkbenchStateProjection.pane(pane) {
        case .running: .green
        case .empty, .stopped: .secondary
        case .exited: .red
        case .protocolStale, .relayUnavailable: .orange
        }
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
        let folderAccess = pane.permissionSelection.map { selection in
            "Folder access (\(selection.approvedRoots.count)): \(selection.approvedRoots.joined(separator: ", "))"
        }
        let role = pane.role.map { "Routing role: \($0)" }
        guard let projectContext else {
            return [pane.cwd, role, permission, folderAccess].compactMap { $0 }.joined(separator: "\n")
        }
        let state = projectContext.isDirty ? "dirty" : "clean"
        return [
            pane.cwd,
            "Git: \(projectContext.branch) · \(state)",
            role,
            permission,
            folderAccess,
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
