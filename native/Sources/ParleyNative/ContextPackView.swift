import ParleyCore
import SwiftUI

struct ContextPackView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPartID: String?
    @State private var commandCapturePresented = false
    @State private var pinnedSnippetPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.contextPackIsAgentProposed {
                Divider()
                agentDraftBanner
            }
            Divider()
            sourceToolbar
            Divider()
            packBody
            Divider()
            requestEditor
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1_080, minHeight: 650, idealHeight: 760)
        .onAppear { selectFirstPartIfNeeded() }
        .onChange(of: partIDs) { _, _ in selectFirstPartIfNeeded() }
        .sheet(isPresented: $commandCapturePresented) {
            ContextCommandCaptureView(model: model)
        }
        .sheet(isPresented: $pinnedSnippetPickerPresented) {
            PinnedContextSnippetPickerView(model: model)
        }
    }

    private var agentDraftBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("AGENT-PROPOSED CONTEXT · NOT SENT")
                    .font(.caption.monospaced().weight(.semibold))
                if let draft = model.contextPackDraft {
                    Text(
                        draft.reviewState == .awaitingReview
                            ? "\(draft.sourcePaneName) is blocked waiting for you to inspect the sources and request. Approve and Ask submits the edited pack; Decline submits nothing and releases the waiting command with a refusal."
                            : "\(draft.sourcePaneName) staged this material. Parts labelled Agent file are claims made by that pane. Local sources you add here are captured separately by Parley's core with their own provenance. Inspect or edit every part before sending."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.07))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label("Context Pack", systemImage: "shippingbox")
                .font(.title2.weight(.semibold))
            TextField("Pack name", text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Spacer()
            if let draft = model.contextPackDraft {
                Text("SOURCE · \(draft.sourcePaneName)")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(model.contextPackSourcePane == nil ? Color.red : Color.secondary)
            }
        }
        .padding(16)
    }

    private var sourceToolbar: some View {
        HStack(spacing: 10) {
            Button("Add Files…", systemImage: "doc.badge.plus") { model.addContextFiles() }
            Button("Add Git Diff", systemImage: "arrow.triangle.branch") { model.addContextGitDiff() }
            Button("Add Visible Screen…", systemImage: "rectangle.inset.filled") {
                model.addVisibleTerminalContext()
            }
            Button("Capture Command…", systemImage: "terminal") {
                commandCapturePresented = true
            }
            Button("Add Workspace Brief", systemImage: "doc.text") {
                model.addWorkspaceBriefContext()
            }
            .disabled(!model.canAddWorkspaceBriefToContextPack)
            Button("Add Pinned Snippets…", systemImage: "pin") {
                pinnedSnippetPickerPresented = true
            }
            .disabled(model.contextPackIsAgentProposed)
            Spacer()
            Text(model.contextPackIsAgentProposed ? "Added local sources are captured independently by Parley" : "Only sources you add explicitly are included")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder
    private var packBody: some View {
        if let draft = model.contextPackDraft {
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SOURCES")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    if draft.pack.parts.isEmpty {
                        ContentUnavailableView(
                            "No Explicit Sources",
                            systemImage: "shippingbox",
                            description: Text("Add files, a Git diff, one visible screen, a command result, the workspace brief or pinned context.")
                        )
                    } else {
                        List(draft.pack.parts, selection: $selectedPartID) { part in
                            sourceRow(part).tag(part.id)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .padding(14)
                .frame(minWidth: 270, idealWidth: 320)

                partEditor
                    .frame(minWidth: 500)
            }
        } else {
            ContentUnavailableView(
                "No Context Pack",
                systemImage: "shippingbox",
                description: Text("Create a pack from the Context toolbar menu.")
            )
        }
    }

    private func sourceRow(_ part: ContextPackPart) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: part.source.kind))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(part.source.label)
                        .lineLimit(1)
                    if part.isEdited {
                        Text("EDITED")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(part.source.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(part.byteCount.formatted()) bytes")
                    .font(.caption2.monospaced())
                    .foregroundStyle(part.byteCount > model.contextPackMaximumPartBytes ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var partEditor: some View {
        if let part = selectedPart {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(part.source.kind.label)
                            .font(.headline)
                        Text(part.source.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Current: \(part.byteCount.formatted()) bytes")
                        Text("Captured: \(part.capturedByteCount.formatted()) bytes")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(part.byteCount > model.contextPackMaximumPartBytes ? Color.red : Color.secondary)
                }
                Text("Editing changes only this preview. The original source and captured byte count remain recorded above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: partTextBinding(part.id))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .border(Color.secondary.opacity(0.25))
                HStack {
                    if part.isEdited {
                        Button("Restore Capture") {
                            model.updateContextPackPart(part.id, text: part.capturedText)
                        }
                    }
                    Spacer()
                    Button("Remove Source", role: .destructive) {
                        model.removeContextPackPart(part.id)
                    }
                }
            }
            .padding(14)
        } else {
            ContentUnavailableView(
                "Select a Source",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Its exact provenance, byte size and editable content will appear here.")
            )
        }
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("REQUEST FOR THE RECEIVING VENDOR")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\((model.contextPackDraft?.pack.note.utf8.count ?? 0).formatted()) bytes")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: noteBinding)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 110)
                .border(Color.secondary.opacity(0.25))
            Text("This instruction is part of the pack and must be present before Ask or Compare is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            let partCount = model.contextPackDraft?.pack.parts.count ?? 0
            VStack(alignment: .leading, spacing: 2) {
                Text("\(partCount) source\(partCount == 1 ? "" : "s") · \(model.contextPackRenderedByteCount.formatted()) of \(model.contextPackMaximumBytes.formatted()) rendered bytes")
                    .font(.caption.monospaced())
                    .foregroundStyle(model.contextPackRenderedByteCount > model.contextPackMaximumBytes ? Color.red : Color.secondary)
                if model.contextPackSourcePane == nil {
                    Text("The original source pane is no longer ready; the draft remains viewable but cannot be sent.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if model.contextPackIsAgentProposed {
                Button(
                    model.contextPackDraft?.reviewState == .awaitingReview ? "Decline Ask" : "Discard Draft",
                    role: .destructive
                ) { model.rejectCurrentContextReview() }
            }
            Button("Close") { model.dismissContextPack() }
                .keyboardShortcut(.cancelAction)
            Button(
                model.contextPackDraft?.reviewState == .awaitingReview ? "Approve and Ask…" : "Ask One Vendor…"
            ) { model.askWithContextPack() }
                .disabled(!model.contextPackIsSendable || model.contextPackAskTargets.isEmpty)
            Button("Compare Vendors…") { model.compareWithContextPack() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCompareContextPack)
        }
        .padding(14)
    }

    private var selectedPart: ContextPackPart? {
        guard let selectedPartID else { return nil }
        return model.contextPackDraft?.pack.parts.first { $0.id == selectedPartID }
    }

    private var partIDs: [String] {
        model.contextPackDraft?.pack.parts.map(\.id) ?? []
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.contextPackDraft?.pack.name ?? "" },
            set: { model.updateContextPackName($0) }
        )
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { model.contextPackDraft?.pack.note ?? "" },
            set: { model.updateContextPackNote($0) }
        )
    }

    private func partTextBinding(_ partID: String) -> Binding<String> {
        Binding(
            get: {
                model.contextPackDraft?.pack.parts.first { $0.id == partID }?.text ?? ""
            },
            set: { model.updateContextPackPart(partID, text: $0) }
        )
    }

    private func selectFirstPartIfNeeded() {
        if let selectedPartID, partIDs.contains(selectedPartID) { return }
        selectedPartID = partIDs.first
    }

    private func symbol(for kind: ContextPackSourceKind) -> String {
        switch kind {
        case .file: "doc.text"
        case .gitDiff: "arrow.triangle.branch"
        case .visibleTerminal: "rectangle.inset.filled"
        case .commandResult: "terminal"
        case .agentFileDraft: "person.crop.circle.badge.questionmark"
        case .workspaceBrief: "doc.text"
        case .pinnedSnippet: "pin"
        case .editorSelection: "selection.pin.in.out"
        case .editorDiagnostics: "exclamationmark.bubble"
        }
    }
}

private struct ContextCommandCaptureView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var executablePath = "/usr/bin/git"
    @State private var argumentLines = "status\n--short"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture Command Result")
                .font(.title2.weight(.semibold))
            Text("Parley executes one absolute executable directly in the context pack's folder. Each non-empty line below is one literal argument. There is no shell, expansion, pipe or redirect step.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Absolute executable", text: $executablePath)
                LabeledContent("Working folder") {
                    Text(model.contextPackDraft?.sourceFolder ?? "Unavailable")
                        .textSelection(.enabled)
                }
                LabeledContent("Arguments") {
                    TextEditor(text: $argumentLines)
                        .font(.body.monospaced())
                        .frame(minHeight: 150)
                        .border(Color.secondary.opacity(0.25))
                }
            }
            Text("Both stdout and stderr, plus the exact exit status, are captured into one bounded editable part.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.contextCommandCapturing)
                Button(model.contextCommandCapturing ? "Capturing…" : "Run and Capture") {
                    Task {
                        do {
                            try await model.captureContextCommand(
                                executablePath: executablePath,
                                argumentLines: argumentLines
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.contextCommandCapturing || executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 430)
        .alert(
            "Command result was not captured",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK") { errorMessage = nil } },
            message: { Text(errorMessage ?? "Unknown error") }
        )
    }
}
