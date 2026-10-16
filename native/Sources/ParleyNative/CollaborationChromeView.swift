import AppKit
import ParleyCore
import ParleyUI
import SwiftUI

struct HandoffComposerView: View {
    @ObservedObject var model: AppModel
    /// The composer is inline chrome, not a sheet, so nothing takes keyboard
    /// focus from the Ghostty pane the person was in when they chose Ask. Left
    /// alone, their first keystrokes go to that terminal and the box looks
    /// dead until clicked. Focus is requested when the composer appears and
    /// again for each new draft.

    @ViewBuilder
    var body: some View {
        if let draft = model.handoffComposerDraft {
            // Cleaned once per render: the count, the over-limit colour, the
            // accessibility label and Send's state all read it, and cleaning
            // a long draft is not free now that nothing is truncated.
            let cleanedCount = RelayText.clean(draft.text).count
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
                    // The same wire as the pane headers and the dock: source
                    // monogram, line, target monogram, then the names.
                    ChromeMonogram(kind: draft.sourceKind, size: 16)
                    Text(draft.voiceSource?.label ?? draft.sourceName)
                        .font(ChromeFont.secondaryMedium)
                    ChromeWireLine(color: .accentColor, length: 14)
                    ChromeMonogram(kind: draft.targetKind, size: 16)
                    Text(draft.voiceTarget?.label ?? draft.targetName)
                        .font(ChromeFont.secondaryMedium)
                    ChromeChip(draft.actionLabel, color: .secondary)
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

                // A plain editor: a message to an agent often carries a command
                // or code, and macOS smart quotes and dashes would change it.
                PlainTextEditor(
                    text: Binding(
                        get: { model.handoffComposerDraft?.text ?? "" },
                        set: { text in model.updateHandoffComposerText(text) }
                    ),
                    isEditable: !model.submittingHandoffComposer,
                    accessibilityLabel: "Message to \(draft.targetName)",
                    font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                    drawsBackground: false,
                    // Asks for focus when it appears and again for each new draft.
                    focusRequest: draft.id
                )
                .padding(5)
                .frame(height: composerHeight(for: draft.text))
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }

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
                    Text(characterCountLabel(cleanedCount))
                        .font(ChromeFont.meta)
                        .foregroundStyle(exceedsLimit(cleanedCount) ? Color.red : Color.secondary)
                        .help("Relay messages are limited to \(RelayText.maximumCharacters.formatted()) characters after trimming")
                        .accessibilityLabel(characterCountAccessibilityLabel(cleanedCount))
                    Button("Insert Selection") { model.insertSelectionInHandoffComposer() }
                        .help("Insert only the text currently selected in \(draft.sourceName)")
                        .disabled(model.submittingHandoffComposer)
                    Button("Cancel") { model.cancelHandoffComposer() }
                        .disabled(model.submittingHandoffComposer)
                    Button(
                        model.submittingHandoffComposer
                            ? "Waiting on \(draft.actionLabel)..."
                            : "Send \(draft.actionLabel)"
                    ) { model.submitHandoffComposer() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            cleanedCount == 0
                                || exceedsLimit(cleanedCount)
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

    private func exceedsLimit(_ cleanedCount: Int) -> Bool {
        cleanedCount > RelayText.maximumCharacters
    }

    private func characterCountLabel(_ cleanedCount: Int) -> String {
        "\(cleanedCount.formatted()) / \(RelayText.maximumCharacters.formatted())"
    }

    private func characterCountAccessibilityLabel(_ cleanedCount: Int) -> String {
        let base = "\(cleanedCount) of \(RelayText.maximumCharacters) characters"
        return exceedsLimit(cleanedCount) ? "\(base), over the relay limit" : base
    }
}

/// The Collaboration Dock as a ledger: what is in flight, what came back and
/// is waiting to be read, the runtime facts, then the day's record with a
/// time column. Every handoff is drawn with the wire, source to target.
struct CollaborationDockView: View {
    @ObservedObject var model: AppModel
    let openStatus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("Collaboration")
                    .font(ChromeFont.windowTitle)
                Spacer()
                Button {
                    model.toggleCollaborationDock()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hide Collaboration Dock")
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle("In flight")
                    if let handoff = model.primaryActivity {
                        card { activeHandoff(handoff) }
                    } else {
                        Text("Nothing is waiting or in flight.")
                            .font(ChromeFont.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 12)
                    }
                    if let recipe = model.activeRecipeRun {
                        sectionTitle("Recipe")
                        card { recipeSection(recipe) }
                    }
                    let returned = returnedHandoffs
                    if !returned.isEmpty {
                        sectionTitle("Returned")
                        ForEach(returned.prefix(3)) { handoff in
                            card { returnedHandoff(handoff) }
                        }
                    }
                    sectionTitle("Runtime")
                    fact(
                        label: "Coordination core",
                        value: WorkbenchChromeProjection.connectionLabel(model.connectionState),
                        color: ChromeColor.connection(model.connectionState)
                    )
                    let protocolFact = WorkbenchChromeProjection.protocolLabel(panes: model.panes)
                    fact(label: "Protocol", value: protocolFact.value, color: protocolFact.needsRestart ? .orange : .secondary)
                    fact(label: "Retained panes", value: "\(model.visiblePanes.count)", color: .secondary)
                    sectionTitle("Recent")
                    if model.workspaceHandoffs.isEmpty {
                        Text("No handoffs recorded in this workspace.")
                            .font(ChromeFont.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 12)
                    } else {
                        ForEach(Array(model.workspaceHandoffs.prefix(8))) { handoff in
                            recentHandoff(handoff)
                        }
                    }
                }
                .padding(.bottom, 8)
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
        .background(ChromeSurface.paper)
    }

    /// Results that returned to a pane in this workspace and have not been
    /// read: the dock's second section, so a result is never only a chip.
    private var returnedHandoffs: [RelayHandoff] {
        let unread = Set(model.unreadHandoffs.map(\.id))
        guard !unread.isEmpty else { return [] }
        return model.workspaceHandoffs.filter { unread.contains($0.id) }
    }

    private func sectionTitle(_ title: String) -> some View {
        ChromeHeading(title)
            .padding(.horizontal, 11)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    /// One raised card per live item: the only elevation in the dock.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChromeSurface.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ChromeRule.hairline, lineWidth: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
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
        .help(recipe.instructions)
        .accessibilityElement(children: .contain)
    }

    private func activeHandoff(_ handoff: RelayHandoff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { model.focus(handoff, target: false) } label: {
                    HStack(spacing: 4) {
                        if let kind = handoff.sourceKind { ChromeMonogram(kind: kind, size: 18) }
                        Text(handoff.sourceName)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!model.canFocus(handoff.sourcePaneID))
                .accessibilityLabel("Focus \(handoff.sourceName)")
                ChromeWireLine(color: ChromeColor.handoff(handoff), length: 16)
                Button { model.focus(handoff, target: true) } label: {
                    HStack(spacing: 4) {
                        if let kind = handoff.targetKind { ChromeMonogram(kind: kind, size: 18) }
                        Text(handoff.targetName)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!model.canFocus(handoff.targetPaneID))
                .accessibilityLabel("Focus \(handoff.targetName)")
                Spacer(minLength: 4)
                ChromeChip("\(handoff.kind.label) · \(stateLabel(handoff))", color: ChromeColor.handoff(handoff))
            }
            .buttonStyle(.plain)
            .font(ChromeFont.bodyMedium)
            Text(subject(handoff.text))
                .font(ChromeFont.body)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(String(handoff.id.prefix(12)))
                        Text("·")
                        Text(timing(handoff, at: context.date))
                    }
                    .font(ChromeFont.meta)
                    if let facts = model.delegationVisibility(for: handoff, at: context.date) {
                        delegationFacts(facts)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A returned result waiting to be read: the wire runs back to the pane
    /// that asked, and the one action reads it.
    private func returnedHandoff(_ handoff: RelayHandoff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let kind = handoff.targetKind { ChromeMonogram(kind: kind, size: 18) }
                ChromeWireLine(color: .green, length: 16)
                if let kind = handoff.sourceKind { ChromeMonogram(kind: kind, size: 18) }
                Text("to \(handoff.sourceName)")
                    .font(ChromeFont.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ChromeChip("\(handoff.kind.label) · returned", color: .green)
            }
            Text(subject(handoff.resultText ?? handoff.text))
                .font(ChromeFont.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(String(handoff.id.prefix(12)))
                Text("·")
                Text(handoff.updatedAt.formatted(date: .omitted, time: .shortened))
                Spacer()
                Button("Open in Status", action: openStatus)
                Button("Mark Read") { model.markRead(handoff) }
                    .accessibilityHint("Mark this result as read without opening it")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(ChromeFont.meta)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(WorkbenchAccessibility.handoff(handoff))
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

    private func fact(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(label)
                .font(ChromeFont.secondary)
            Spacer()
            Text(value)
                .font(ChromeFont.meta)
                .foregroundStyle(color == .secondary ? Color.secondary : color)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// One ledger row: the time in a fixed column, the wire, the kind, the
    /// state. The row opens the target pane when it can.
    private func recentHandoff(_ handoff: RelayHandoff) -> some View {
        Button {
            if model.canFocus(handoff.targetPaneID) { model.focus(handoff, target: true) }
        } label: {
            HStack(spacing: 8) {
                Text(handoff.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(ChromeFont.meta)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                ChromeWire(handoff: handoff, size: 14, length: 10)
                Text(handoff.kind.label)
                    .font(ChromeFont.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ChromeChip(stateLabel(handoff), color: ChromeColor.handoff(handoff))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(ChromeRule.soft).frame(height: 1).padding(.horizontal, 11)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canFocus(handoff.targetPaneID))
        .help(subject(handoff.text))
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
