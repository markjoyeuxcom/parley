import ParleyCore
import ParleyUI
import SwiftUI
import UniformTypeIdentifiers

struct ContextPackView: View {
    @ObservedObject var model: AppModel
    @State private var selectedPartID: String?
    @State private var commandCapturePresented = false
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
        .sheet(isPresented: $vendorEvidencePresented) {
            VendorToolEvidenceCaptureView(model: model)
        }
        .sheet(item: paneChoiceRequest) { request in
            PaneChoiceSheet(model: model, request: request)
        }
    }

    /// While this window is presented it owns the pane choice sheet so the
    /// choice appears over the pack being sent, not over the main window.
    private var paneChoiceRequest: Binding<PaneChoiceRequest?> {
        Binding(
            get: { model.contextPackPresented ? model.paneChoiceRequest : nil },
            set: { if $0 == nil { model.cancelPaneChoice() } }
        )
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
                .disabled(model.contextPackCaptureRunning)
                .help("Attach files you choose; each becomes an attributed, editable part")
            Button("Add Git Diff", systemImage: "arrow.triangle.branch") { model.addContextGitDiff() }
                .disabled(model.contextPackCaptureRunning)
                .help("Capture the source pane folder's current Git diff as a part")
            Button("Add Terminal Selection…", systemImage: "selection.pin.in.out") {
                model.addVisibleTerminalContext()
            }
            .disabled(model.contextPackCaptureRunning)
            Button("Capture Command…", systemImage: "terminal") {
                commandCapturePresented = true
            }
            .disabled(model.contextPackCaptureRunning)
            Button("Capture Window…", systemImage: "macwindow") { model.captureWindowIntoContextPack() }
                .disabled(!model.canCaptureWindowIntoContextPack)
                .help(model.contextPackIsAgentProposed
                    ? "Pick one window to add to this draft; the capture stays yours, so the agent cannot fetch it, only the pane you send the draft to"
                    : "Pick one window with the macOS window picker; Parley captures it once and shows it here before anything is sent")
            Menu("More Sources", systemImage: "plus") {
                Button("Add Browser/Tool Evidence…", systemImage: "globe") {
                    vendorEvidencePresented = true
                }
                .disabled(model.vendorToolEvidencePanes.isEmpty)
            }
            .disabled(model.contextPackCaptureRunning)
            if model.contextPackCaptureRunning {
                ProgressView().controlSize(.small)
                Text("Capturing…").font(.caption).foregroundStyle(.secondary)
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
                            description: Text("Add files, a Git diff, selected terminal text, a command result or browser/tool evidence.")
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
                if let image = part.image {
                    // An image is shown, not edited: its text is Parley's own
                    // description of how the receiver fetches it.
                    ContextImagePreview(image: image, store: model.contextImageStore)
                    Text(part.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    // One editor per part: its undo history belongs to that part's text.
                    PlainTextEditor(text: partTextBinding(part.id), accessibilityLabel: "Part text")
                        .id(part.id)
                        .frame(minHeight: 120)
                        .border(Color.secondary.opacity(0.25))
                }
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
            PlainTextEditor(text: noteBinding, accessibilityLabel: "Pack instruction",
                            font: .systemFont(ofSize: NSFont.systemFontSize))
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
                    .disabled(model.contextPackCaptureRunning)
            }
            Button("Close") { model.dismissContextPack() }
                .keyboardShortcut(.cancelAction)
                .help("Close this pack without sending; the draft stays with its source pane")
            Button(
                model.contextPackDraft?.reviewState == .awaitingReview ? "Approve and Ask…" : "Ask One Pane…"
            ) { model.askWithContextPack() }
                .disabled(!model.contextPackIsSendable || model.contextPackAskTargets.isEmpty)
                .help("Choose one target pane, then confirm before the attributed pack is submitted")
                .accessibilityHint("Opens a pane choice followed by a confirmation")
            Button("Compare Panes…") { model.compareWithContextPack() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCompareContextPack)
                .help("Send the same pack to at least two panes independently and compare their answers")
                .accessibilityHint("Opens a pane choice followed by a confirmation")
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
        case .visibleTerminal: "selection.pin.in.out"
        case .commandResult: "terminal"
        case .agentFileDraft: "person.crop.circle.badge.questionmark"
        case .workspaceBrief: "doc.text"
        case .handoffResult: "arrow.trianglehead.branch"
        case .pinnedSnippet: "pin"
        case .editorSelection: "selection.pin.in.out"
        case .editorDiagnostics: "exclamationmark.bubble"
        case .browserURL: "link"
        case .browserSelection: "text.quote"
        case .browserScreenshot: "photo"
        case .toolArtifact: "doc.badge.gearshape"
        case .windowCapture: "macwindow"
        case .unrecognized: "questionmark.square.dashed"
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
                        Text("\(pane.displayName) · \(pane.kind.label) · \(pane.workspaceName ?? pane.workspaceID)")
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
                        PlainTextEditor(text: $selectedText, accessibilityLabel: "Selected text")
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
                Button(model.contextCaptureInFlight ? "Adding…" : "Add to Editable Pack") {
                    Task {
                        do {
                            try await model.addVendorToolEvidence(
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
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd || model.contextCaptureInFlight)
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
                    PlainTextEditor(text: $argumentLines, accessibilityLabel: "Command arguments, one per line")
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

/// A staged image as the person reviews it: the picture, scaled to fit, and
/// exactly what Parley checked about it.
/// Reads Parley's copy once per digest, off the main actor, and shows a
/// bounded thumbnail: a render never touches the disk, hashes the copy or
/// draws a full-size frame.
struct ContextImagePreview: View {
    let image: ContextPackImage
    let store: ContextImageStore
    @State private var loaded: (digest: String, outcome: Outcome)?
    @State private var inspecting = false

    /// Kept but not drawable is not missing: the inspector does not decode
    /// pixels, so an image ImageIO cannot draw is still Parley's copy and an
    /// agent can still fetch it (Codex's review of MR !138, L2).
    private enum Outcome: Sendable {
        case shown(CGImage)
        case notDrawable
        case missing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch loaded?.digest == image.sha256 ? loaded?.outcome : nil {
            case let .shown(picture):
                Image(nsImage: NSImage(cgImage: picture, size: .zero))
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .border(Color.secondary.opacity(0.25))
                    .accessibilityLabel("Image, \(image.width) by \(image.height) pixels")
                Button("Inspect Full Size…") { inspecting = true }
                    .controlSize(.small)
                    .help("Open the image at up to its full resolution, with zoom, before sending it")
            case .notDrawable:
                Text("Parley keeps this image, but cannot draw a preview of it. A pane it is sent to can still fetch it.")
                    .foregroundStyle(.orange)
            case .missing:
                Text("Parley no longer keeps this image, or its copy no longer matches its digest.")
                    .foregroundStyle(.orange)
            case nil:
                ProgressView().controlSize(.small)
            }
            Text("\(image.format.label) · \(image.width) × \(image.height) pixels · \(image.byteCount.formatted()) bytes")
            Text("SHA-256: \(image.sha256)")
                .textSelection(.enabled)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .task(id: image.sha256) {
            let image = image, store = store
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                guard let data = try? store.data(for: image) else { return .missing }
                return ContextImageInspector.thumbnail(data, maximumPixelSize: 1_600).map(Outcome.shown) ?? .notDrawable
            }.value
            guard !Task.isCancelled else { return }
            loaded = (image.sha256, outcome)
        }
        .sheet(isPresented: $inspecting) {
            ContextImageFullSizeSheet(image: image, store: store) { inspecting = false }
        }
    }
}

/// The image at up to its full resolution, for reading fine text in a
/// screenshot before it is sent (Codex's review of 3 October 2026: the
/// preview is a 1,600-pixel thumbnail at most 360 points high). Decoded once,
/// off the main actor, scaled down when needed to at most
/// `ContextImageDecodeBudget.maximumDecodedPixels` (about 64 MB at four bytes
/// a pixel): the inspector
/// accepts up to 64 million, which would be a quarter of a gigabyte here
/// (Codex's review of MR !146). A scaled image says so, and its 100% is of
/// what is shown.
struct ContextImageFullSizeSheet: View {
    let image: ContextPackImage
    let store: ContextImageStore
    let close: () -> Void
    @State private var picture: CGImage?
    @State private var failed = false
    @State private var fit = true
    @State private var scale = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(sizeLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Fit to Window", isOn: $fit)
                    .toggleStyle(.checkbox)
                Button("Zoom Out") { zoom(by: 0.8) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(fit)
                Button(isScaledDown ? "Shown Size" : "Actual Size") { fit = false; scale = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Zoom In") { zoom(by: 1.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            Group {
                if let picture {
                    let shown = Image(nsImage: NSImage(cgImage: picture, size: .zero))
                        .resizable()
                        .interpolation(.high)
                        .accessibilityLabel("Image, \(image.width) by \(image.height) pixels")
                    if fit {
                        shown.aspectRatio(contentMode: .fit).padding(8)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            shown.frame(width: Double(picture.width) * scale, height: Double(picture.height) * scale)
                        }
                    }
                } else if failed {
                    Text("Parley could not draw this image at full size.")
                        .foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 900, minHeight: 380, idealHeight: 680)
        .task(id: image.sha256) {
            let image = image, store = store
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let data = try? store.data(for: image) else { return nil }
                return ContextImageInspector.thumbnail(
                    data, maximumPixelSize: ContextImageDecodeBudget.decodedSide(width: image.width, height: image.height)
                )
            }.value
            guard !Task.isCancelled else { return }
            picture = decoded
            failed = decoded == nil
        }
    }

    private var isScaledDown: Bool {
        guard let picture else { return false }
        return picture.width < image.width || picture.height < image.height
    }

    private var sizeLabel: String {
        let original = "\(image.format.label) · \(image.width) × \(image.height) pixels"
        guard let picture, isScaledDown else { return original }
        return original + " · shown at \(picture.width) × \(picture.height) to stay within memory"
    }

    private func zoom(by factor: Double) {
        fit = false
        scale = min(max(scale * factor, 0.1), 8)
    }
}
