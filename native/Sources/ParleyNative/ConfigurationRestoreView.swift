import ParleyCore
import SwiftUI

/// The preview a configuration restore shows before anything changes: what
/// the archive holds, which workspaces it replaces, which folders this Mac
/// lacks, which stores the export left out, and why Replace is not yet
/// available. Cancel is the default; Replace is the person's explicit choice.
struct ConfigurationRestoreView: View {
    @ObservedObject var model: AppModel
    let proposal: AppModel.ConfigurationRestoreProposal

    private var preview: ConfigurationRestorePreview { proposal.preview }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace this runtime's configuration?")
                .font(.title3.weight(.semibold))
            // The facts scroll; the buttons stay in reach however long the
            // lists get (128 profile lines were reproduced in review).
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
            Text("From \(proposal.sourceName), exported \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened)) by Parley \(preview.appVersion). Everything below replaces what this \(model.runtime.mode.label) runtime has now; nothing is merged.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                column("Replaces", preview.currentWorkspaceNames, empty: "No workspaces")
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 22)
                column("With", preview.incomingWorkspaceNames, empty: "No workspaces")
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Pane templates"); Text(preview.paneCount.formatted()).monospacedDigit() }
                GridRow { Text("Groups"); Text(preview.groupCount.formatted()).monospacedDigit() }
                GridRow { Text("Saved layouts"); Text(preview.savedLayoutCount.formatted()).monospacedDigit() }
                GridRow { Text("Custom permission profiles"); Text(preview.customProfileCount.formatted()).monospacedDigit() }
                GridRow { Text("Recipes with edited text"); Text(preview.customizedRecipeCount.formatted()).monospacedDigit() }
                GridRow { Text("Favourite folders"); Text(preview.favouriteCount.formatted()).monospacedDigit() }
                GridRow { Text("Worktree repositories"); Text(preview.worktreeRepositoryCount.formatted()).monospacedDigit() }
            }
            .font(.callout)

            if !preview.missingFolders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(preview.missingFolders.count) folder\(preview.missingFolders.count == 1 ? " is" : "s are") not on this Mac", systemImage: "folder.badge.questionmark")
                        .font(.callout.weight(.medium))
                    Text("They are restored as written and shown as MISSING; a pane in one cannot start until you choose its folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(preview.missingFolders, id: \.self) { folder in
                                Text(folder).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
            }

            if !preview.settingChanges.isEmpty || !preview.profileChanges.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Settings that change", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                    ForEach(preview.settingChanges + preview.profileChanges, id: \.self) { line in
                        Text("• \(line)").font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Workspace automation after the restore: \(preview.automationSummary.isEmpty ? "none" : preview.automationSummary). Agents start only through their launch review; a profile choice here is remembered, never granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if preview.containerTemplateCount > 0 {
                Label("\(preview.containerTemplateCount) pane template\(preview.containerTemplateCount == 1 ? "" : "s") ran in a container. Images, daemons and mounts are never in an archive: each comes back as a host template until its launch review chooses In a container again.", systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.omittedStores.isEmpty {
                Label("Left out of the export because they could not be read then: \(preview.omittedStores.map(\.title).joined(separator: ", ")). Those stores are left as they are on this Mac.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let change = preview.retentionChange {
                Text("History retention changes from \(change.from) to \(change.to) records. A lower limit prunes history, so Parley asks about that separately after the restore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !preview.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Replace needs a quiet Parley", systemImage: "pause.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.red)
                    ForEach(preview.blockers, id: \.self) { blocker in
                        Text("• \(blocker)").font(.caption)
                    }
                    Text("Stop or finish these, then choose Restore Configuration… again. Parley never stops anything because Restore was chosen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Every restored pane is stopped: start each from its menu, agents through their launch review. Credentials, history, context, container ids, grants and the session-only switches are not in the file and are not touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)

            HStack {
                Spacer()
                Button("Cancel") { model.cancelConfigurationRestore() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace") { model.applyConfigurationRestore() }
                    .disabled(!preview.canApply)
                    .help(preview.canApply ? "Replace this runtime's configuration with the archive" : "Finish the live work listed above first")
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 760)
    }

    private func column(_ title: String, _ names: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(names.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if names.isEmpty {
                        Text(empty).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.callout).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 140)
        }
        .frame(maxWidth: .infinity)
    }
}
