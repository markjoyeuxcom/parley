import ParleyCore
import SwiftUI

private struct PinnedSnippetEditorDraft: Identifiable {
    let id = UUID()
    let snippetID: String?
    let title: String
    let text: String

    init(_ snippet: PinnedContextSnippet? = nil) {
        snippetID = snippet?.id
        title = snippet?.title ?? ""
        text = snippet?.text ?? ""
    }
}

struct PinnedContextSnippetLibraryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var editorDraft: PinnedSnippetEditorDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notice
            Divider()
            HSplitView {
                snippetList
                    .frame(minWidth: 280, idealWidth: 330)
                preview
                    .frame(minWidth: 480)
            }
            Divider()
            footer
        }
        .frame(minWidth: 830, idealWidth: 940, minHeight: 600, idealHeight: 700)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: snippetIDs) { _, _ in selectFirstIfNeeded() }
        .sheet(item: $editorDraft) { draft in
            PinnedContextSnippetEditorView(model: model, draft: draft)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Pinned Snippets", systemImage: "pin")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(model.pinnedContextSnippets.count) of \(PinnedContextSnippetStore.maximumSnippets)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("NEVER ATTACHED AUTOMATICALLY")
                    .font(.caption.monospaced().weight(.semibold))
                Text("Pinned snippets are reusable across workspaces, but they reach an agent only when you add them to an editable Context Pack preview. Do not store credentials, tokens or other secrets here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.055))
    }

    @ViewBuilder
    private var snippetList: some View {
        if model.pinnedContextSnippets.isEmpty {
            ContentUnavailableView(
                "No Pinned Snippets",
                systemImage: "pin",
                description: Text("Create reusable architecture notes, test instructions or review criteria.")
            )
            .padding()
        } else {
            List(model.pinnedContextSnippets, selection: $selectedID) { snippet in
                VStack(alignment: .leading, spacing: 3) {
                    Text(snippet.title)
                        .lineLimit(1)
                    Text("\(snippet.text.utf8.count.formatted()) bytes · saved \(snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(snippet.id)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let selectedSnippet {
            VStack(alignment: .leading, spacing: 10) {
                Text(selectedSnippet.title)
                    .font(.headline)
                Text("Reusable local source · \(selectedSnippet.text.utf8.count.formatted()) UTF-8 bytes")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(selectedSnippet.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.secondary.opacity(0.055))
                .overlay {
                    Rectangle().stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView("Select a Snippet", systemImage: "pin")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("New…") { editorDraft = PinnedSnippetEditorDraft() }
                .disabled(model.pinnedContextSnippets.count >= PinnedContextSnippetStore.maximumSnippets)
            Button("Edit…") {
                guard let selectedSnippet else { return }
                editorDraft = PinnedSnippetEditorDraft(selectedSnippet)
            }
            .disabled(selectedSnippet == nil)
            Button("Delete…", role: .destructive) {
                guard let selectedSnippet else { return }
                model.deletePinnedContextSnippet(selectedSnippet)
            }
            .disabled(selectedSnippet == nil)
            Spacer()
            Text("Managing this library does not contact any agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private var snippetIDs: [String] { model.pinnedContextSnippets.map(\.id) }

    private var selectedSnippet: PinnedContextSnippet? {
        model.pinnedContextSnippets.first(where: { $0.id == selectedID })
    }

    private func selectFirstIfNeeded() {
        if let selectedID, snippetIDs.contains(selectedID) { return }
        selectedID = snippetIDs.first
    }
}

private struct PinnedContextSnippetEditorView: View {
    @ObservedObject var model: AppModel
    let draft: PinnedSnippetEditorDraft
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String

    init(model: AppModel, draft: PinnedSnippetEditorDraft) {
        self.model = model
        self.draft = draft
        _title = State(initialValue: draft.title)
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(draft.snippetID == nil ? "New Pinned Snippet" : "Edit Pinned Snippet")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(draft.snippetID == nil ? "NEW" : "SAVED LOCAL REFERENCE")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("NAME")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(normalizedTitle.utf8.count) of \(PinnedContextSnippetStore.maximumTitleBytes) bytes")
                            .font(.caption.monospaced())
                            .foregroundStyle(titleTooLarge ? Color.red : Color.secondary)
                    }
                    TextField("For example: Definition of done", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("REUSABLE CONTEXT")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(normalizedText.utf8.count.formatted()) of \(PinnedContextSnippetStore.maximumContentBytes.formatted()) bytes")
                            .font(.caption.monospaced())
                            .foregroundStyle(textTooLarge ? Color.red : Color.secondary)
                    }
                    Text("Write architecture notes, test instructions or review criteria. Every insertion remains editable before sending.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 300)
                        .border(Color.secondary.opacity(0.25))
                }
            }
            .padding(18)
            Divider()
            HStack {
                Text("Saving does not contact any agent. Do not store credentials or secrets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Snippet") {
                    if model.savePinnedContextSnippet(id: draft.snippetID, title: title, text: text) != nil {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isSaveable)
            }
            .padding(18)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 530, idealHeight: 620)
    }

    private var normalizedTitle: String {
        ContextPackText.normalize(title).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedText: String { ContextPackText.normalize(text) }
    private var titleTooLarge: Bool { normalizedTitle.utf8.count > PinnedContextSnippetStore.maximumTitleBytes }
    private var textTooLarge: Bool { normalizedText.utf8.count > PinnedContextSnippetStore.maximumContentBytes }
    private var isSaveable: Bool {
        !normalizedTitle.isEmpty
            && !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !titleTooLarge
            && !textTooLarge
    }
}

struct PinnedContextSnippetPickerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Add Pinned Snippets", systemImage: "pin")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(selectedIDs.count) selected")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            if model.availablePinnedContextSnippets.isEmpty {
                ContentUnavailableView(
                    "No Available Snippets",
                    systemImage: "pin",
                    description: Text(model.pinnedContextSnippets.isEmpty ? "Create snippets from Context → Manage Pinned Snippets." : "Every saved snippet is already attached to this pack.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.availablePinnedContextSnippets) { snippet in
                    Button {
                        if selectedIDs.contains(snippet.id) {
                            selectedIDs.remove(snippet.id)
                        } else {
                            selectedIDs.insert(snippet.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedIDs.contains(snippet.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedIDs.contains(snippet.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snippet.title)
                                    .foregroundStyle(.primary)
                                Text(snippet.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                Text("\(snippet.text.utf8.count.formatted()) bytes · saved \(snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Text("Each selection becomes a separately attributed editable snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected") {
                    let orderedIDs = model.availablePinnedContextSnippets
                        .map(\.id)
                        .filter(selectedIDs.contains)
                    model.addPinnedContextSnippets(ids: orderedIDs)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(18)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 620)
        .onChange(of: availableIDs) { _, ids in selectedIDs.formIntersection(ids) }
    }

    private var availableIDs: Set<String> { Set(model.availablePinnedContextSnippets.map(\.id)) }
}
