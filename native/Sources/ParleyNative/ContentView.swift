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
    @State private var participantsExpanded = true
    /// Nil until the person opens or closes All Workspaces; the default
    /// depends on how many there are.
    @State private var allWorkspacesExpandedChoice: Bool?
    @State private var favouritesExpanded = true
    /// Attached folders are collapsed by default, so each workspace is one line.
    @State private var expandedWorkspaceFolderIDs: Set<String> = []

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
                VoiceDraftView(model: model, voice: model.voice)
                CommandRunNotice(model: model)
                TeamSessionNotice(model: model)
                Divider()
                if model.handoffComposerDraft != nil {
                    handoffComposer
                    Divider()
                }
                if model.visiblePanes.count > 1, !sidebarVisible {
                    paneFocusStrip
                    Divider()
                }
                // Every branch of `terminal` must fill: the pane split does so
                // itself, but the "no pane" and "unavailable" placeholders only
                // took their intrinsic height, and the whole window's content
                // collapsed to the bottom whenever one of them showed.
                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
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
        .sheet(isPresented: Binding(
            get: { model.teamSessionsPresented },
            set: { if !$0 { model.dismissTeamSessionReview() } }
        )) { TeamSessionsView(model: model) }
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
        .sheet(isPresented: $model.folderManagerPresented) {
            FolderManagerView(model: model)
        }
        .sheet(isPresented: $model.releaseLifecyclePresented) {
            ReleaseLifecycleView(model: model)
        }
        .onChange(of: model.settingsOpenRequestID) { _, requestID in
            guard requestID != nil else { return }
            openSettings()
        }
        .onChange(of: model.statusCenterOpenRequestID) { _, requestID in
            guard requestID != nil else { return }
            openWindow(id: "status-center")
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
                if sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sectionedSidebar
                } else {
                    filteredSidebar
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
                            .font(ChromeFont.heading)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
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
                    .font(ChromeFont.heading)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Menu {
                    Button("Choose New Pane Folder…", action: model.chooseFolder)
                    if model.activeWorkspace?.newPaneFolder != nil {
                        Button("Clear New Pane Folder", action: model.clearWorkspaceNewPaneFolder)
                    }
                    Button(model.folderIdentity.contains(model.defaultFolder, in: model.favouriteFolders) ? "Remove This Folder from Favourites" : "Add This Folder to Favourites") {
                        model.toggleFavouriteFolder(model.defaultFolder)
                    }
                    // A folder that no longer exists cannot be used for new
                    // panes, so it is not offered here. The manager below lists
                    // it as missing with a Remove button.
                    let favouriteAlternatives = model.favouriteFolders.filter {
                        !model.folderIdentity.matches($0, model.defaultFolder)
                            && model.folderIdentity.exists($0)
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
                        !model.folderIdentity.matches($0, model.defaultFolder)
                            && !model.favouriteFolders.contains($0)
                            && model.folderIdentity.exists($0)
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
                            Button("Clear Recent Folders") { model.clearRecentFolders() }
                        }
                    }
                    Divider()
                    Button("Manage Folders…") { model.folderManagerPresented = true }
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

    /// The sidebar at many workspaces (Mark's decision, 30 September 2026):
    /// this workspace's panes first, then the workspaces that need the person,
    /// the pinned ones and the recent ones, and every workspace last. The rules
    /// are `WorkspaceSidebarSections`; this only draws them.
    @ViewBuilder private var sectionedSidebar: some View {
        let sections = model.workspaceSidebarSections
        let byID = Dictionary(model.workspaces.map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        Section {
            if participantsExpanded { paneRows(model.layoutOrderedVisiblePanes) }
        } header: {
            sidebarSectionHeader("THIS WORKSPACE", expanded: $participantsExpanded, detail: model.activeWorkspace?.name)
        }
        if !sections.needsAttention.isEmpty {
            Section {
                ForEach(sections.needsAttention.compactMap { byID[$0] }) { workspace in
                    let count = model.workspaceActivity(for: workspace.workspaceID).needsPerson
                    workspaceShortcutRow(workspace, trailing: "\(count)", spokenTrailing: "\(count) waiting on you", emphasised: true)
                }
            } header: {
                sidebarSectionHeader("NEEDS ATTENTION", tone: .orange)
            }
        }
        if !sections.pinned.isEmpty {
            Section {
                ForEach(sections.pinned.compactMap { byID[$0] }) { workspace in
                    workspaceShortcutRow(workspace, trailing: nil)
                }
                .onMove { model.moveWorkspaces(inSubset: sections.pinned, fromOffsets: $0, toOffset: $1) }
            } header: {
                sidebarSectionHeader("PINNED")
            }
        }
        if !sections.recent.isEmpty {
            Section {
                ForEach(sections.recent.compactMap { byID[$0] }) { workspace in
                    workspaceShortcutRow(workspace, trailing: workspace.lastSelectedAt.map { WorkspaceRecency.label(for: $0, now: Date()) },
                                         spokenTrailing: workspace.lastSelectedAt.map { "last used \(WorkspaceRecency.label(for: $0, now: Date()))" })
                }
            } header: {
                sidebarSectionHeader("RECENT")
            }
        }
        let allExpanded = allWorkspacesExpandedChoice ?? sections.allExpandedByDefault
        Section {
            if allExpanded {
                if sections.groups.isEmpty {
                    ForEach(model.workspaces) { workspace in
                        workspaceSidebarRow(workspace)
                    }
                    .onMove { model.moveWorkspaces(fromOffsets: $0, toOffset: $1) }
                } else {
                    // The person's groups in their order, then Ungrouped. A drag
                    // reorders within one group; Move to Group moves between them.
                    ForEach(sections.groups) { group in
                        workspaceGroupHeaderRow(group)
                        if !group.isCollapsed {
                            ForEach(group.workspaces.compactMap { byID[$0] }) { workspace in
                                workspaceSidebarRow(workspace)
                            }
                            .onMove { model.moveWorkspaces(inSubset: group.workspaces, fromOffsets: $0, toOffset: $1) }
                        }
                    }
                    if !sections.ungrouped.isEmpty {
                        HStack(spacing: 6) {
                            Text("Ungrouped")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(sections.ungrouped.count)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 23)
                        .padding(.trailing, 7)
                        .frame(minHeight: 22)
                        .accessibilityElement(children: .combine)
                        .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
                        .listRowBackground(Color.clear)
                        ForEach(sections.ungrouped.compactMap { byID[$0] }) { workspace in
                            workspaceSidebarRow(workspace)
                        }
                        .onMove { model.moveWorkspaces(inSubset: sections.ungrouped, fromOffsets: $0, toOffset: $1) }
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Button {
                    allWorkspacesExpandedChoice = !allExpanded
                } label: {
                    Label("ALL WORKSPACES (\(model.workspaces.count))", systemImage: allExpanded ? "chevron.down" : "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(ChromeFont.heading)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(allExpanded ? "Collapse all workspaces" : "Expand all workspaces")
                Spacer()
                workspaceActionsMenu
            }
        }
    }

    /// A group in All Workspaces: click to show or hide its workspaces.
    private func workspaceGroupHeaderRow(_ group: WorkspaceSidebarSections.Group) -> some View {
        Button {
            model.setCollapsed(!group.isCollapsed, for: group)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(group.workspaces.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Group \(group.name)")
        .accessibilityValue("\(group.workspaces.count) workspace\(group.workspaces.count == 1 ? "" : "s"), \(group.isCollapsed ? "collapsed" : "expanded")")
        .accessibilityHint(group.isCollapsed ? "Show its workspaces" : "Hide its workspaces")
        .snapshotContextMenu(workspaceGroupMenuItems(group))
        .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
        .listRowBackground(Color.clear)
    }

    private func workspaceGroupMenuItems(_ group: WorkspaceSidebarSections.Group) -> [ToolbarMenuItem] {
        [
            .action("Rename Group…") { model.renameWorkspaceGroup(group) },
            .action("Move Group Up", isEnabled: model.canMoveWorkspaceGroup(group, by: -1)) { model.moveWorkspaceGroup(group, by: -1) },
            .action("Move Group Down", isEnabled: model.canMoveWorkspaceGroup(group, by: 1)) { model.moveWorkspaceGroup(group, by: 1) },
            .separator,
            .action("Delete Group…", isDestructive: true) { model.deleteWorkspaceGroup(group) },
        ]
    }

    /// While filtering, matches only: the workspaces, then this workspace's panes.
    @ViewBuilder private var filteredSidebar: some View {
        Section {
            ForEach(filteredWorkspaces) { workspace in
                // Matched by a folder: show the folders, which are collapsed by default.
                workspaceSidebarRow(workspace, showFolders: !workspace.name.localizedCaseInsensitiveContains(
                    sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } header: {
            HStack(spacing: 6) {
                sidebarSectionHeader("WORKSPACES")
                Spacer()
                workspaceActionsMenu
            }
        }
        Section {
            paneRows(filteredVisiblePanes)
        } header: {
            sidebarSectionHeader("THIS WORKSPACE", detail: model.activeWorkspace?.name)
        }
    }

    /// Section headings are the chrome's only uppercase: 9 pt mono, secondary,
    /// or a semantic tone when the section itself states a fact.
    private func sidebarSectionHeader(_ title: String, expanded: Binding<Bool>? = nil, detail: String? = nil,
                                      tone: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let expanded {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    Label(title, systemImage: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded.wrappedValue ? "Collapse" : "Expand") \(title.lowercased())")
            } else {
                Text(title)
            }
            if let detail {
                Text(detail)
                    .font(ChromeFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(ChromeFont.heading)
        .foregroundStyle(tone ?? Color.secondary)
    }

    @ViewBuilder private func paneRows(_ panes: [WorkbenchPane]) -> some View {
        ForEach(panes) { pane in
            HStack(spacing: 6) {
                Button {
                    model.select(pane)
                } label: {
                    PaneRow(
                        pane: pane,
                        facts: model.sidebarFacts(for: pane),
                        managedWorktreeBranch: model.managedWorktree(forPane: pane.id)?.branch,
                        awaitingAnswerCount: model.awaitingAnswerCount(for: pane.id),
                        unreadResultCount: model.unreadResultCount(forPane: pane.id),
                        latestFailure: model.latestFailure(for: pane.id),
                        permissionProfileName: model.permissionProfileName(for: pane)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(pane.displayName), \(pane.kind.label) pane")
                .accessibilityValue(paneAccessibilityValue(pane))
                .accessibilityHint("Focus this pane")
                paneRecoveryButton(pane)
            }
            .listRowBackground(pane.isActive ? Color.accentColor.opacity(0.14) : Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
            .overlay {
                PaneContextMenu(items: paneMenuItems(pane))
            }
        }
    }

    /// A workspace in Needs Attention, Pinned or Recent: one line, no folders.
    private func workspaceShortcutRow(_ workspace: WorkbenchWorkspace, trailing: String?, spokenTrailing: String? = nil,
                                      emphasised: Bool = false) -> some View {
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
                if let trailing {
                    // Emphasis here means the person is needed, so it is orange,
                    // the same tone as the section heading above it.
                    Text(trailing)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                        .foregroundStyle(emphasised ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(workspace.isActive ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(workspaceTabHelp(workspace))
        .accessibilityLabel("Workspace \(workspace.name)")
        // The label replaces the button's text, so the count or time is spoken here.
        .accessibilityValue(([spokenTrailing].compactMap { $0 } + [workspaceTabAccessibilityValue(workspace)]).joined(separator: ", "))
        .accessibilityHint("Open workspace")
        .snapshotContextMenu(workspaceMenuItems(workspace))
        .listRowInsets(EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5))
        .listRowBackground(Color.clear)
    }

    private func workspaceSidebarRow(_ workspace: WorkbenchWorkspace, showFolders: Bool = false) -> some View {
        let paneCount = model.panes.count { $0.workspaceID == workspace.workspaceID }
        let waiting = model.waitingCount(for: workspace.id)
        let failures = model.failureCount(for: workspace.id)
        let unread = model.unreadResultCount(forWorkspace: workspace.id)
        let foldersExpanded = showFolders || expandedWorkspaceFolderIDs.contains(workspace.workspaceID)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                if workspace.isFolderless {
                    Color.clear
                        .frame(width: 22, height: 28)
                        .accessibilityHidden(true)
                } else {
                    Button {
                        if foldersExpanded {
                            expandedWorkspaceFolderIDs.remove(workspace.workspaceID)
                        } else {
                            expandedWorkspaceFolderIDs.insert(workspace.workspaceID)
                        }
                    } label: {
                        // A plain button answers only on its drawn pixels, so the
                        // 9-point glyph alone took several clicks to hit: the
                        // whole row-high box answers instead.
                        Image(systemName: foldersExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle())
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
                .snapshotContextMenu(workspaceMenuItems(workspace))
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
            Button {
                model.attachFolder(to: workspace)
            } label: {
                Text("Attach…")
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .font(.system(size: 9, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Attach a folder to \(workspace.name)")
        }
        .padding(.leading, 40)
        .padding(.trailing, 7)
        .frame(minHeight: 24)
    }

    private func workspaceFolderRow(_ folder: String, workspace: WorkbenchWorkspace) -> some View {
        let name = WorkspaceFolderIdentity.displayName(for: folder)
        let displayPath = (WorkspaceFolderIdentity.normalized(folder) as NSString).abbreviatingWithTildeInPath
        let isNewPaneFolder = workspace.newPaneFolder.map {
            model.folderIdentity.matches($0, folder)
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
        .padding(.leading, 40)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(folder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Attached folder \(name)")
        .accessibilityValue(isNewPaneFolder ? "\(displayPath), used for new panes" : displayPath)
        .snapshotContextMenu(attachedFolderMenuItems(folder, workspace: workspace))
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
        .accessibilityHint("Create a folderless workspace, one from a saved layout, or a group")
    }

    @ViewBuilder
    private var workspaceCreationMenuItems: some View {
        Button("New Workspace", action: model.createWorkspace)
        Button("New Group…") { model.newWorkspaceGroup(moving: nil) }
        if !model.savedLayouts.isEmpty {
            Menu("From Saved Layout") {
                ForEach(model.savedLayouts) { layout in
                    Button(layout.name) { model.createWorkspace(from: layout) }
                }
            }
        }
    }

    /// An AppKit snapshot like the pane menus: a model change while it is open
    /// no longer rebuilds its items under the pointer.
    private func workspaceMenuItems(_ workspace: WorkbenchWorkspace) -> [ToolbarMenuItem] {
        var items: [ToolbarMenuItem] = [
            .action("Rename…") { model.rename(workspace) },
            .action(workspace.pinned ? "Unpin from Sidebar" : "Pin to Sidebar") { model.setPinned(!workspace.pinned, for: workspace) },
            .submenu("Move to Group", items: model.workspaceGroups.map { group in
                .action(group.name, systemImage: workspace.groupID == group.id ? "checkmark" : nil) { model.move(workspace, toGroup: group.id) }
            } + [
                .action("Ungrouped", systemImage: model.workspaceGroups.contains(where: { $0.id == workspace.groupID }) ? nil : "checkmark") {
                    model.move(workspace, toGroup: nil)
                },
                .separator,
                .action("New Group…") { model.newWorkspaceGroup(moving: workspace) },
            ]),
            .action("Save Layout…") { model.saveLayout(of: workspace) },
        ]
        if !model.savedLayouts.isEmpty {
            items.append(.submenu("Saved Layouts", items: model.savedLayouts.map { layout in
                .submenu(layout.name, items: [
                    .action("Create New Workspace") { model.createWorkspace(from: layout) },
                    .action("Replace This Workspace…") { model.open(layout, replacing: workspace) },
                    .separator,
                    .action("Delete Saved Layout…", isDestructive: true) { model.delete(layout) },
                ])
            }))
        }
        items.append(.submenu("Automation: \(workspace.automationPolicy.label)", items: WorkspaceAutomationPolicy.allCases.map { policy in
            .action(policy.label, systemImage: policy == workspace.automationPolicy ? "checkmark" : nil) {
                model.setAutomationPolicy(policy, for: workspace)
            }
        }))
        if model.panes.contains(where: { $0.workspaceID == workspace.workspaceID && $0.isWorkspaceLead }) {
            items.append(.action("Clear Workspace Lead") { model.clearWorkspaceLead(workspace) })
        }
        items.append(.action("Attach Folder…") { model.attachFolder(to: workspace) })
        if !workspace.attachedFolders.isEmpty {
            items.append(.submenu("Attached Folders", items: workspace.attachedFolders.enumerated().map { index, folder in
                .submenu(WorkspaceFolderIdentity.displayName(for: folder), items: [
                    .action("Use for New Panes") { model.setWorkspaceFolder(folder) },
                    .action(model.folderIdentity.contains(folder, in: model.favouriteFolders) ? "Remove from Favourites" : "Add to Favourites") {
                        model.toggleFavouriteFolder(folder)
                    },
                    .action("Open New Workspace Here") { model.createNewWorkspace(folder: folder) },
                    .separator,
                    .action("Move Earlier", isEnabled: index > 0) { model.moveAttachedFolder(folder, in: workspace, by: -1) },
                    .action("Move Later", isEnabled: index < workspace.attachedFolders.count - 1) {
                        model.moveAttachedFolder(folder, in: workspace, by: 1)
                    },
                    .separator,
                    .action("Detach from Workspace", isDestructive: true) { model.detachFolder(folder, from: workspace) },
                ])
            }))
        }
        items += [
            .separator,
            .action("Move Workspace Up", isEnabled: model.canMove(workspace, by: -1)) { model.move(workspace, by: -1) },
            .action("Move Workspace Down", isEnabled: model.canMove(workspace, by: 1)) { model.move(workspace, by: 1) },
            .separator,
            .action("Close Workspace…", isEnabled: model.workspaces.count > 1, isDestructive: true) { model.close(workspace) },
        ]
        return items
    }

    private func attachedFolderMenuItems(_ folder: String, workspace: WorkbenchWorkspace) -> [ToolbarMenuItem] {
        [
            .action("Use for New Panes") { model.setWorkspaceFolder(folder) },
            .action(model.folderIdentity.contains(folder, in: model.favouriteFolders) ? "Remove from Favourites" : "Add to Favourites") {
                model.toggleFavouriteFolder(folder)
            },
            .action("Open New Workspace Here") { model.createNewWorkspace(folder: folder) },
            .separator,
            .action("Detach from Workspace", isDestructive: true) { model.detachFolder(folder, from: workspace) },
        ]
    }

    private func favouriteFolderMenuItems(_ folder: String) -> [ToolbarMenuItem] {
        [
            .action("Open New Workspace Here") { model.createNewWorkspace(folder: folder) },
            .separator,
            .action("Remove from Favourites") { model.toggleFavouriteFolder(folder) },
        ]
    }

    private func paneMenuItems(_ pane: WorkbenchPane) -> [ToolbarMenuItem] {
        var items: [ToolbarMenuItem] = [.action("Rename…") { model.rename(pane) }]
        if pane.kind.isAgent {
            if pane.isWorkspaceLead {
                items.append(.action("Remove as Workspace Lead") {
                    if let workspace = model.workspaces.first(where: { $0.workspaceID == pane.workspaceID }) {
                        model.clearWorkspaceLead(workspace)
                    }
                })
            } else {
                items.append(.action("Make Workspace Lead") { model.setWorkspaceLead(pane) })
            }
            items.append(.separator)
            items.append(.action(pane.role == nil ? "Set Routing Role…" : "Change Routing Role…") {
                model.setRole(pane)
            })
            if pane.role != nil {
                items.append(.action("Clear Routing Role") { model.clearRole(pane) })
            }
            items.append(.separator)
            items.append(.action("Browser & Tool Capability…") { model.showPaneToolCapabilitySummary(pane) })
            if pane.isStarted {
                items.append(.action("Folder Access…") { model.showFolderAccess(pane) })
            }
        }
        items.append(.separator)
        if pane.kind.isAgent {
            if !pane.isStarted {
                items.append(.action("Start Fresh Session") { model.start(pane) })
            }
            if let plan = VendorResumeAdapter.plan(for: pane.kind) {
                items.append(.action(plan.menuLabel) { model.resume(pane) })
            }
            if pane.isStarted {
                if pane.kind == .copilot && !pane.isDead {
                    items.append(.action("Confirm Copilot Folder Trust…") { model.confirmCopilotFolderTrust(pane) })
                }
                items.append(.action("Restart Fresh Session…") { model.restart(pane) })
                items.append(.action("Stop…") { model.stop(pane) })
            }
        } else {
            items.append(.action("Restart…") { model.restart(pane) })
        }
        let destinations = model.mobilityDestinations(for: pane)
        if !destinations.isEmpty {
            items.append(.separator)
            // Pinned and recent first, then a submenu per group, then
            // Ungrouped; the plain list for a few workspaces and no groups.
            let byID = Dictionary(destinations.map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
            let layout = WorkspaceDestinationMenu.layout(destinations: destinations.map(\.workspaceID), sections: model.workspaceSidebarSections)
            func moves(_ ids: [String]) -> [ToolbarMenuItem] {
                ids.compactMap { byID[$0] }.map { workspace in
                    // A destination that would refuse this pane's role or lead
                    // says so here; choosing it still runs the full check.
                    if let note = PaneMobilityPolicy.destinationConflictNote(
                        pane: pane, targetWorkspaceID: workspace.workspaceID, panes: model.panes
                    ) {
                        return .action("\(workspace.name) (\(note))", isEnabled: false,
                                       help: "Clear the role or lead mark first, or choose another workspace") {}
                    }
                    return .action(workspace.name) { model.movePane(pane, to: workspace) }
                }
            }
            var destinationItems = moves(layout.shortcuts)
            let rest = layout.groups.map { ToolbarMenuItem.submenu($0.name, items: moves($0.workspaces)) }
                + (layout.remainingIsUngrouped
                    ? (layout.remaining.isEmpty ? [] : [.submenu("Ungrouped", items: moves(layout.remaining))])
                    : moves(layout.remaining))
            if !destinationItems.isEmpty, !rest.isEmpty { destinationItems.append(.separator) }
            destinationItems += rest
            items.append(.submenu("Move to Workspace", items: destinationItems))
        }
        items.append(.separator)
        items.append(.action("Terminal Appearance…") { model.showTerminalFontSettings() })
        items.append(.separator)
        items.append(.action("Close Pane…", isDestructive: true) { model.close(pane) })
        return items
    }

    private func favouriteFolderRow(_ folder: String) -> some View {
        let name = WorkspaceFolderIdentity.displayName(for: folder)
        let matchingWorkspaces = model.folderIdentity.workspaces(matching: folder, in: model.workspaces)
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
        .snapshotContextMenu(favouriteFolderMenuItems(folder))
    }

    private func workspaceTabHelp(_ workspace: WorkbenchWorkspace) -> String {
        var folders = workspace.attachedFolders.isEmpty
            ? ["No folders attached"]
            : ["Attached: \(workspace.attachedFolders.joined(separator: ", "))"]
        folders.append(workspace.newPaneFolder.map { "New panes: \($0)" } ?? "New panes: follows active pane")
        return (folders + workspaceTabStatusDetails(workspace) + ["Control-Tab switches workspaces; Command-Shift-O goes to any workspace"])
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

    /// With the sidebar hidden. Past eight workspaces the tabs are the pinned
    /// ones, the current one and those needing the person (`sections.tabs`),
    /// and More opens Go to Workspace for the rest.
    private var workspaceTabs: some View {
        let sections = model.workspaceSidebarSections
        let byID = Dictionary(model.workspaces.map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        return HStack(spacing: 6) {
            ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(sections.tabs.compactMap { byID[$0] }) { workspace in
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
                            .contentShape(Rectangle())
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
                        .snapshotContextMenu(workspaceMenuItems(workspace))
                    }
                }
            }
            // A workspace reached another way (Go to Workspace, Control-Tab)
            // may sit beyond the scrolled tabs; bring its tab into view.
            .onChange(of: model.activeWorkspace?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id, anchor: .center) }
            }
            }

            // Outside the scrolling tabs, so it cannot scroll out of view.
            if sections.tabsOverflow {
                let hidden = model.workspaces.count - sections.tabs.count
                Button {
                    model.showWorkspaceSwitcher()
                } label: {
                    Text("More (\(hidden))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Go to Workspace (Command-Shift-O)")
                .accessibilityLabel("More workspaces")
                .accessibilityValue("\(hidden) not shown as tabs")
                .accessibilityHint("Open Go to Workspace")
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
            VoiceToolbarControl(model: model, voice: model.voice)
            contextPackMenu
            recipeMenu
            if model.canReturn {
                returnMenu
            }

            if hasWaitingWork {
                Divider().frame(height: 18)
                waitingMenu
            }

            WindowDragArea()
                .frame(minWidth: 6, maxWidth: .infinity)
                .frame(height: 42)
            Button(action: { model.toggleFocusCanvas() }) {
                Label(
                    model.focusCanvasPaneID == nil ? "Zoom" : "Unzoom",
                    systemImage: model.focusCanvasPaneID == nil ? "rectangle.inset.filled" : "rectangle.grid.2x2"
                )
            }
            .disabled(model.activePane == nil)
            .accessibilityLabel(model.focusCanvasPaneID == nil ? "Zoom the selected pane" : "Unzoom")
            .help(model.focusCanvasPaneID == nil ? "Enlarge the selected pane while keeping peers visible" : "Restore the pane proportions")
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
            VoiceToolbarControl(model: model, voice: model.voice)
            WindowDragArea()
                .frame(minWidth: 6, maxWidth: .infinity)
                .frame(height: 42)
            Button(action: { model.toggleFocusCanvas() }) {
                Image(systemName: model.focusCanvasPaneID == nil ? "rectangle.inset.filled" : "rectangle.grid.2x2")
            }
            .disabled(model.activePane == nil)
            .accessibilityLabel(model.focusCanvasPaneID == nil ? "Zoom the selected pane" : "Unzoom")
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
                !model.folderIdentity.matches($0.cwd, model.defaultFolder)
            } ?? false,
            defaultAgentKind: model.lastAgentVendor
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
            items.append(.message(model.askUnavailableReason ?? "No agent pane can be asked right now."))
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
            accessibilityLabel: "Ask another agent",
            accessibilityValue: "\(model.askTargets.count) available target\(model.askTargets.count == 1 ? "" : "s")",
            accessibilityHint: "Choose another agent pane for a correlated question",
            items: items
        )
    }

    private var reviewMenu: ToolbarActionMenu {
        ToolbarActionMenu(
            title: "Review", systemImage: "doc.text.magnifyingglass",
            accessibilityLabel: "Review with another agent",
            help: "Preview repository changes or a selected file, then ask another agent pane to review it",
            accessibilityHint: "Preview current changes, a plan, or a file before asking another agent pane",
            items: model.askTargets.isEmpty
                ? [.message(model.askUnavailableReason ?? "No agent pane can be asked right now.")]
                : [
                    .submenu("Current Changes", items: reviewTargetItems { model.reviewChanges(with: $0) }),
                    .submenu("Plan or File…", items: reviewTargetItems { model.reviewFile(with: $0) })
                ]
        )
    }

    private var contextPackMenu: ToolbarActionMenu {
        let lane = AgentDraftMenuProjection.lane(reviews: model.pendingContextReviews)
        // Built again each time the menu opens so draft ages are current; the
        // static copy serves the overflow submenu.
        func buildItems() -> [ToolbarMenuItem] {
            var items: [ToolbarMenuItem] = []
            let lane = AgentDraftMenuProjection.lane(reviews: model.pendingContextReviews)
            func open(_ entry: AgentDraftMenuEntry) {
                if let review = model.pendingContextReviews.first(where: { $0.id == entry.id }) {
                    model.presentContextReview(review)
                }
            }
            if !lane.waiting.isEmpty {
                items.append(.heading("Waiting for Your Approval"))
                items += lane.waiting.map { entry in
                    .action(entry.title, systemImage: "person.crop.circle.badge.clock") { open(entry) }
                }
                items.append(.separator)
            }
            if !lane.saved.isEmpty {
                items.append(.heading("Saved Agent Drafts"))
                items += lane.saved.map { entry in
                    .action(entry.title, systemImage: "doc.badge.ellipsis") { open(entry) }
                }
                if lane.olderCount > 0 {
                    items.append(.action("\(lane.olderCount) older \(lane.olderCount == 1 ? "draft" : "drafts") in Status Center…", systemImage: "list.bullet") {
                        model.refreshStatusCenterQuietly()
                        model.requestStatusCenterSegment(.live)
                        openWindow(id: "status-center")
                    })
                }
                items.append(.action("Discard All Editable Drafts…", systemImage: "trash", isDestructive: true) {
                    model.discardAllEditableDrafts()
                })
                items.append(.separator)
            }
            if !model.deletableContextReviews.isEmpty {
                items.append(.action("Delete Saved Context…", systemImage: "trash", isDestructive: true) {
                    model.deleteSavedContext(model.deletableContextReviews)
                })
                items.append(.separator)
            }
            if let draft = model.contextPackDraft {
                items += [
                    .action("Open Context Pack “\(draft.pack.name)”") { model.presentContextPack() },
                    .separator
                ]
            }
            items.append(.action("New Context Pack…", isEnabled: model.canCreateContextPack) { model.newContextPack() })
            items += [
                .separator,
                .action("How Context Works", systemImage: "questionmark.circle") {
                    model.requestHelp(topicID: "context-model")
                    openWindow(id: "help")
                }
            ]
            return items
        }
        let items = buildItems()
        return ToolbarActionMenu(
            title: model.pendingContextReviews.isEmpty ? "Context" : "Context \(model.pendingContextReviews.count)",
            systemImage: model.pendingContextReviews.isEmpty ? "shippingbox" : "shippingbox.fill",
            accessibilityLabel: "Context packs and references",
            accessibilityValue: model.pendingContextReviews.isEmpty
                ? (model.contextPackDraft.map { "\($0.pack.parts.count) sources" } ?? "No draft")
                : "\(lane.waiting.count) waiting for your approval, \(lane.editableCount) saved agent \(lane.editableCount == 1 ? "draft" : "drafts")",
            help: "Assemble explicit attributed sources into an editable context pack before a cross-vendor handoff",
            accessibilityHint: "Open an editable attributed context pack or review an agent-staged draft",
            items: items,
            itemsOnOpen: buildItems
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
        var editItems: [ToolbarMenuItem] = model.recipes.map { recipe in
            .action(recipe.name) { model.edit(recipe) }
        }
        editItems += [.separator, .action("Restore Defaults…") { model.restoreDefaultRecipes() }]
        items += [.separator, .submenu("Edit Recipes", items: editItems)]
        return ToolbarActionMenu(
            title: "Recipes", systemImage: "list.bullet.rectangle",
            accessibilityLabel: "Recipes",
            accessibilityValue: model.workspaceLead.map { "Lead: \($0.displayName)" } ?? "No workspace lead",
            help: "Send one reviewed recipe instruction to the workspace lead, or edit the recipe templates",
            accessibilityHint: "Choose a recipe to run with the workspace lead, or edit the recipe templates",
            items: items
        )
    }

    private var returnMenu: ToolbarActionMenu {
        // Shown only while the active pane holds an unanswered Ask: this is the
        // manual completion for a target that printed its reply without
        // running `parley answer`, not a general send.
        ToolbarActionMenu(
            title: "Answer", systemImage: "arrow.turn.down.left",
            isEnabled: model.canReturn,
            accessibilityLabel: "Answer waiting Ask",
            accessibilityValue: model.canReturn ? "A pane is waiting for this pane's answer" : "No waiting Ask",
            accessibilityHint: "Complete the Ask this pane was asked, by hand, when it printed its reply without running parley answer",
            items: model.activePaneConsultations.map { consultation in
                .action("Answer \(consultation.sourceName)…") { model.returnConsultation(consultation) }
            }
        )
    }

    private var compactActionsMenu: ToolbarActionMenu {
        var items = [reviewMenu.asSubmenu, contextPackMenu.asSubmenu, recipeMenu.asSubmenu]
        if model.canReturn { items.append(returnMenu.asSubmenu) }
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

    /// One line under the grid carrying every honest fact: the connection,
    /// what is in flight and what came back, the top notice with its one
    /// action and the rest behind "+N", then the selected pane, the protocol
    /// and the palette. The notices used to stack as banners above the grid.
    private var workbenchStatusBar: some View {
        let lane = noticeLane
        let inFlight = model.consultations.count + model.activeDelegations.count
        let returned = model.activeWorkspace.map { model.unreadResultCount(forWorkspace: $0.id) } ?? 0
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ChromeColor.connection(model.connectionState))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(WorkbenchChromeProjection.connectionLabel(model.connectionState))
                    .foregroundStyle(model.connectionState == .connected ? Color.secondary : ChromeColor.connection(model.connectionState))
            }
            .help("Coordination core: \(WorkbenchChromeProjection.connectionLabel(model.connectionState))")
            if inFlight > 0 || returned > 0 {
                statusSeparator
                HStack(spacing: 5) {
                    ChromeWireLine(color: inFlight > 0 ? .accentColor : .secondary, length: 10)
                    Text([inFlight > 0 ? "\(inFlight) in flight" : nil, returned > 0 ? "\(returned) returned" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                .help("Questions and delegations awaiting a result, and results waiting to be read in this workspace")
                .accessibilityElement(children: .combine)
            }
            if let top = lane.first {
                statusSeparator
                statusNotice(top: top, rest: Array(lane.dropFirst()))
            }
            Spacer(minLength: 6)
            if let pane = model.activePane {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ChromeMonogram(kind: pane.kind, size: 14)
                        Text(pane.displayName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let role = pane.role {
                            Text("@\(role)")
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("selected")
                    }
                    EmptyView()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(pane.displayName) selected\(pane.role.map { ", @\($0)" } ?? "")")
            }
            ViewThatFits(in: .horizontal) {
                Text("Protocol \(AgentProtocol.version) · \(model.visiblePanes.count) pane\(model.visiblePanes.count == 1 ? "" : "s")")
                    .font(ChromeFont.meta)
                EmptyView()
            }
            if !model.workspaceHandoffs.isEmpty {
                activityHistoryMenu
                    .fixedSize()
            }
            Button(action: model.showCommandPalette) {
                Text("⌘K Actions")
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the Command Palette")
                .accessibilityLabel("Open Command Palette")
        }
        .font(ChromeFont.secondary.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(ChromeSurface.paper)
        .accessibilityElement(children: .contain)
    }

    private var statusSeparator: some View {
        Rectangle()
            .fill(ChromeRule.hairline)
            .frame(width: 1, height: 12)
            .accessibilityHidden(true)
    }

    /// The top notice as one line: a dot in its tone, the title, the detail
    /// while there is room, its single action, and the remaining notices in
    /// priority order behind "+N". The detail is always in the help.
    private func statusNotice(top: WorkbenchNotice, rest: [WorkbenchNotice]) -> some View {
        let tone = ChromeColor.tone(top.tone)
        return HStack(spacing: 7) {
            Circle()
                .fill(tone)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(top.title)
                        .font(ChromeFont.secondaryMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(top.detail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(top.title)
                    .font(ChromeFont.secondaryMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(top.title). \(top.detail)")
            if let label = top.actionLabel, let action = top.action {
                Button(label) { perform(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
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
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(rest.map(\.title).joined(separator: "\n"))
                .accessibilityLabel("\(rest.count) more notice\(rest.count == 1 ? "" : "s")")
                .accessibilityHint("Open the remaining notices in priority order")
            }
        }
        .help(top.detail)
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
            dockVisible: model.collaborationDockVisible,
            protocolVersion: AgentProtocol.version
        )
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
        case .openWorktrees: "Open the Worktrees window on this folder's repository"
        case .stopRecipe: "Send Control-C to the lead pane after confirmation"
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
            openWindow(id: "worktrees")
            model.selectWorktreeRepository(containing: path)
        case .stopRecipe:
            model.interruptActiveRecipeRun()
        }
    }

    private func noticeHandoff(_ id: String) -> RelayHandoff? {
        model.workspaceHandoffs.first(where: { $0.id == id })
            ?? (model.primaryActivity?.id == id ? model.primaryActivity : nil)
    }

    /// An AppKit snapshot like the toolbar menus: handoffs change while an
    /// agent works, and a live menu rebuilt its items under the pointer.
    private var activityHistoryMenu: ToolbarActionMenu {
        let count = min(model.workspaceHandoffs.count, 12)
        return ToolbarActionMenu(
            title: "History", systemImage: "clock.arrow.circlepath", iconOnly: true,
            accessibilityLabel: "Recent collaboration history",
            accessibilityValue: "\(count) recent item\(count == 1 ? "" : "s")",
            help: "Recent collaboration in this workspace",
            accessibilityHint: "Inspect recent handoffs in this workspace",
            items: [],
            itemsOnOpen: { model.workspaceHandoffs.prefix(12).map(activityHistoryItem) },
            secondary: true
        )
    }

    private func activityHistoryItem(_ item: RelayHandoff) -> ToolbarMenuItem {
        var items: [ToolbarMenuItem] = [.message(activitySubject(item.text))]
        if item.state == .failed || item.state == .interrupted,
           let failure = item.transitions.last?.detail, !failure.isEmpty {
            items.append(.message(failure))
        }
        var offeredRead = false
        if let result = item.resultText, !result.isEmpty, item.state == .completed || item.kind == .delegate {
            items += [.separator, .message(result)]
            if item.hasUnreadResult {
                items.append(.action("Mark Result Read") { model.markRead(item) })
                offeredRead = true
            }
        }
        // A failure or request usually has no result text, so this sits
        // outside the result block (Agy's review of MR !124).
        if item.awaitsAcknowledgement, !offeredRead {
            items.append(.action("Mark Seen") { model.markRead(item) })
        }
        items += [
            .separator,
            .action("Focus \(item.sourceName)", isEnabled: model.canFocus(item.sourcePaneID)) { model.focus(item, target: false) },
            .action("Focus \(item.targetName)", isEnabled: model.canFocus(item.targetPaneID)) { model.focus(item, target: true) },
        ]
        if item.attention != nil {
            items += [.separator, .action(attentionActionLabel(item), isEnabled: model.canFocus(item.targetPaneID)) { model.focus(item, target: true) }]
            if item.attention == .permissionRequired {
                items.append(.action("Open Permission Guide") {
                    model.requestHelp(topicID: "cli-permissions")
                    openWindow(id: "help")
                })
            }
        }
        if item.canRetrySafely {
            items += [.separator, .action("Retry Original Delivery…") { model.retry(item) }]
        } else if item.state == .failed && item.kind == .delegate {
            items += [.separator, .action("Delegated work cannot be delivery-retried", isEnabled: false) {}]
        } else if item.state == .failed && item.kind != .ask {
            items += [.separator, .action("Retry unavailable — delivery may have started", isEnabled: false) {}]
        }
        if let consultation = model.consultation(for: item) {
            items += [.separator, .action("Cancel Ask…", isDestructive: true) { model.cancel(consultation) }]
        }
        return .submenu("\(item.sourceName) → \(item.targetName) · \(item.state.rawValue)", items: items)
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
            .contentShape(Rectangle())
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
            return (awaiting > 1 ? "Answer \(awaiting)" : "Answer", .accentColor)
        }
        let unread = model.unreadResultCount(forPane: pane.id)
        if unread > 0 { return (unread > 1 ? "Result \(unread)" : "Result", .accentColor) }
        return switch WorkbenchStateProjection.pane(pane) {
        case .empty, .running: nil
        case .stopped: ("Stopped", .secondary)
        case let .exited(status): (status.map { "Exited \($0)" } ?? "Exited", .red)
        case .protocolStale: ("Restart for protocol", .orange)
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
            // A workspace with no panes is a valid state, not a dead end: its
            // attachments, New Pane Folder and history are all still here.
            ContentUnavailableView {
                Label("No panes in this workspace", systemImage: "rectangle.split.2x1")
            } description: {
                Text("Open a shell here, or start an agent and choose its vendor in the review. The workspace, its folders and its history stay either way.")
            } actions: {
                HStack {
                    Button("New Shell") { model.create(.shell, direction: .horizontal) }
                    // Return opens the agent review, which starts nothing by itself.
                    Button("New Agent…") { model.createAgent(direction: .horizontal) }
                        .keyboardShortcut(.defaultAction)
                }
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
            .background(ChromeSurface.glass)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                // The outer ring is selection and nothing else; attention is a
                // separate inner ring. Position alone tells them apart, so a
                // selected pane looks the same whether or not it has attention.
                let rings = PaneChromeRings.forPane(
                    selected: paneSurface.containsActivePane, attention: attention?.reason)
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(ChromeColor.color(rings.outer), lineWidth: rings.outerWidth)
                    if let inner = rings.inner {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(ChromeColor.color(inner), lineWidth: rings.innerWidth)
                            .padding(4)
                    }
                }
                .allowsHitTesting(false)
            }
            .shadow(
                color: attention.map { ChromeColor.attention($0.reason).opacity(0.28) }
                    ?? (paneSurface.containsActivePane ? Color.accentColor.opacity(0.22) : Color.clear),
                radius: 4
            )
            .padding(4)
        }
    }

    /// The live handoff this pane is party to, if any: drawn as the wire in
    /// its header so a glance says who it is talking to.
    private func wireHandoff(for pane: WorkbenchPane) -> RelayHandoff? {
        let live: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        return model.workspaceHandoffs.first {
            live.contains($0.state) && ($0.sourcePaneID == pane.id || $0.targetPaneID == pane.id)
        }
    }

    /// Left to right: who, what it is called, how it routes, who it is
    /// talking to, what state that is in; facts sit right in mono. Selection
    /// is the ring and the name's weight, never a tinted header.
    private func paneChromeHeader(_ pane: WorkbenchPane) -> some View {
        let facts = model.sidebarFacts(for: pane)
        return HStack(spacing: 7) {
            ChromeMonogram(kind: pane.kind, size: 18)
            Text(pane.displayName)
                .font(.system(size: 11, weight: pane.isActive ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            if pane.isWorkspaceLead {
                ChromeChip("Lead", color: .secondary)
            }
            if let role = pane.role {
                Text("@\(role)")
                    .font(ChromeFont.meta)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let handoff = wireHandoff(for: pane) {
                let outgoing = handoff.sourcePaneID == pane.id
                let other = outgoing ? handoff.targetKind : handoff.sourceKind
                let otherName = outgoing ? handoff.targetName : handoff.sourceName
                HStack(spacing: 3) {
                    if !outgoing, let other { ChromeMonogram(kind: other, size: 14) }
                    ChromeWireLine(color: ChromeColor.handoff(handoff))
                    if outgoing, let other { ChromeMonogram(kind: other, size: 14) }
                }
                .help("\(handoff.kind.label) \(outgoing ? "to" : "from") \(otherName) · \(handoff.state.rawValue)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(handoff.kind.label) \(outgoing ? "to" : "from") \(otherName), \(handoff.state.rawValue)")
            }
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Text(WorkspaceFolderIdentity.displayName(for: pane.cwd))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let git = facts.gitContext {
                        Text("·")
                        Text(git.branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if git.isDirty {
                            Text("dirty")
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                Text(WorkspaceFolderIdentity.displayName(for: pane.cwd))
                    .lineLimit(1)
                    .truncationMode(.middle)
                EmptyView()
            }
            .font(ChromeFont.meta)
            .foregroundStyle(.secondary)
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
            PaneActionsMenu(
                accessibilityLabel: "Pane actions for \(pane.displayName)",
                items: [
                    .action(model.focusCanvasPaneID == pane.id ? "Unzoom" : "Zoom Pane") {
                        model.toggleFocusCanvas(paneID: pane.id)
                    },
                    .separator,
                ] + paneMenuItems(pane)
            )
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .background(ChromeSurface.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChromeRule.soft).frame(height: 1).accessibilityHidden(true)
        }
        .onTapGesture(count: 2) {
            model.toggleFocusCanvas(paneID: pane.id)
        }
        .onTapGesture {
            model.select(pane)
        }
        .focusable()
        .accessibilityLabel("Focus \(pane.displayName), \(pane.kind.label) pane")
        .accessibilityValue(paneAccessibilityValue(pane))
        .accessibilityHint("Select this terminal; double-click to zoom or unzoom it")
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
    /// This split's divider: whether it holds the resize cursor it pushed.
    @State private var resizeCursor = ResizeCursorHold()

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

    private func applyResizeCursor(_ change: ResizeCursorHold.Change, direction: SplitDirection) {
        switch change {
        case .push: (direction == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        case .pop: NSCursor.pop()
        case .none: break
        }
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
                applyResizeCursor(resizeCursor.hover(hovering, allowed: focusPaneID == nil), direction: direction)
            }
            // Zooming hides the divider's purpose, and a divider removed under
            // the pointer never hears the hover end: give the cursor back.
            .onChange(of: focusPaneID) { _, focused in
                if focused != nil { applyResizeCursor(resizeCursor.release(), direction: direction) }
            }
            .onDisappear { applyResizeCursor(resizeCursor.release(), direction: direction) }
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
    /// Branch of the Parley-managed worktree containing this pane, if any.
    var managedWorktreeBranch: String? = nil
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
                    if let configuration = pane.containerConfiguration {
                        Text([configuration.bypassVendorPermissions ? "CONTAINER · BYPASS" : "CONTAINER",
                              configuration.publishedPort.map { "PORT \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(ChromeFont.meta).foregroundStyle(configuration.bypassVendorPermissions ? Color.orange : Color.secondary)
                            .help(configuration.permissionModeLabel
                                + (configuration.publishedPort.map { " · port \($0) forwarded from this Mac’s loopback" } ?? ""))
                    }
                    if pane.isWorkspaceLead {
                        // Lead is identity, not a state or a route: neutral.
                        ChromeChip("Lead", color: .secondary)
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
                    if let managedWorktreeBranch {
                        Text("·")
                        Text("worktree \(managedWorktreeBranch)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("This pane works in a Git worktree Parley created or bound to a team. The Team Sessions sheet and the worktree browser show its recorded base.")
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
        case .protocolStale: return ("Restart for protocol", .orange, .process)
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
