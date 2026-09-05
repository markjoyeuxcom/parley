import AppKit
import ParleyCore
import ParleyUI
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
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
                CommandRunNotice(model: model)
                Divider()
                if let top = noticeLane.first {
                    noticeLaneView(top: top, lane: noticeLane)
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
                    .sheet(item: paneChoiceRequest) { request in
                        PaneChoiceSheet(model: model, request: request)
                    }
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
        .sheet(isPresented: Binding(
            get: { model.commandRunsPresented },
            set: { if !$0 { model.dismissCommandRunReview() } }
        )) { CommandRunsView(model: model) }
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
        .onChange(of: model.settingsOpenRequestID) { _, requestID in
            guard requestID != nil else { return }
            openSettings()
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
                                        facts: model.sidebarFacts(for: pane),
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
                            .font(.system(size: 9, weight: .semibold))
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
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(displayPath)
                    .font(.system(size: 9))
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
        Divider()
        if pane.kind.isAgent {
            if !pane.isStarted {
                Button("Start Fresh Session") { model.start(pane) }
            }
            if let plan = VendorResumeAdapter.plan(for: pane.kind) {
                Button(plan.menuLabel) { model.resume(pane) }
            }
            if pane.isStarted {
                if pane.kind == .copilot && !pane.isDead {
                    Button("Confirm Copilot Folder Trust…") { model.confirmCopilotFolderTrust(pane) }
                }
                Button("Restart Fresh Session…") { model.restart(pane) }
            }
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
        Button("Terminal Appearance…") { model.showTerminalFontSettings() }
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
        let facts = model.sidebarFacts(for: pane)
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
        let attention = model.paneAttention(for: pane.id)
            .map { ", \($0.accessibilityDescription())" } ?? ""
        let git = facts.gitContext.map {
            ", Git branch \($0.branch), \($0.isDirty ? "dirty" : "clean")"
        } ?? ""
        let listeners = facts.listeningPorts.isEmpty
            ? ""
            : ", listening on TCP ports \(facts.listeningPorts.map(String.init).joined(separator: ", "))"
        return "\(state)\(lead)\(role)\(attention)\(git)\(listeners), working folder \(facts.workingDirectory)"
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

            WindowDragArea()
                .frame(minWidth: 6, maxWidth: .infinity)
                .frame(height: 42)
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
            WindowDragArea()
                .frame(minWidth: 6, maxWidth: .infinity)
                .frame(height: 42)
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
        PaneCreationMenu(
            offersActivePaneFolder: model.activePane.map {
                !WorkspaceFolderIdentity.matches($0.cwd, model.defaultFolder)
            } ?? false
        ) { kind, direction, folder in
            switch folder {
            case .newPane: model.create(kind, direction: direction)
            case .activePane: model.createInActivePaneFolder(kind, direction: direction)
            case .chosen: model.createInChosenFolder(kind, direction: direction)
            }
        }
        .accessibilityLabel("New pane")
        .help("Open a new agent or shell pane")
        .accessibilityHint("Choose an agent or shell and where to split the active workspace")
    }

    private var askMenu: ToolbarActionMenu {
        var items: [ToolbarMenuItem] = []
        if let target = model.quickRelayTarget {
            items += [
                .heading("Last Explicit Target"),
                .action(
                    "Ask \(target.displayName) · \(target.kind.label) with Selection…",
                    isEnabled: model.canQuickRelaySelection, help: "Command-Shift-A"
                ) {
                    guard model.quickRelayTarget?.id == target.id else { return }
                    model.quickRelaySelection()
                },
                .separator
            ]
        }
        if model.askTargets.isEmpty {
            items.append(.message("Focus an agent pane with another vendor open"))
        } else {
            if !model.localAskTargets.isEmpty {
                items.append(.heading("This Workspace"))
                items += model.localAskTargets.map { target in
                    .action("Ask \(target.displayName)") { model.ask(target) }
                }
            }
            items += model.otherWorkspaceAskGroups.map { group in
                .submenu(group.workspace.name, items: group.panes.map { target in
                    .action("Ask \(target.displayName)") { model.ask(target) }
                })
            }
        }
        if model.askManyComparisonRun != nil || model.canCompareAskMany {
            items.append(.separator)
            if let comparison = model.askManyComparisonRun {
                items.append(.action(comparison.isRunning ? "Open Active Comparison" : "Open Last Comparison") {
                    model.presentAskManyComparison()
                })
            }
            items.append(.action("Compare Independently…", isEnabled: model.canCompareAskMany) {
                model.compareAskMany()
            })
        }
        return ToolbarActionMenu(
            title: "Ask", systemImage: "arrow.turn.up.right",
            isEnabled: !model.askTargets.isEmpty || model.askManyComparisonRun != nil,
            accessibilityLabel: "Ask another vendor",
            accessibilityValue: "\(model.askTargets.count) available target\(model.askTargets.count == 1 ? "" : "s")",
            accessibilityHint: "Choose another agent pane for a correlated question",
            items: items
        )
    }

    private var reviewMenu: ToolbarActionMenu {
        ToolbarActionMenu(
            title: "Review", systemImage: "doc.text.magnifyingglass",
            isEnabled: !model.askTargets.isEmpty,
            accessibilityLabel: "Review with another vendor",
            help: "Preview repository changes or a selected file, then ask another vendor to review it",
            accessibilityHint: "Preview current changes, a plan, or a file before asking another vendor",
            items: [
                .submenu("Current Changes", items: reviewTargetItems { model.reviewChanges(with: $0) }),
                .submenu("Plan or File…", items: reviewTargetItems { model.reviewFile(with: $0) })
            ]
        )
    }

    private var contextPackMenu: ToolbarActionMenu {
        var items: [ToolbarMenuItem] = []
        if !model.pendingContextReviews.isEmpty {
            items.append(.heading("Agent Drafts Awaiting Review"))
            items += model.pendingContextReviews.map { review in
                let target = review.requestedTargetName.map { " → \($0)" } ?? ""
                return .action(
                    "\(review.sourcePaneName)\(target) · \(review.state == .awaitingReview ? "awaiting review" : "draft")",
                    systemImage: review.state == .awaitingReview ? "person.crop.circle.badge.clock" : "doc.badge.ellipsis"
                ) { model.presentContextReview(review) }
            }
            items.append(.separator)
        }
        if let draft = model.contextPackDraft {
            items += [
                .action("Open Context Pack “\(draft.pack.name)”") { model.presentContextPack() },
                .separator
            ]
        }
        items.append(.action("New Context Pack…", isEnabled: model.canCreateContextPack) { model.newContextPack() })
        if model.activeWorkspace != nil {
            items += [
                .separator,
                .heading("Workspace Brief"),
                .action(model.activeWorkspaceBrief == nil ? "Create Workspace Brief…" : "Edit Workspace Brief…") {
                    model.editWorkspaceBrief()
                }
            ]
            if model.activeWorkspaceBrief != nil {
                items.append(.action("New Context Pack with Workspace Brief…", isEnabled: model.canCreateContextPack) {
                    model.newContextPackWithWorkspaceBrief()
                })
            }
        }
        items += [
            .separator,
            .heading("Reusable Context"),
            .action("Manage Pinned Snippets…") { model.presentPinnedContextSnippets() },
            .separator,
            .action("How Context Works", systemImage: "questionmark.circle") {
                model.requestHelp(topicID: "context-model")
                openWindow(id: "help")
            }
        ]
        return ToolbarActionMenu(
            title: model.pendingContextReviews.isEmpty ? "Context" : "Context \(model.pendingContextReviews.count)",
            systemImage: model.pendingContextReviews.isEmpty ? "shippingbox" : "shippingbox.fill",
            accessibilityLabel: "Context packs and references",
            accessibilityValue: model.pendingContextReviews.isEmpty
                ? (model.contextPackDraft.map { "\($0.pack.parts.count) sources" } ?? "No draft")
                : "\(model.pendingContextReviews.count) agent draft\(model.pendingContextReviews.count == 1 ? "" : "s") awaiting review",
            help: "Manage reusable context, edit the workspace brief or assemble explicit attributed sources before a cross-vendor handoff",
            accessibilityHint: "Manage pinned context and the workspace brief, or open an editable attributed context pack",
            items: items
        )
    }

    private var recipeMenu: ToolbarActionMenu {
        var items: [ToolbarMenuItem] = []
        if model.workspaceLead == nil {
            items.append(.message("Mark an agent pane as workspace lead"))
        }
        items.append(.heading("Run with Workspace Lead"))
        items += model.recipes.map { recipe in
            .action(recipe.name, isEnabled: model.canRun(recipe)) { model.run(recipe) }
        }
        items += [.separator, .heading("Smart Orchestration")]
        if model.activeSupervisedWorkflow != nil {
            items.append(.action("Open Active Orchestration…") { model.presentSupervisedWorkflow() })
        } else {
            items.append(.action("New Plan → Review → Implement → Verify…", isEnabled: model.canStartSupervisedWorkflow) {
                model.startSupervisedWorkflow()
            })
        }
        if !model.recentSupervisedWorkflows.isEmpty {
            items.append(.submenu("Recent Orchestration", items: model.recentSupervisedWorkflows.prefix(8).map { run in
                .action("\(run.phase.label) · \(run.updatedAt.formatted(date: .abbreviated, time: .shortened))") {
                    model.presentSupervisedWorkflow(run)
                }
            }))
        }
        var editItems: [ToolbarMenuItem] = model.recipes.map { recipe in
            .action(recipe.name) { model.edit(recipe) }
        }
        editItems += [.separator, .action("Restore Defaults…") { model.restoreDefaultRecipes() }]
        items += [.separator, .submenu("Edit Recipes", items: editItems)]
        return ToolbarActionMenu(
            title: "Recipes", systemImage: "list.bullet.rectangle",
            accessibilityLabel: "Recipes and smart orchestration",
            accessibilityValue: model.workspaceLead.map { "Lead: \($0.displayName)" } ?? "No workspace lead",
            help: "Run a one-shot recipe or a bounded supervised or Auto cross-vendor sequence",
            accessibilityHint: "Choose a recipe or configure smart Plan, Review, Implement, Verify orchestration",
            items: items
        )
    }

    private var returnMenu: ToolbarActionMenu {
        ToolbarActionMenu(
            title: "Return", systemImage: "arrow.turn.down.left",
            isEnabled: model.canReturn,
            accessibilityLabel: "Return answer",
            accessibilityValue: model.canReturn ? "Answer destination available" : "No answer destination",
            accessibilityHint: "Return the active pane's answer to its waiting requester",
            items: model.activePaneConsultations.map { consultation in
                .action("Answer \(consultation.sourceName)") { model.returnConsultation(consultation) }
            }
        )
    }

    private var compactActionsMenu: ToolbarActionMenu {
        var items = [reviewMenu.asSubmenu, contextPackMenu.asSubmenu, recipeMenu.asSubmenu, returnMenu.asSubmenu]
        if hasWaitingWork { items.append(waitingMenu.asSubmenu) }
        items += [.separator, .action("Balance Panes", perform: model.balance)]
        return ToolbarActionMenu(
            title: "Actions", systemImage: "ellipsis.circle",
            accessibilityLabel: "Pane actions",
            accessibilityHint: "Review, return, inspect waiting work, or balance panes",
            items: items
        )
    }

    private var hasWaitingWork: Bool {
        !model.consultations.isEmpty || !model.activeDelegations.isEmpty
    }

    private var waitingMenu: ToolbarActionMenu {
        var items: [ToolbarMenuItem] = []
        if !model.consultations.isEmpty {
            items.append(.heading("Questions"))
            items += model.consultations.map { consultation in
                .action("Cancel \(consultation.sourceName) → \(consultation.targetName)…", isDestructive: true) {
                    model.cancel(consultation)
                }
            }
        }
        if !model.activeDelegations.isEmpty {
            if !items.isEmpty { items.append(.separator) }
            items.append(.heading("Delegated Work"))
            items += model.activeDelegations.map { handoff in
                .submenu("\(handoff.sourceName) → \(handoff.targetName)", items: [
                    .message(activitySubject(handoff.text)),
                    .separator,
                    .action("Focus \(handoff.sourceName)", isEnabled: model.canFocus(handoff.sourcePaneID)) {
                        model.focus(handoff, target: false)
                    },
                    .action("Focus \(handoff.targetName)", isEnabled: model.canFocus(handoff.targetPaneID)) {
                        model.focus(handoff, target: true)
                    },
                    .separator,
                    .action("Cancel Tracking…", isDestructive: true) { model.cancel(handoff) }
                ])
            }
        }
        return ToolbarActionMenu(
            title: "Waiting \(model.consultations.count + model.activeDelegations.count)", systemImage: "clock",
            accessibilityLabel: "Waiting collaboration",
            accessibilityValue: "\(model.consultations.count) questions, \(model.activeDelegations.count) delegations",
            help: "Inspect questions and delegated work awaiting a result",
            accessibilityHint: "Inspect work awaiting an answer or completion",
            items: items
        )
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
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                .fill(ChromeColor.connection(model.connectionState))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(WorkbenchChromeProjection.connectionLabel(model.connectionState))
                .foregroundStyle(model.connectionState == .connected ? Color.secondary : ChromeColor.connection(model.connectionState))
            Text("Protocol \(AgentProtocol.version)")
            Text("\(model.visiblePanes.count) pane\(model.visiblePanes.count == 1 ? "" : "s")")
            if let pane = model.activePane {
                Text(ChromeIdentity.monogram(pane.kind))
                    .font(ChromeFont.chip)
                    .accessibilityHidden(true)
                Text(pane.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let role = pane.role {
                    Text("@\(role)")
                        .foregroundStyle(Color.accentColor)
                }
                Text("selected")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if !model.workspaceHandoffs.isEmpty {
                activityHistoryMenu
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            Button("⌘K Actions", action: model.showCommandPalette)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the Command Palette")
                .accessibilityLabel("Open Command Palette")
        }
        .font(ChromeFont.secondary.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var handoffComposer: some View {
        HandoffComposerView(model: model)
    }

    private var collaborationDock: some View {
        CollaborationDockView(model: model) {
            openWindow(id: "status-center")
        }
    }

    // MARK: Notice lane

    /// The pane choice sheet belongs to the Context Pack window while that
    /// window is presented, so the main window only presents it otherwise.
    private var paneChoiceRequest: Binding<PaneChoiceRequest?> {
        Binding(
            get: { model.contextPackPresented ? nil : model.paneChoiceRequest },
            set: { if $0 == nil { model.cancelPaneChoice() } }
        )
    }

    private var noticeLane: [WorkbenchNotice] {
        WorkbenchNoticeProjection.lane(noticeInputs)
    }

    private var noticeInputs: WorkbenchNoticeInputs {
        let settled: Set<RelayHandoffState> = [.completed, .cancelled]
        let attention = model.workspaceHandoffs.filter { $0.attention != nil && !settled.contains($0.state) }
        return WorkbenchNoticeInputs(
            activePane: model.activePane.map {
                WorkbenchNoticePane(id: $0.id, name: $0.displayName, kindLabel: $0.kind.label)
            },
            activePaneState: model.terminalAvailable ? model.activePaneState : .empty,
            connectionState: model.connectionState,
            worktreeCollisions: model.activeWorktreeWriterCollisions.map { collision in
                WorkbenchWorktreeNotice(
                    path: collision.worktree.path,
                    writerNames: collision.writers.map {
                        "\($0.paneName) (\($0.permissionProfileName), \($0.enforcement?.label ?? "enforcement unknown"))"
                    }
                )
            },
            primaryActivity: model.primaryActivity.map(WorkbenchNoticeActivity.init(handoff:)),
            attentionActivities: attention.map(WorkbenchNoticeActivity.init(handoff:)),
            recipe: model.activeRecipeRun.map { WorkbenchRecipeNotice(name: $0.recipeName, leadName: $0.leadName) },
            workflow: model.activeSupervisedWorkflow.map(WorkbenchWorkflowNotice.init(run:)),
            focusCanvasActive: model.focusCanvasPaneID != nil,
            dockVisible: model.collaborationDockVisible,
            protocolVersion: AgentProtocol.version
        )
    }

    private func noticeLaneView(top: WorkbenchNotice, lane: [WorkbenchNotice]) -> some View {
        let tone = ChromeColor.tone(top.tone)
        let rest = Array(lane.dropFirst())
        return HStack(spacing: 10) {
            Image(systemName: noticeSymbol(top.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(top.title)
                    .font(ChromeFont.bodySemibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(top.detail)
                    .font(ChromeFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(top.kind == .activity ? 1 : 2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(top.title). \(top.detail)")
            Spacer(minLength: 8)
            if let label = top.actionLabel, let action = top.action {
                Button(label) { perform(action) }
                    .accessibilityHint(noticeActionHint(action))
            }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest) { notice in
                        Section {
                            Text(notice.detail)
                            if let label = notice.actionLabel, let action = notice.action {
                                Button(label) { perform(action) }
                            }
                        } header: {
                            Text(notice.title)
                        }
                    }
                } label: {
                    Text("+\(rest.count)")
                        .font(ChromeFont.secondaryMedium.monospacedDigit())
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(rest.map(\.title).joined(separator: "\n"))
                .accessibilityLabel("\(rest.count) more notice\(rest.count == 1 ? "" : "s")")
                .accessibilityHint("Open the remaining notices in priority order")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .background(tone.opacity(0.07))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tone)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .help(top.detail)
        .accessibilityElement(children: .contain)
    }

    private func noticeSymbol(_ kind: WorkbenchNoticeKind) -> String {
        switch kind {
        case .permission: "hand.raised"
        case .humanCheckpoint: "person.crop.circle.badge.questionmark"
        case .failure: "xmark.circle"
        case .protocolStale: "arrow.triangle.2.circlepath.circle"
        case .relayUnavailable: "link.badge.plus"
        case .worktreeCollision: "exclamationmark.triangle"
        case .connection: "bolt.horizontal.circle"
        case .targetAttention: "exclamationmark.bubble"
        case .paneStopped: "pause.circle"
        case .activity: "arrow.triangle.branch"
        case .workflow: "list.bullet.rectangle"
        case .recipe: "text.badge.checkmark"
        case .focusCanvas: "rectangle.inset.filled"
        }
    }

    private func noticeActionHint(_ action: WorkbenchNoticeAction) -> String {
        switch action {
        case .focusPane: "Focus this pane"
        case .focusHandoffTarget: "Move to the pane receiving this handoff"
        case .focusHandoffSource: "Move to the pane that initiated this handoff"
        case .restartPane: "Begin a new CLI process in the same pane and folder after confirmation"
        case .startPane: "Start the subscription CLI in this pane"
        case .retryDelivery: "Retry the original delivery after confirmation"
        case .reconnect: "Reconnect to the local coordination core"
        case .openWorktrees: "Open the worktree browser for this folder"
        case .openWorkflow: "Open the supervised workflow window"
        case .stopRecipe: "Send Control-C to the lead pane after confirmation"
        case .exitFocusCanvas: "Return every visible pane to the grid"
        }
    }

    private func perform(_ action: WorkbenchNoticeAction) {
        switch action {
        case let .focusPane(paneID):
            if let pane = model.panes.first(where: { $0.id == paneID }) { model.select(pane) }
        case let .focusHandoffTarget(handoffID):
            if let handoff = noticeHandoff(handoffID) { model.focus(handoff, target: true) }
        case let .focusHandoffSource(handoffID):
            if let handoff = noticeHandoff(handoffID) { model.focus(handoff, target: false) }
        case let .restartPane(paneID):
            if let pane = model.panes.first(where: { $0.id == paneID }) { model.restart(pane) }
        case let .startPane(paneID):
            if let pane = model.panes.first(where: { $0.id == paneID }) { model.start(pane) }
        case let .retryDelivery(handoffID):
            if let handoff = noticeHandoff(handoffID) { model.retry(handoff) }
        case .reconnect:
            model.retryConnections()
        case let .openWorktrees(path):
            model.showWorktreeBrowser(sourceFolder: path)
        case .openWorkflow:
            model.presentSupervisedWorkflow()
        case .stopRecipe:
            model.interruptActiveRecipeRun()
        case .exitFocusCanvas:
            model.exitFocusCanvas()
        }
    }

    private func noticeHandoff(_ id: String) -> RelayHandoff? {
        model.workspaceHandoffs.first(where: { $0.id == id })
            ?? (model.primaryActivity?.id == id ? model.primaryActivity : nil)
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

    private func attentionActionLabel(_ handoff: RelayHandoff) -> String {
        switch handoff.attention {
        case .permissionRequired: "Resolve Permission in \(handoff.targetName)"
        case .targetNotReady: "Make \(handoff.targetName) Ready"
        case .targetUnavailable: "Inspect Missing Target"
        case nil: "Focus \(handoff.targetName)"
        }
    }

    private var paneFocusStrip: some View {
        HStack(spacing: 8) {
            ChromeHeading("Panes")

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
                Text(ChromeIdentity.monogram(pane.kind))
                    .font(ChromeFont.chip)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(pane.displayName)
                    .font(.system(size: 10, weight: pane.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let role = pane.role {
                    Text("@\(role)")
                        .font(ChromeFont.meta)
                        .foregroundStyle(Color.accentColor)
                }
                if let state = paneFocusState(pane) {
                    ChromeChip(state.label, color: state.color)
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
            return failure.attention == nil ? ("Failed", .red) : ("Attention", .orange)
        }
        let awaiting = model.awaitingAnswerCount(for: pane.id)
        if awaiting > 0 {
            return (awaiting > 1 ? "Return \(awaiting)" : "Return", .accentColor)
        }
        let unread = model.unreadResultCount(forPane: pane.id)
        if unread > 0 { return (unread > 1 ? "Result \(unread)" : "Result", .accentColor) }
        return switch WorkbenchStateProjection.pane(pane) {
        case .empty, .running: nil
        case .stopped: ("Stopped", .secondary)
        case let .exited(status): (status.map { "Exited \($0)" } ?? "Exited", .red)
        case .protocolStale: ("Protocol stale", .orange)
        case .relayUnavailable: ("Relay off", .orange)
        }
    }

    private func paneFocusHelp(_ pane: WorkbenchPane) -> String {
        var details = [
            "Focus in the native pane layout",
            pane.cwd,
            "Drag to select and release to copy; scroll normally inside the vendor terminal",
        ]
        if let attention = model.paneAttention(for: pane.id) {
            details.insert(attention.accessibilityDescription(), at: 1)
        }
        return details.joined(separator: "\n")
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
            let attention = model.paneAttention(for: pane.id)
            VStack(spacing: 0) {
                paneChromeHeader(pane)
                nativeTerminalLeaf(paneSurface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: NSColor(white: 0.075, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                if let attention {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(ChromeColor.attention(attention.reason), lineWidth: 2)
                        if paneSurface.containsActivePane {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                                .padding(3)
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            paneSurface.containsActivePane
                                ? Color.accentColor
                                : Color(nsColor: .separatorColor).opacity(0.9),
                            lineWidth: paneSurface.containsActivePane ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: attention.map { ChromeColor.attention($0.reason).opacity(0.28) }
                    ?? (paneSurface.containsActivePane ? Color.accentColor.opacity(0.22) : Color.clear),
                radius: 4
            )
            .padding(4)
        }
    }

    private func paneChromeHeader(_ pane: WorkbenchPane) -> some View {
        HStack(spacing: 7) {
            ChromeMonogram(kind: pane.kind, size: 17)
            Text(pane.displayName)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            if let role = pane.role {
                Text("@\(role)")
                    .font(ChromeFont.meta)
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
            if let attention = model.paneAttention(for: pane.id) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ChromeChip(attention.label(at: context.date), color: ChromeColor.attention(attention.reason))
                }
                .help(attention.accessibilityDescription())
                .accessibilityLabel(attention.accessibilityDescription())
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ChromeChip(WorkbenchChromeProjection.processLabel(pane), color: ChromeColor.paneProcess(pane))
                    if let selection = WorkbenchChromeProjection.selectionLabel(pane) {
                        ChromeChip(selection, color: .accentColor)
                    }
                }
                if let selection = WorkbenchChromeProjection.selectionLabel(pane) {
                    ChromeChip(selection, color: .accentColor)
                }
                ChromeChip(WorkbenchChromeProjection.processLabel(pane), color: ChromeColor.paneProcess(pane))
            }
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
        .background(pane.isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .background(Color(nsColor: .controlBackgroundColor))
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
        .help(paneFocusHelp(pane))
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

    private func reviewTargetItems(action: @escaping (WorkbenchPane) -> Void) -> [ToolbarMenuItem] {
        var items: [ToolbarMenuItem] = []
        if !model.localAskTargets.isEmpty {
            items.append(.heading("This Workspace"))
            items += model.localAskTargets.map { target in
                .action(target.displayName) { action(target) }
            }
        }
        items += model.otherWorkspaceAskGroups.map { group in
            .submenu(group.workspace.name, items: group.panes.map { target in
                .action(target.displayName) { action(target) }
            })
        }
        return items
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
    let facts: PaneSidebarFacts
    let awaitingAnswerCount: Int
    let unreadResultCount: Int
    let latestFailure: RelayHandoff?
    let permissionProfileName: String?

    var body: some View {
        HStack(spacing: 8) {
            ChromeMonogram(kind: pane.kind, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(pane.displayName)
                        .font(.system(size: 11, weight: pane.isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if pane.isWorkspaceLead {
                        Text("Lead")
                            .font(ChromeFont.meta)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let role = pane.role {
                        Text("@\(role)")
                            .font(ChromeFont.meta)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if awaitingAnswerCount > 0 {
                        countBadge(awaitingAnswerCount, symbol: "arrow.uturn.left")
                    }
                    if unreadResultCount > 0 {
                        countBadge(unreadResultCount, symbol: "envelope")
                    }
                    if let state = primaryState {
                        ChromeChip(state.label, color: state.color)
                    }
                }
                HStack(spacing: 4) {
                    Text(workingDirectoryLabel)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let projectContext = facts.gitContext {
                        Text("·")
                        Text(projectContext.branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if projectContext.isDirty {
                            Text("dirty")
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                    }
                    if pane.kind.isAgent, let rootCount = pane.permissionSelection?.approvedRoots.count,
                       rootCount > 1 {
                        Text("·")
                        Text("\(rootCount) folders")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let permissionProfileName {
                        Text("·")
                        Text(permissionProfileName)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if !facts.listeningPorts.isEmpty {
                        Label(facts.listeningPorts.count.formatted(), systemImage: "antenna.radiowaves.left.and.right")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.accentColor)
                            .help(listeningPortHelp)
                            .accessibilityLabel(listeningPortHelp)
                    }
                    if let attention = facts.latestAttention, primaryState?.source != .attention {
                        Image(systemName: attentionSymbol(attention))
                            .foregroundStyle(ChromeColor.attention(attention.reason))
                            .help(attention.accessibilityDescription())
                            .accessibilityLabel(attention.accessibilityDescription())
                    }
                }
                .font(ChromeFont.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .help(paneHelp)
    }

    private enum StateSource { case failure, process, attention }

    /// The single state that earns the row's chip, in the order a person
    /// would want to know it: a failed or blocked handoff, then the process,
    /// then the latest authoritative attention.
    private var primaryState: (label: String, color: Color, source: StateSource)? {
        if let latestFailure {
            return (failureLabel(latestFailure), latestFailure.attention != nil ? .orange : .red, .failure)
        }
        switch WorkbenchStateProjection.pane(pane) {
        case .stopped: return ("Stopped", .secondary, .process)
        case let .exited(status): return (status.map { "Exited \($0)" } ?? "Exited", .red, .process)
        case .protocolStale: return ("Protocol stale", .orange, .process)
        case .relayUnavailable: return ("Relay off", .orange, .process)
        case .empty, .running: break
        }
        if let attention = facts.latestAttention {
            return (attentionReasonLabel(attention), ChromeColor.attention(attention.reason), .attention)
        }
        return nil
    }

    private func countBadge(_ count: Int, symbol: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(count.formatted())
                .font(ChromeFont.meta)
        }
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
    }

    private var workingDirectoryLabel: String {
        (facts.workingDirectory as NSString).abbreviatingWithTildeInPath
    }

    private var listeningPortHelp: String {
        "Listening TCP ports attributed to this pane's process tree: "
            + facts.listeningPorts.map(String.init).joined(separator: ", ")
    }

    private var processLabel: String {
        switch WorkbenchStateProjection.pane(pane) {
        case .stopped: "not started"
        case let .exited(status): status.map { "exited \($0)" } ?? "exited"
        case .empty, .running, .protocolStale, .relayUnavailable: pane.currentCommand
        }
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
        let process = processLabel.isEmpty ? nil : "Process: \(processLabel)"
        let listeners = facts.listeningPorts.isEmpty ? nil : listeningPortHelp
        let attention = facts.latestAttention.map {
            "Latest authoritative attention: \($0.accessibilityDescription())"
        }
        let git = facts.gitContext.map { "Git: \($0.branch) · \($0.isDirty ? "dirty" : "clean")" }
        return [facts.workingDirectory, git, process, listeners, attention, role, permission, folderAccess]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func attentionReasonLabel(_ attention: PaneAttentionItem) -> String {
        switch (attention.reason, attention.source) {
        case (.permissionRequest, .vendorOfficialHook): "Permission reported"
        case (.permissionRequest, .durableHandoff): "Permission"
        case (.returnedResult, _): "Result"
        case (.interruptedHandoff, _): "Interrupted"
        }
    }

    private func attentionSymbol(_ attention: PaneAttentionItem) -> String {
        switch attention.reason {
        case .permissionRequest: "hand.raised"
        case .returnedResult: "envelope"
        case .interruptedHandoff: "bolt.horizontal"
        }
    }

    private func failureLabel(_ handoff: RelayHandoff) -> String {
        switch handoff.attention {
        case .permissionRequired: "Needs permission"
        case .targetNotReady: "Not ready"
        case .targetUnavailable: "Unavailable"
        case nil: "Delivery failed"
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
