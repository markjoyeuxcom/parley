import AppKit
import ParleyCore
import SwiftUI

struct HandoffComposerView: View {
    @ObservedObject var model: AppModel

    @ViewBuilder
    var body: some View {
        if let draft = model.handoffComposerDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Text(
                        draft.relationship == nil
                            ? "Reviewed handoff"
                            : (draft.relationship == .requestChanges ? "Linked delegation" : "Linked review")
                    )
                        .font(ChromeFont.secondaryMedium)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(draft.sourceName) · \(draft.sourceKind.label)")
                        .font(ChromeFont.secondaryMedium)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("\(draft.targetName) · \(draft.targetKind.label)")
                        .font(ChromeFont.secondaryMedium)
                    ChromeChip(draft.relationship?.label ?? "Ask", color: .secondary)
                    Spacer()
                    Button {
                        model.cancelHandoffComposer()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.submittingHandoffComposer)
                    .accessibilityLabel("Cancel reviewed handoff")
                }
                if let advisory = model.handoffComposerSignalAdvisory {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(Color.accentColor)
                            Text("Target signal")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                            Text(advisory.sourceLabel)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(advisory.stateLabel)
                                .fontWeight(.semibold)
                            Text("· \(advisory.signalLabel)")
                            Text("· \(advisory.ageLabel(at: context.date))")
                            Spacer(minLength: 8)
                            Text("Advisory only")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
                        }
                        .font(ChromeFont.meta)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                        .help(advisory.accessibilityDescription(at: context.date))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(advisory.accessibilityDescription(at: context.date))
                    }
                }

                TextEditor(text: Binding(
                    get: { model.handoffComposerDraft?.text ?? "" },
                    set: { text in model.updateHandoffComposerText(text) }
                ))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: composerHeight(for: draft.text))
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .disabled(model.submittingHandoffComposer)
                .accessibilityLabel("Message to \(draft.targetName)")

                HStack(spacing: 8) {
                    if draft.includesTerminalSelection {
                        Label("Terminal selection included", systemImage: "text.viewfinder")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else if let parentID = draft.inReplyToHandoffID {
                        Label(
                            "Linked to \(String(parentID.prefix(8)))",
                            systemImage: "arrow.triangle.branch"
                        )
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Only the reviewed text above will be sent")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(characterCountLabel(for: draft.text))
                        .font(ChromeFont.meta)
                        .foregroundStyle(exceedsLimit(draft.text) ? Color.red : Color.secondary)
                        .help("Relay messages are limited to \(RelayText.maximumCharacters.formatted()) characters after trimming")
                        .accessibilityLabel(characterCountAccessibilityLabel(for: draft.text))
                    Button("Insert Selection") { model.insertSelectionInHandoffComposer() }
                        .help("Insert only the text currently selected in \(draft.sourceName)")
                        .disabled(model.submittingHandoffComposer)
                    Button("Cancel") { model.cancelHandoffComposer() }
                        .disabled(model.submittingHandoffComposer)
                    Button(
                        model.submittingHandoffComposer
                            ? "Waiting on \(draft.relationship?.label ?? "Ask")..."
                            : "Send \(draft.relationship?.label ?? "Ask")"
                    ) { model.submitHandoffComposer() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            RelayText.clean(draft.text).isEmpty
                                || exceedsLimit(draft.text)
                                || model.submittingHandoffComposer
                        )
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.045))
            .accessibilityElement(children: .contain)
        }
    }

    private static let minimumEditorHeight: CGFloat = 78
    private static let maximumEditorHeight: CGFloat = 196
    private static let editorLineHeight: CGFloat = 15

    private func composerHeight(for text: String) -> CGFloat {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let wanted = CGFloat(lines) * Self.editorLineHeight + 22
        return min(max(wanted, Self.minimumEditorHeight), Self.maximumEditorHeight)
    }

    private func exceedsLimit(_ text: String) -> Bool {
        RelayText.clean(text).count > RelayText.maximumCharacters
    }

    private func characterCountLabel(for text: String) -> String {
        "\(RelayText.clean(text).count.formatted()) / \(RelayText.maximumCharacters.formatted())"
    }

    private func characterCountAccessibilityLabel(for text: String) -> String {
        let count = RelayText.clean(text).count
        let base = "\(count) of \(RelayText.maximumCharacters) characters"
        return exceedsLimit(text) ? "\(base), over the relay limit" : base
    }
}

