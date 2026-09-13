import AppKit
import ParleyCore
import SwiftUI

/// The Worktrees window: every repository Parley knows on the left, the
/// selected repository's registered worktrees on the right as board rows.
/// Git's registry is the list; Parley's records annotate it. It opens with
/// no pane or workspace, reads only while on screen, and every action is
/// the same previewed, refused-or-confirmed step it is elsewhere.
struct WorktreeManagerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.auxiliaryWindowActive) private var windowActive
    @State private var lifecycleID: String?
    @State private var creating = false
    @State private var newBranch = ""
    @State private var newBase = "HEAD"
    @State private var createPreview: ManagedWorktreeService.CreatePreview?
    @State private var createError: String?
    @State private var busy = false

    private var selected: WorktreeRepositoryEntry? { model.selectedWorktreeRepository }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            repositories.frame(width: 270)
            Divider()
            trees.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { model.setWorktreeManagerMounted(true) }
        .onDisappear { model.setWorktreeManagerMounted(false) }
        .onChange(of: windowActive) { _, active in if active { model.refreshWorktreeManagerFacts() } }
        .onChange(of: model.worktreeManagerSelection) { _, _ in creating = false; createPreview = nil; createError = nil }
        .sheet(isPresented: Binding(get: { lifecycleID != nil }, set: { if !$0 { lifecycleID = nil } })) {
            VStack(alignment: .leading, spacing: 0) {
                WorktreeLifecycleView(model: model, selectedID: $lifecycleID)
                Divider()
                HStack { Spacer(); Button("Done") { lifecycleID = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .frame(width: 940, height: 700)
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repositories").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 14)
            if model.worktreeRepositories.isEmpty {
                Text("No repositories yet. Parley lists the repositories of its panes, attached, favourite and recent folders, and any you add here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.worktreeRepositories) { entry in
                            Button { model.selectWorktreeRepository(entry.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        if entry.isMissing { Text("MISSING").font(.system(size: 9, weight: .semibold)).foregroundStyle(.red) }
                                        Spacer(minLength: 4)
                                        Text(entry.isMissing ? "" : "\(entry.linkedCount)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    Text(entry.primaryPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Text(entry.isMissing ? "folder not found" : (entry.staleCount > 0 ? "\(entry.staleCount) stale" : entry.sources.map(\.label).sorted().joined(separator: ", ")))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 5).fill(entry.id == model.worktreeManagerSelection ? Color.accentColor.opacity(0.14) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Repository \(entry.name)")
                            .accessibilityValue(entry.isMissing ? "missing" : "\(entry.linkedCount) linked worktrees")
                        }
                    }.padding(.horizontal, 6)
                }
            }
            Divider()
            HStack {
                Button("Add Repository…") { model.addWorktreeRepository() }.controlSize(.small)
                Spacer()
                if let selected, selected.canForget {
                    Button("Forget") { model.forgetWorktreeRepository(selected) }.controlSize(.small)
                        .help("Removes this repository from the list. Nothing on disk changes.")
                }
            }.padding(12)
        }
    }

    @ViewBuilder
    private var trees: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(entry.name).font(.system(size: 16, weight: .semibold))
                            if let primary = entry.primary {
                                Text("\(primary.shortIdentity) \(primary.head.prefix(8))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Text(entry.isMissing ? "folder not found" : "\(entry.linkedCount) linked worktree\(entry.linkedCount == 1 ? "" : "s")" + (entry.staleCount > 0 ? " · \(entry.staleCount) stale" : ""))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if model.worktreeManagerReading { ProgressView().controlSize(.mini) }
                        }
                        Text(entry.primaryPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Refresh") { model.refreshWorktreeRepositories() }.controlSize(.small).disabled(busy)
                    if entry.staleCount > 0 {
                        Button("Prune stale…") { model.pruneWorktrees(in: entry) }.controlSize(.small)
                            .disabled(busy || model.managedWorktreeMutation != nil)
                            .help("Git forgets every registration whose folder is gone. The preview lists them all; no folder or branch changes.")
                    }
                    Button(creating ? "Cancel New Worktree" : "New Worktree…") { creating.toggle(); createPreview = nil; createError = nil }
                        .controlSize(.small).disabled(entry.isMissing || busy)
                }
                .padding(.horizontal, 18).padding(.top, 14)
                if creating { createForm(for: entry).padding(.horizontal, 18) }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if entry.isMissing {
                            Text("This folder no longer exists or is not a Git repository. Forget it to remove it from the list; nothing on disk changes.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(entry.worktrees.sorted { $0.isPrimary && !$1.isPrimary }) { tree in
                            treeRow(tree, in: entry)
                            Divider()
                        }
                        if !entry.isMissing, entry.linked.isEmpty {
                            Text("No linked worktrees. New Worktree… creates one on a new branch from a base you preview.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(18)
                }
                Divider()
                HStack(alignment: .center) {
                    Text("Git's registry is the list; Parley's records add base, team and requester. Facts are read while this window is on screen and never stored.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove integrated…") { model.removeIntegratedWorktrees(in: entry) }.controlSize(.small)
                        .disabled(entry.isMissing || busy || model.managedWorktreeMutation != nil || !entry.linked.contains { model.worktreeManagerRow(for: $0).state == .integrated })
                        .help("One preview over every INTEGRATED tree of this repository, built from fresh checks; trees with a refusal are listed and skipped. Removes the passing ones one git worktree remove at a time, without --force, stopping at the first outcome that is not a confirmed removal. Branches are offered separately afterwards.")
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
        } else {
            VStack(spacing: 8) {
                Text("Select a repository").font(.system(size: 13, weight: .medium))
                Text("Or add one; no pane needs to be open.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func treeRow(_ tree: GitWorktreeRecord, in entry: WorktreeRepositoryEntry) -> some View {
        let row = model.worktreeManagerRow(for: tree)
        let mutating = model.managedWorktreeMutation != nil
        HStack(alignment: .top, spacing: 8) {
            if tree.isPrimary {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(tree.shortIdentity).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text("PRIMARY").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Text("never removed here").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(tree.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(tree.shortIdentity), primary worktree")
            } else {
                WorktreeBoardRowView(row: row)
            }
            Spacer(minLength: 4)
            if row.state == .stale {
                Button("Prune…") { model.pruneWorktrees(in: entry) }.controlSize(.small).disabled(mutating)
                    .help("Git forgets every registration whose folder is gone, this one included. The preview lists them all; no folder changes. Git still counts a stale entry's branch as checked out, so the branch step is offered after the prune.")
            } else {
                Button("Open") { model.openWorktreeFromManager(tree) }.controlSize(.small)
                    .disabled(!model.canOpenDiscoveredWorktree(tree))
                if !tree.isPrimary {
                    Button("Integrate…") { model.integrateWorktreeFromManager(tree, in: entry) }.controlSize(.small)
                        .disabled(!row.canIntegrate || tree.branch == nil || mutating)
                        .help("Propose git merge --no-ff of this branch into the primary checkout as a reviewed command run you approve; Parley runs no merge itself.")
                    Button("Finish…") {
                        Task { @MainActor in
                            do { lifecycleID = try await model.ensureWorktreeRecord(for: tree, in: entry).id }
                            catch { NSAlert(error: error).runModal() }
                        }
                    }.controlSize(.small).disabled(mutating)
                    Button("Remove…") { model.removeWorktreeFromManager(tree, in: entry) }.controlSize(.small).disabled(mutating)
                        .help("The same preview and refusals everywhere: never --force, the branch is kept. A tree Parley did not create is identified by Git's registry entry at its path; a record is written for it on the way in.")
                }
            }
        }
    }

    private func createForm(for entry: WorktreeRepositoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("New branch (e.g. feat/parser)", text: $newBranch).textFieldStyle(.roundedBorder)
                    .onChange(of: newBranch) { _, _ in createPreview = nil; createError = nil }
                TextField("Base ref", text: $newBase).textFieldStyle(.roundedBorder).frame(width: 140)
                    .onChange(of: newBase) { _, _ in createPreview = nil; createError = nil }
                Button("Preview") {
                    let branch = newBranch.trimmingCharacters(in: .whitespaces)
                    let base = newBase.trimmingCharacters(in: .whitespaces)
                    let repositoryPath = entry.primaryPath
                    busy = true; createPreview = nil; createError = nil
                    Task { @MainActor in
                        defer { busy = false }
                        let result = await model.previewManagedWorktree(repositoryFolder: repositoryPath, branch: branch, baseRef: base)
                        guard branch == newBranch.trimmingCharacters(in: .whitespaces), base == newBase.trimmingCharacters(in: .whitespaces),
                              model.worktreeManagerSelection == repositoryPath else { return }
                        switch result {
                        case let .success(preview): createPreview = preview
                        case let .failure(error): createError = error.localizedDescription
                        }
                    }
                }.controlSize(.small).disabled(busy || newBranch.trimmingCharacters(in: .whitespaces).isEmpty || newBase.trimmingCharacters(in: .whitespaces).isEmpty)
                if let preview = createPreview {
                    Button("Create \(preview.branch)") {
                        busy = true; createError = nil
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                _ = try await model.createManagedWorktree(preview: preview, repositoryFolder: entry.primaryPath)
                                creating = false; createPreview = nil
                                model.refreshWorktreeRepositories()
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
    }
}

/// One board row: branch and state, who owns it, then the facts line. Every
/// value comes from `WorktreeBoardRow`, which the model derives from the
/// record, the last background Git read, the panes inside and the team.
struct WorktreeBoardRowView: View {
    let row: WorktreeBoardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text(row.branch).font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(row.state.label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(stateColor)
                Text(row.ownerLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Text("·").foregroundStyle(.secondary)
                Text(row.panesLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(row.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(row.factsLine).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning = row.warning { Text(warning).font(.system(size: 10)).foregroundStyle(.orange) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.branch), \(row.state.label), \(row.ownerLabel)")
        .accessibilityValue(row.factsLine)
    }

    private var stateColor: Color {
        switch row.state {
        case .inUse: .accentColor
        case .integrated: .green
        case .idle, .unread: .secondary
        case .missing, .stale: .red
        case .unknown: .orange
        }
    }
}
