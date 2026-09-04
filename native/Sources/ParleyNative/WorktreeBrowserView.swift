import ParleyCore
import SwiftUI

struct WorktreeBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPath: String?

    private var selectedWorktree: GitWorktreeRecord? {
        guard let selectedPath else { return nil }
        return model.discoveredWorktreeRepository?.worktrees.first { $0.path == selectedPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 660, height: 480)
        .onChange(of: model.discoveredWorktreeRepository) { _, repository in
            guard let repository else { return }
            selectedPath = repository.worktrees.first(where: { $0.path == model.activeWorktreePath })?.path
                ?? repository.worktrees.first(where: model.canOpenDiscoveredWorktree)?.path
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Open Existing Worktree as Workspace")
                .font(.system(size: 16, weight: .semibold))
            Text("Read-only discovery from Git. Opening a worktree creates or focuses an ordinary Parley workspace; it does not change branches or Git state.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    @ViewBuilder
    private var content: some View {
        if model.worktreeDiscoveryLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading Git worktrees…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.worktreeDiscoveryError {
            ContentUnavailableView {
                Label("No Worktrees Found", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text(error)
            } actions: {
                Button("Choose an Ordinary Folder…") {
                    model.worktreeBrowserPresented = false
                    model.openWorkspacePicker()
                }
            }
        } else if let repository = model.discoveredWorktreeRepository {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(repository.primaryPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                List(repository.worktrees) { worktree in
                    Button {
                        selectedPath = worktree.path
                    } label: {
                        WorktreeRow(
                            worktree: worktree,
                            selected: selectedPath == worktree.path,
                            openable: model.canOpenDiscoveredWorktree(worktree)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canOpenDiscoveredWorktree(worktree))
                    .accessibilityLabel("\(worktree.shortIdentity), \(worktree.locationKind)")
                    .accessibilityValue(worktree.path)
                }
                .listStyle(.inset)
            }
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack {
            Text("Ordinary folders and shared worktrees remain supported.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.worktreeBrowserPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Open Workspace") {
                if let selectedWorktree { model.openDiscoveredWorktree(selectedWorktree) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedWorktree.map(model.canOpenDiscoveredWorktree) != true)
        }
        .padding(14)
    }
}

private struct WorktreeRow: View {
    let worktree: GitWorktreeRecord
    let selected: Bool
    let openable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(worktree.shortIdentity)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(worktree.locationKind.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if worktree.lockReason != nil {
                        stateChip("LOCKED", color: .orange)
                    }
                    if worktree.pruneReason != nil || !openable {
                        stateChip("UNAVAILABLE", color: .red)
                    }
                }
                Text(worktree.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let lockReason = worktree.lockReason, !lockReason.isEmpty {
                    Text(lockReason)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                if let pruneReason = worktree.pruneReason, !pruneReason.isEmpty {
                    Text(pruneReason)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
        .opacity(openable ? 1 : 0.58)
    }

    private func stateChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
    }
}