struct CollaborationDockView: View {
    @ObservedObject var model: AppModel
    let openStatus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                Text("Collaboration")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    model.toggleCollaborationDock()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Collaboration Dock")
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("Active handoff")
                    if let handoff = model.primaryActivity {
                        activeHandoff(handoff)
                    } else {
                        Text("No collaboration is currently waiting or in flight.")
                            .font(ChromeFont.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 12)
                    }
                    if let recipe = model.activeRecipeRun {
                        Divider()
                        sectionTitle("Recipe")
                        recipeSection(recipe)
                    }
                    if let workflow = model.activeSupervisedWorkflow {
                        Divider()
                        sectionTitle("Workflow")
                        workflowSection(workflow)
                    }
                    Divider()
                    sectionTitle("Runtime")
                    fact(
                        icon: "circle.fill",
                        label: "Coordination core",
                        value: WorkbenchChromeProjection.connectionLabel(model.connectionState),
                        color: ChromeColor.connection(model.connectionState)
                    )
                    fact(icon: "bolt.horizontal", label: "Protocol", value: AgentProtocol.version, color: .secondary)
                    fact(icon: "rectangle.split.3x1", label: "Retained panes", value: "\(model.visiblePanes.count)", color: .secondary)
                    Divider().padding(.top, 10)
                    sectionTitle("Recent")
                    if model.workspaceHandoffs.isEmpty {
                        Text("No handoffs recorded in this workspace.")
                            .font(ChromeFont.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                    } else {
                        ForEach(Array(model.workspaceHandoffs.prefix(6))) { handoff in
                            recentHandoff(handoff)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Button("Open Status", action: openStatus)
                Spacer()
                if let handoff = model.primaryActivity,
                   model.canFocus(handoff.targetPaneID) {
                    Button("Focus Target") { model.focus(handoff, target: true) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sectionTitle(_ title: String) -> some View {
        ChromeHeading(title)
            .padding(.horizontal, 11)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    private func recipeSection(_ recipe: ActiveRecipeRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("\(recipe.recipeName) → \(recipe.leadName)")
                    .font(ChromeFont.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ChromeChip("Submitted", color: .secondary)
            }
            Text(recipe.instructions)
                .font(ChromeFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Stop…") { model.interruptActiveRecipeRun() }
                    .accessibilityLabel("Interrupt workspace lead")
                    .accessibilityHint("Send Control-C after explicit confirmation")
                    .help("Interrupt the lead pane after explicit confirmation")
                Button("Dismiss") { model.dismissActiveRecipeRun() }
                    .accessibilityLabel("Dismiss submitted recipe notice")
                    .help("Hide this notice; the lead pane keeps running")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
        .help(recipe.instructions)
        .accessibilityElement(children: .contain)
    }

    private func workflowSection(_ run: SupervisedWorkflowRun) -> some View {
        let checkpoint = run.phase == .awaitingImplementationApproval || run.phase == .awaitingCompletionApproval
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(run.name)
                    .font(ChromeFont.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ChromeChip(run.mode.label, color: run.mode == .automatic ? .accentColor : .secondary)
            }
            HStack(spacing: 6) {
                Text(run.phase.label)
                    .font(ChromeFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if checkpoint {
                    ChromeChip("Human checkpoint", color: .orange)
                }
            }
            HStack(spacing: 6) {
                Button("Open") { model.presentSupervisedWorkflow() }
                    .help("Open the supervised workflow window")
                Button("End…", role: .destructive) { model.interruptSupervisedWorkflow() }
                    .help("End this supervised workflow after explicit confirmation")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
        .help("\(run.name) · \(run.phase.label)")
        .accessibilityElement(children: .contain)
    }

    private func activeHandoff(_ handoff: RelayHandoff) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button(handoff.sourceName) { model.focus(handoff, target: false) }
                    .disabled(!model.canFocus(handoff.sourcePaneID))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button(handoff.targetName) { model.focus(handoff, target: true) }
                    .disabled(!model.canFocus(handoff.targetPaneID))
            }
            .buttonStyle(.plain)
            .font(ChromeFont.secondaryMedium)
            Text(subject(handoff.text))
                .font(ChromeFont.secondary)
                .lineLimit(3)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(handoff.kind.rawValue.capitalized)
                            .font(ChromeFont.secondary)
                        Spacer()
                        Text(timing(handoff, at: context.date))
                            .font(ChromeFont.meta)
                        ChromeChip(stateLabel(handoff), color: ChromeColor.handoff(handoff))
                    }
                    if let facts = model.delegationVisibility(for: handoff, at: context.date) {
                        delegationFacts(facts)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func delegationFacts(_ facts: DelegationVisibility) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(facts.elapsedLabel, systemImage: "clock")
            Label(facts.targetSignalLabel, systemImage: "checkmark.shield")
            Label(facts.progressSummary, systemImage: "text.bubble")
                .lineLimit(2)
                .truncationMode(.tail)
            if let detail = facts.quietDetail {
                Label(DelegationVisibility.quietTitle, systemImage: "info.circle")
                    .help(detail)
            }
        }
        .font(ChromeFont.meta)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(facts.accessibilityDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(facts.accessibilityDescription)
    }

    private func fact(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 11)
                .accessibilityHidden(true)
            Text(label)
                .font(ChromeFont.secondary)
            Spacer()
            Text(value)
                .font(ChromeFont.meta)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
    }

    private func recentHandoff(_ handoff: RelayHandoff) -> some View {
        Button {
            if model.canFocus(handoff.targetPaneID) { model.focus(handoff, target: true) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(handoff.sourceName) → \(handoff.targetName)")
                        .font(ChromeFont.secondaryMedium)
                        .lineLimit(1)
                    Spacer()
                    ChromeChip(stateLabel(handoff), color: ChromeColor.handoff(handoff))
                }
                Text(subject(handoff.text))
                    .font(ChromeFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canFocus(handoff.targetPaneID))
        .accessibilityLabel(WorkbenchAccessibility.handoff(handoff))
    }

    private func subject(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private func timing(_ handoff: RelayHandoff, at now: Date) -> String {
        let terminalStates: Set<RelayHandoffState> = [.completed, .cancelled, .failed, .interrupted]
        let origin = terminalStates.contains(handoff.state)
            ? handoff.updatedAt
            : handoff.transitions.first?.occurredAt ?? handoff.updatedAt
        let seconds = max(0, Int(now.timeIntervalSince(origin)))
        let amount: String
        if seconds < 60 { amount = "\(seconds)s" }
        else if seconds < 3_600 { amount = "\(seconds / 60)m" }
        else { amount = "\(seconds / 3_600)h" }
        return terminalStates.contains(handoff.state) ? "\(amount) ago" : "for \(amount)"
    }

    private func stateLabel(_ handoff: RelayHandoff) -> String {
        switch handoff.attention {
        case .permissionRequired: "Permission"
        case .targetNotReady: "Not ready"
        case .targetUnavailable: "Unavailable"
        case nil: handoff.state.rawValue.capitalized
        }
    }
}
