import ParleyCore
import SwiftUI
import UniformTypeIdentifiers

struct ContextPackView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPartID: String?
    @State private var commandCapturePresented = false
    @State private var pinnedSnippetPickerPresented = false
    @State private var vendorEvidencePresented = false

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
        .sheet(isPresented: $vendorEvidencePresented) {
            VendorToolEvidenceCaptureView(model: model)
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
            Menu("More Sources", systemImage: "plus") {
                Button("Add Browser/Tool Evidence…", systemImage: "globe") {
                    vendorEvidencePresented = true
                }
                .disabled(model.vendorToolEvidencePanes.isEmpty)
                Button("Add Workspace Brief", systemImage: "doc.text") {
                    model.addWorkspaceBriefContext()
                }
                .disabled(!model.canAddWorkspaceBriefToContextPack)
                Button("Add Pinned Snippets…", systemImage: "pin") {
                    pinnedSnippetPickerPresented = true
                }
                .disabled(model.contextPackIsAgentProposed)
            }
            Spacer()
            Text(model.contextPackIsAgentProposed ? "Every added source states exactly what Parley established" : "Only sources you add explicitly are included")
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
                            description: Text("Add files, a Git diff, one visible screen, a command result, browser/tool evidence, the workspace brief or pinned context.")
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
                if let evidence = part.source.vendorEvidence {
                    Text("TOOL \(evidence.toolAccess.label.uppercased())")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(evidence.toolAccess == .verified ? Color.green : Color.orange)
                    if let artifactBytes = evidence.artifactByteCount {
                        Text("Artifact: \(artifactBytes.formatted()) bytes")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
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
                if let evidence = part.source.vendorEvidence {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Attributed by the person to \(evidence.paneName) · \(evidence.vendor.label) · \(evidence.paneID)")
                        Text("Browser/tool capability: \(evidence.toolAccess.label). \(evidence.toolAccessDetail)")
                        if let sourceURL = evidence.sourceURL { Text("URL: \(sourceURL)") }
                        if let artifactPath = evidence.artifactPath { Text("Local artifact: \(artifactPath)") }
                        if let bytes = evidence.artifactByteCount { Text("Artifact: \(bytes.formatted()) bytes") }
                        if let digest = evidence.sha256 { Text("SHA-256: \(digest)") }
                        Text("Parley did not open, scrape or control the vendor browser session.")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
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
        case .browserURL: "link"
        case .browserSelection: "text.quote"
        case .browserScreenshot: "photo"
        case .toolArtifact: "doc.badge.gearshape"
        }
    }
}

private struct VendorToolEvidenceCaptureView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPaneID: String
    @State private var kind = VendorToolEvidenceKind.browserURL
    @State private var sourceURL = ""
    @State private var selectedText = ""
    @State private var artifactPath = ""
    @State private var errorMessage: String?

    init(model: AppModel) {
        self.model = model
        _selectedPaneID = State(
            initialValue: model.contextPackSourcePane?.id
                ?? model.vendorToolEvidencePanes.first?.id
                ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Browser or Tool Evidence")
                .font(.title2.weight(.semibold))
            Text("Parley records what you select and who you attribute it to. It does not inspect the vendor's browser session, MCP servers, cookies or credentials.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Evidence from", selection: $selectedPaneID) {
                    ForEach(model.vendorToolEvidencePanes) { pane in
                        Text("\(pane.displayName) · \(pane.kind.label) · \(pane.workspaceName ?? pane.windowID)")
                            .tag(pane.id)
                    }
                }
                Picker("Evidence type", selection: $kind) {
                    ForEach(VendorToolEvidenceKind.allCases, id: \.rawValue) { evidenceKind in
                        Text(evidenceKind.label).tag(evidenceKind)
                    }
                }
                if kind == .browserURL || kind == .browserSelection {
                    TextField("HTTP(S) source URL", text: $sourceURL)
                } else {
                    TextField("HTTP(S) source URL (optional)", text: $sourceURL)
                }
                if kind == .browserSelection {
                    LabeledContent("Selected text") {
                        TextEditor(text: $selectedText)
                            .font(.body.monospaced())
                            .frame(minHeight: 150)
                            .border(Color.secondary.opacity(0.25))
                    }
                }
                if kind == .browserScreenshot || kind == .savedArtifact {
                    LabeledContent("Local file") {
                        HStack {
                            Text(artifactPath.isEmpty ? "No file selected" : artifactPath)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Choose…") { chooseArtifact() }
                        }
                    }
                }
            }

            if let capability {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BROWSER/TOOL ACCESS · \(capability.toolAccess.label.uppercased())")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(capability.toolAccess == .verified ? Color.green : Color.orange)
                    Text(capability.detail)
                    Text("Network policy: \(capability.networkLabel). This is permission intent, not proof that a browser tool exists.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(kind == .browserScreenshot || kind == .savedArtifact
                ? "Parley validates, measures and hashes at most 25 MB. Binary bytes are not embedded; the reviewed pack carries the exact local path, size and SHA-256."
                : "The URL and selected text are person-provided. Parley validates the URL shape but never fetches or verifies the page.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Editable Pack") {
                    do {
                        try model.addVendorToolEvidence(
                            kind: kind,
                            paneID: selectedPaneID,
                            sourceURL: sourceURL,
                            selectedText: selectedText,
                            artifactPath: artifactPath
                        )
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 520)
        .alert(
            "Evidence was not added",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK") { errorMessage = nil } },
            message: { Text(errorMessage ?? "Unknown error") }
        )
    }

    private var capability: PaneToolCapabilitySummary? {
        guard let pane = model.vendorToolEvidencePanes.first(where: { $0.id == selectedPaneID }) else {
            return nil
        }
        return model.paneToolCapabilitySummary(for: pane)
    }

    private var canAdd: Bool {
        guard capability?.canCaptureEvidence == true else { return false }
        switch kind {
        case .browserURL:
            return !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .browserSelection:
            return !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .browserScreenshot, .savedArtifact:
            return !artifactPath.isEmpty
        }
    }

    private func chooseArtifact() {
        let panel = NSOpenPanel()
        panel.title = kind == .browserScreenshot ? "Choose Browser Screenshot" : "Choose Saved Tool Artifact"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if kind == .browserScreenshot { panel.allowedContentTypes = [.image] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        artifactPath = url.path
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
