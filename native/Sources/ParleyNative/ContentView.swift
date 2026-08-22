import ParleyCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
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
                Button {
                    model.select(pane)
                } label: {
                    PaneRow(
                        pane: pane,
                        awaitingAnswerCount: model.awaitingAnswerCount(for: pane.id)
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(pane.isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .contextMenu {
                    Button("Rename…") { model.rename(pane) }
                    Button("Restart…") { model.restart(pane) }
                    Divider()
                    Button("Close Pane…", role: .destructive) { model.close(pane) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("WORKSPACE FOLDER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Choose Folder…", action: model.chooseFolder)
                    let alternatives = model.recentFolders.filter { $0 != model.defaultFolder }
                    if !alternatives.isEmpty {
                        Divider()
                        Section("Recent") {
                            ForEach(alternatives, id: \.self) { folder in
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
                            Divider()
                            Button("Close Workspace…", role: .destructive) { model.close(workspace) }
                                .disabled(model.workspaces.count == 1)
                        }
                    }
                }
            }

            Menu {
                Button("Choose Folder…", action: model.createWorkspace)
                if !model.recentFolders.isEmpty {
                    Divider()
                    Section("Recent Folders") {
                        ForEach(model.recentFolders, id: \.self) { folder in
                            Button(URL(fileURLWithPath: folder).lastPathComponent) {
                                model.createWorkspace(folder: folder)
                            }
                            .help(folder)
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
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 42)
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
}

private struct PaneRow: View {
    let pane: TmuxPane
    let awaitingAnswerCount: Int

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
                    if pane.kind.isAgent && !pane.relayEnabled {
                        Text("RESTART FOR RELAY")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                    if pane.kind.isAgent && !pane.hasCurrentProtocol {
                        Text("RESTART FOR PROTOCOL")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                }
                Text("\(URL(fileURLWithPath: pane.cwd).lastPathComponent) · \(pane.currentCommand)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
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
}
