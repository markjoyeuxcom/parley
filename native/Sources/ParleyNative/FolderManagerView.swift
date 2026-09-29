import ParleyCore
import SwiftUI

/// The person's remembered folders in one place: favourites they bookmarked
/// and the automatic recent history, each with its full path, whether it
/// still exists, and a way to use it for new panes or remove it. Removal
/// here forgets a bookmark or a history entry; it never touches the folder.
struct FolderManagerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Manage Folders")
                    .font(.title2.weight(.semibold))
                Text("Favourites are folders you bookmarked; Recent is the history of folders used for new panes. Removing an entry forgets it here and changes nothing on disk. A folder marked Missing no longer exists at that path and is never offered for new panes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        title: "FAVOURITES",
                        folders: model.favouriteFolders,
                        empty: "No favourite folders. Add one from the New Pane Folder menu or the Favourites bar.",
                        remove: model.removeFavouriteFolder
                    )
                    section(
                        title: "RECENT",
                        folders: model.recentFolders,
                        empty: "No recent folders.",
                        remove: model.removeRecentFolder
                    )
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Add Favourite…") { model.addFavouriteFolder() }
                Button("Clear Recent") { model.clearRecentFolders() }
                    .disabled(model.recentFolders.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 380, idealHeight: 480)
    }

    private func section(
        title: String,
        folders: [String],
        empty: String,
        remove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if folders.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folders, id: \.self) { folder in
                        row(folder, remove: remove)
                        if folder != folders.last { Divider() }
                    }
                }
            }
        }
    }

    private func row(_ folder: String, remove: @escaping (String) -> Void) -> some View {
        let exists = model.folderIdentity.exists(folder)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(WorkspaceFolderIdentity.displayName(for: folder))
                        .fontWeight(.medium)
                    if !exists {
                        Text("MISSING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Use for New Panes") { model.setWorkspaceFolder(folder) }
                .disabled(!exists)
                .help(exists ? "Use \(folder) for new panes in the active workspace" : "This folder no longer exists at that path")
            Button("Remove") { remove(folder) }
                .help("Forget \(folder) here. Nothing on disk changes.")
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WorkspaceFolderIdentity.displayName(for: folder)), \(exists ? "present" : "missing")")
    }
}
