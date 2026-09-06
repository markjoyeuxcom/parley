import ParleyCore
import SwiftUI

struct WorktreeBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPath: String?
    @State private var creating = false
    @State private var newBranch = ""
    @State private var newBase = "HEAD"
    @State private var createPreview: ManagedWorktreeService.CreatePreview?
    @State private var createError: String?
    @State private var busy = false

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
            managedSection
            Divider()
            footer
        }
        .frame(width: 700, height: 640)
        .onAppear { model.scheduleManagedWorktreeFactsRefresh(force: true, scope: .all) }
        .onChange(of: model.discoveredWorktreeRepository) { _, repository in
            createPreview = nil
            createError = nil
            guard let repository else { return }
            selectedPath = repository.worktrees.first(where: { $0.path == model.activeWorktreePath })?.path
                ?? repository.worktrees.first(where: model.canOpenDiscoveredWorktree)?.path
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Git Worktrees")
                .font(.system(size: 16, weight: .semibold))
            Text("The list is read-only discovery from Git; opening a worktree creates or focuses an ordinary Parley workspace without changing Git state. Below it, New Worktree and Remove are explicit actions that each show exactly what one fixed Git command will do before you confirm.")
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

    /// Worktrees Parley created or bound to a team, with the recorded base
    /// beside the last background reading. Creation and removal are explicit
    /// person actions with a concrete preview; nothing here is automatic.
    private var managedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Managed by Parley").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let mutation = model.managedWorktreeMutation {
                    Text("\(mutation.kind.rawValue) in progress…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button(creating ? "Cancel New Worktree" : "New Worktree…") {
                    creating.toggle()
                    createPreview = nil
                    createError = nil
                }.controlSize(.small).disabled(model.discoveredWorktreeRepository == nil || busy)
            }
            if creating, let repository = model.discoveredWorktreeRepository {
                HStack {
                    TextField("New branch (e.g. feat/parser)", text: $newBranch).textFieldStyle(.roundedBorder)
                        .onChange(of: newBranch) { _, _ in createPreview = nil; createError = nil }
                    TextField("Base ref", text: $newBase).textFieldStyle(.roundedBorder).frame(width: 140)
                        .onChange(of: newBase) { _, _ in createPreview = nil; createError = nil }
                    Button("Preview") {
                        let branch = newBranch.trimmingCharacters(in: .whitespaces)
                        let base = newBase.trimmingCharacters(in: .whitespaces)
                        let repositoryPath = repository.primaryPath
                        busy = true
                        createPreview = nil
                        createError = nil
                        Task { @MainActor in
                            defer { busy = false }
                            let result = await model.previewManagedWorktree(repositoryFolder: repositoryPath, branch: branch, baseRef: base)
                            guard branch == newBranch.trimmingCharacters(in: .whitespaces), base == newBase.trimmingCharacters(in: .whitespaces),
                                  model.discoveredWorktreeRepository?.primaryPath == repositoryPath else { return }
                            switch result {
                            case let .success(preview): createPreview = preview
                            case let .failure(error): createError = error.localizedDescription
                            }
                        }
                    }.controlSize(.small).disabled(busy || newBranch.trimmingCharacters(in: .whitespaces).isEmpty || newBase.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let preview = createPreview {
                        Button("Create \(preview.branch)") {
                            busy = true
                            createError = nil
                            Task { @MainActor in
                                defer { busy = false }
                                do {
                                    _ = try await model.createManagedWorktree(preview: preview, repositoryFolder: repository.primaryPath)
                                    creating = false
                                    createPreview = nil
                                    model.showWorktreeBrowser(sourceFolder: repository.primaryPath)
                                } catch { createError = error.localizedDescription }
                            }
                        }.controlSize(.small).buttonStyle(.borderedProminent).disabled(busy)
                    }
                }
                if let preview = createPreview {
                    Text("git worktree add -b \(preview.branch) \(preview.path) \(preview.baseCommit.prefix(12)) · base \(preview.baseRef) = \(preview.baseCommit.prefix(12)); refused if it moves.")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Text(ManagedWorktreeService.CreatePreview.executionNotice).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let createError { Text(createError).font(.system(size: 10)).foregroundStyle(.red).textSelection(.enabled) }
            }
            if model.managedWorktrees.isEmpty {
                Text("None yet. Team Session approval can create or select one; recorded base and ownership appear here.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.managedWorktrees) { record in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    Text(model.managedWorktreeSummary(record)).font(.system(size: 10)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let warning = record.warning { Text(warning).font(.system(size: 10)).foregroundStyle(.orange) }
                                }
                                Spacer(minLength: 4)
                                Button("Open") { model.openManagedWorktree(record) }.controlSize(.small)
                                if record.parleyCreated {
                                    Button("Remove…") { model.removeManagedWorktree(record) }.controlSize(.small)
                                        .disabled(model.managedWorktreeMutation != nil)
                                        .help("Refuses nested worktrees, live panes, modified or untracked files, commits ahead of the upstream's local tracking state (or, without an upstream, not contained in the primary), locks and anything Git cannot answer; never uses --force and never deletes the branch.")
                                } else {
                                    Text("person-owned").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
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
