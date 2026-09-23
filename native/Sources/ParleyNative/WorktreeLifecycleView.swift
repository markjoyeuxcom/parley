import AppKit
import ParleyCore
import SwiftUI

/// On-demand inspection only: no timer, process sampling or directory traversal
/// is attached to the workbench refresh tick.
struct WorktreeLifecycleView: View {
    @ObservedObject var model: AppModel
    @Binding var selectedID: String?
    @State private var inactiveOnly = false
    @State private var inspections: [String: WorktreeLifecycleInspection] = [:]
    @State private var failures: [String: String] = [:]
    @State private var rememberedScopes: [String: [WorktreeWorkspaceUse]] = [:]
    @State private var sizes: [String: WorktreeDiskUsage] = [:]
    @State private var refreshID = UUID()
    @State private var loading = false
    @State private var busy = false
    @State private var targetRef = ""
    @State private var merge: WorktreeMergePreview?
    @State private var message: String?
    @State private var vendor: PaneKind = .codex

    private var selected: ManagedWorktreeRecord? { model.managedWorktrees.first { $0.id == selectedID } }
    private var records: [ManagedWorktreeRecord] {
        model.managedWorktrees.filter { !inactiveOnly || inspections[$0.id]?.usage.isInactive == true }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Inactive only", isOn: $inactiveOnly).toggleStyle(.checkbox)
                Text("No panes in either Parley runtime and no active team here. Other apps may still use these folders.")
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView("Reading worktrees…").controlSize(.small) }
                List(records) { record in
                    Button {
                        selectedID = record.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.branch).fontWeight(selectedID == record.id ? .semibold : .regular)
                            Text(DelegationGitFacts.displayPath(record.path)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            if let reading = inspections[record.id] {
                                Text(reading.usage.isInactive ? "Inactive in Parley" : "In use or usage unknown")
                                    .font(.caption)
                                if let date = reading.usage.lastRetainedActivity {
                                    Text("Last retained handoff: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
                                } else {
                                    Text("Last handoff activity: not recorded").font(.caption2)
                                }
                                Text(reading.cleanup.refusals.isEmpty ? "Removal preview available" : "\(reading.cleanup.refusals.count) removal blockers")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else { Text("Usage unknown").font(.caption).foregroundStyle(.secondary) }
                            if let size = sizes[record.id] { Text(sizeLabel(size)).font(.caption2) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
                Button("Refresh") { refreshID = UUID() }.disabled(loading || busy)
                Text("Size is measured on request. Activity is limited to retained delegation snapshots, not terminal output or filesystem edits.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(14).frame(width: 260)
            Divider()
            ScrollView {
                if let record = selected {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Finish \(record.branch)").font(.headline)
                        Text(DelegationGitFacts.displayPath(record.path)).font(.caption).textSelection(.enabled)
                        Text("Each step is optional and separately confirmed. Closing panes, clearing records and removing the checkout are independent actions.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reading = inspections[record.id] {
                            Text("Read \(reading.capturedAt.formatted(date: .abbreviated, time: .shortened)). Refresh after external changes.")
                                .font(.caption2).foregroundStyle(.secondary)
                            remainingWork(record, reading)
                            finishPanes(record, reading)
                            clearRecords(record, reading)
                            removal(record, reading)
                            recovery(record, reading)
                        } else {
                            Text(failures[record.id] ?? "Reading this worktree…").foregroundStyle(.secondary)
                        }
                        mergePreview(record)
                        permissionGuidance(record)
                        if let message { Text(message).font(.caption).textSelection(.enabled) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(records.isEmpty ? "No matching recorded worktrees. The Worktrees window lists every registered tree and records one when you use Finish… or Remove…, or create one there." : "Select a worktree to inspect or finish.")
                        .foregroundStyle(.secondary).padding(24)
                }
            }
        }
        .task(id: refreshID) { await refresh() }
        .onChange(of: selectedID) { _, _ in merge = nil; targetRef = ""; message = nil }
        .onChange(of: model.managedWorktrees) { _, _ in refreshID = UUID() }
    }

    private func refresh() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        model.refreshStatusCenterQuietly()
        let records = model.managedWorktrees
        inspections = [:]; failures = [:]; merge = nil
        for record in records {
            guard !Task.isCancelled else { return }
            do {
                let result = try await model.inspectWorktreeLifecycle(record)
                guard !Task.isCancelled, model.managedWorktrees.contains(record) else { return }
                inspections[record.id] = result
                var scopes = rememberedScopes[record.id] ?? []
                for scope in result.usage.workspaces {
                    scopes.removeAll { $0.id == scope.id }; scopes.append(scope)
                }
                rememberedScopes[record.id] = scopes
            } catch {
                guard !Task.isCancelled else { return }
                failures[record.id] = error.localizedDescription
            }
        }
        if selected == nil { selectedID = self.records.first?.id }
    }

    private func remainingWork(_ record: ManagedWorktreeRecord, _ reading: WorktreeLifecycleInspection) -> some View {
        GroupBox("1. Review remaining work") {
            VStack(alignment: .leading, spacing: 6) {
                let facts = reading.cleanup.facts
                Text("Modified: \(facts.modifiedPaths.count) · Untracked: \(facts.untrackedPaths.count) · Ignored entries: \(facts.ignoredPaths.count)\(facts.ignoredListTruncated ? "+" : "")")
                if facts.statusUncertain { Text("Git status or upstream could not be fully read. This is not a clean-state verdict.").foregroundStyle(.orange) }
                if facts.hasUpstream {
                    Text("\(facts.upstreamAheadCount) commits ahead of local upstream tracking state. Remote not contacted.")
                } else { Text(facts.mergedIntoPrimary ? "HEAD is contained in the primary checkout's HEAD." : "No upstream preservation evidence; inspect and preserve your commits before removal.") }
                DisclosureGroup("Changed paths") {
                    ForEach(Array((facts.modifiedPaths + facts.untrackedPaths).prefix(200).enumerated()), id: \.offset) { _, path in
                        Text(DelegationGitFacts.displayPath(path)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Button("Measure folder size") {
                    busy = true
                    Task { @MainActor in
                        let value = await Task.detached(priority: .utility) { WorktreeDiskUsage.measure(path: record.path) }.value
                        sizes[record.id] = value; busy = false
                    }
                }.disabled(busy)
                if let size = sizes[record.id] {
                    Text(sizeLabel(size))
                    Text(size.detail).foregroundStyle(.secondary)
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func finishPanes(_ record: ManagedWorktreeRecord, _ reading: WorktreeLifecycleInspection) -> some View {
        GroupBox("2. Close panes or their workspace") {
            VStack(alignment: .leading, spacing: 8) {
                if reading.usage.paneIDs.isEmpty { Text("No panes in this runtime use the folder in this reading.") }
                ForEach(reading.usage.workspaces) { scope in
                    if let workspace = model.workspaces.first(where: { $0.workspaceID == scope.id }), scope.canCloseWholeWorkspace {
                        Button("Close workspace \(scope.name)…") {
                            model.close(workspace, onlyInsideWorktree: record.path); refreshID = UUID()
                        }.disabled(busy || loading)
                    } else {
                        ForEach(scope.paneIDs, id: \.self) { id in
                            if let pane = model.panes.first(where: { $0.id == id }) {
                                Button("Close pane \(pane.displayName)…") {
                                    model.close(pane, onlyInsideWorktree: record.path); refreshID = UUID()
                                }.disabled(busy || loading)
                            }
                        }
                    }
                }
                if reading.usage.otherPaneCount > 0 { Text("\(reading.usage.otherPaneCount) panes in the other runtime also use this tree. Close or move them there.").foregroundStyle(.orange) }
                if reading.usage.otherRuntimeUnknown { Text("Other runtime usage is unknown; removal remains blocked.").foregroundStyle(.orange) }
                if reading.usage.hasActiveTeam { Text("An active team is bound here. Choose Stop session in Team Sessions before cleanup.").foregroundStyle(.orange) }
                Text("Closing ends those processes; it leaves history and Git files in place. Mixed workspaces offer individual panes.").foregroundStyle(.secondary)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func clearRecords(_ record: ManagedWorktreeRecord, _ reading: WorktreeLifecycleInspection) -> some View {
        GroupBox("3. Optionally clear coordination records") {
            VStack(alignment: .leading, spacing: 6) {
                Text("These actions clear the named workspace's finished history, results and saved context, including work in other folders. Active work and original project files remain.")
                    .foregroundStyle(.secondary)
                let scopes = rememberedScopes[record.id] ?? reading.usage.workspaces
                if scopes.isEmpty { Text("No workspace association is retained. Use Status Center to choose a history scope.") }
                ForEach(scopes) { scope in
                    Button("Clear history for \(scope.name)…") {
                        message = model.clearStatusHistory(workspaceID: scope.id, workspaceName: scope.name)
                        refreshID = UUID()
                    }.disabled(busy || loading)
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func removal(_ record: ManagedWorktreeRecord, _ reading: WorktreeLifecycleInspection) -> some View {
        GroupBox("4. Preview checkout removal") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(reading.cleanup.refusals.enumerated()), id: \.offset) { _, reason in
                    Text("• \(reason)").foregroundStyle(.secondary)
                }
                Text("Removal rechecks current facts and separately confirms ignored files. The Git branch is kept.")
                if !record.parleyCreated {
                    Text("Parley did not create this tree. Its identity for removal is Git's registry entry at the recorded path; the same refusals apply and the branch is kept.")
                        .foregroundStyle(.secondary)
                }
                Button(reading.cleanup.decision == .clearRecordOnly ? "Clear absent worktree record…" : "Preview removal…") {
                    model.removeManagedWorktree(record)
                }.disabled(busy || loading || model.managedWorktreeMutation != nil || reading.usage.hasActiveTeam)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recovery(_ record: ManagedWorktreeRecord, _ reading: WorktreeLifecycleInspection) -> some View {
        GroupBox("Recover or inspect") {
            VStack(alignment: .leading, spacing: 6) {
                Text(reading.recoveryGuidance)
                if let error = reading.recoveryError { Text(error).foregroundStyle(.orange) }
                ForEach(reading.recoveryPaths, id: \.self) { path in
                    Text(DelegationGitFacts.displayPath(path)).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Update Recorded Path…") {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false; refreshID = UUID() }
                            do { try await model.recoverWorktreeRecord(record, to: path) }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(busy || loading || reading.recoveryPaths.count != 1)
                }
                Button("Reveal recorded location in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)])
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mergePreview(_ record: ManagedWorktreeRecord) -> some View {
        GroupBox("Merge-conflict preview") {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    TextField("Integration branch, tag or commit", text: $targetRef)
                        .textFieldStyle(.roundedBorder).onChange(of: targetRef) { _, _ in merge = nil }
                    Button("Preview") {
                        let target = targetRef.trimmingCharacters(in: .whitespaces)
                        let id = record.id
                        busy = true; merge = nil; message = nil
                        Task { @MainActor in
                            defer { busy = false }
                            do {
                                let result = try await model.previewWorktreeMerge(record, target: target)
                                guard selectedID == id, targetRef.trimmingCharacters(in: .whitespaces) == target,
                                      model.managedWorktrees.contains(record) else { return }
                                merge = result
                            } catch { if selectedID == id { message = error.localizedDescription } }
                        }
                    }.disabled(busy || targetRef.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let merge {
                    Text(merge.hasConflicts ? "Conflicts predicted" : "No conflicts predicted").fontWeight(.semibold)
                    Text("Into \(merge.targetCommit.prefix(12)) ← \(merge.sourceCommit.prefix(12)) · \(merge.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(Array(merge.conflictedPaths.enumerated()), id: \.offset) { _, path in
                        Text(DelegationGitFacts.displayPath(path)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if merge.hasConflicts && merge.conflictedPaths.isEmpty { Text("Git reported a conflict without individual file paths. Inspect it with Git.") }
                }
                Text(WorktreeMergePreview.limitation).foregroundStyle(.secondary)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionGuidance(_ record: ManagedWorktreeRecord) -> some View {
        GroupBox("Git permission guidance") {
            VStack(alignment: .leading, spacing: 7) {
                Text(WorktreePermissionGuide.explanation)
                Text("Shared Git directory: \(DelegationGitFacts.displayPath(record.commonDirectory))")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Picker("Pane", selection: $vendor) {
                    ForEach(PaneKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                }
                Text(WorktreePermissionGuide.guidance(for: vendor)).foregroundStyle(.secondary)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sizeLabel(_ size: WorktreeDiskUsage) -> String {
        "\(size.isComplete ? "" : "At least ")\(ByteCountFormatter.string(fromByteCount: size.logicalBytes, countStyle: .file)) · \(size.fileCount) files"
    }
}
