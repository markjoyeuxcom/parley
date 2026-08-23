import ParleyCore
import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedID: String?

    private var commands: [PaletteCommand] {
        let all = model.paletteCommands
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return CommandPaletteSearch.results(query: query, items: all.map(\.item))
            .compactMap { byID[$0.id] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search workspaces, panes, Ask targets and activity", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit(runSelected)
                    .accessibilityLabel("Command search")
                Text("⌘K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            Divider()

            if commands.isEmpty {
                ContentUnavailableView(
                    "No matching command",
                    systemImage: "magnifyingglass",
                    description: Text("Try a workspace, pane, vendor, folder, handoff state or message term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(commands) { command in
                                commandRow(command)
                                    .id(command.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: selectedID) { _, selection in
                        guard let selection else { return }
                        reader.scrollTo(selection, anchor: .center)
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Text("↑↓ Navigate")
                Text("Return Open")
                Text("Esc Close")
                Spacer()
                Text("\(commands.count) result\(commands.count == 1 ? "" : "s")")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 32)
        }
        .frame(width: 680, height: 500)
        .onAppear {
            selectedID = commands.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedID = commands.first?.id
        }
        .onExitCommand(perform: close)
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
    }

    private func commandRow(_ command: PaletteCommand) -> some View {
        Button {
            run(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.item.category.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(command.item.category == .ask ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(command.item.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Text(command.item.category.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedID == command.id ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Button("\(command.item.category.label): \(command.item.title)") {
                run(command)
            }
            .accessibilityHint(command.item.detail)
        }
        .onHover { hovering in
            if hovering { selectedID = command.id }
        }
    }

    private func moveSelection(by offset: Int) {
        guard !commands.isEmpty else { return }
        let current = selectedID.flatMap { selection in
            commands.firstIndex(where: { $0.id == selection })
        } ?? 0
        let next = min(max(current + offset, 0), commands.count - 1)
        selectedID = commands[next].id
    }

    private func runSelected() {
        guard let command = commands.first(where: { $0.id == selectedID }) ?? commands.first else { return }
        run(command)
    }

    private func run(_ command: PaletteCommand) {
        close()
        if case .openStatusCenter = command.action {
            openWindow(id: "status-center")
            return
        }
        Task { @MainActor in
            await Task.yield()
            model.performPaletteCommand(command)
        }
    }

    private func close() {
        model.commandPalettePresented = false
        model.terminalHandle.focus()
    }
}

private extension CommandPaletteCategory {
    var label: String {
        switch self {
        case .action: "ACTION"
        case .workspace: "WORKSPACE"
        case .pane: "PANE"
        case .ask: "ASK"
        case .activity: "ACTIVITY"
        }
    }

    var systemImage: String {
        switch self {
        case .action: "command"
        case .workspace: "folder"
        case .pane: "terminal"
        case .ask: "arrow.turn.up.right"
        case .activity: "clock.arrow.circlepath"
        }
    }
}
