import AppKit
import ParleyCore
import SwiftUI

struct FocusCanvasStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.inset.filled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            if let pane = model.activePane {
                Text("FOCUS CANVAS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(pane.displayName)
                    .font(.system(size: 10, weight: .semibold))
                if let role = pane.role {
                    Text("@\(role)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Peers remain live and selectable")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Return to Grid") { model.exitFocusCanvas() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Color.accentColor.opacity(0.065))
        .accessibilityElement(children: .contain)
    }
}

struct HandoffComposerView: View {
    @ObservedObject var model: AppModel

    @ViewBuilder
    var body: some View {
        if let draft = model.handoffComposerDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Text(draft.relationship == nil ? "REVIEWED HANDOFF" : "LINKED REVIEW")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Text("\(draft.sourceName) · \(draft.sourceKind.label)")
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("\(draft.targetName) · \(draft.targetKind.label)")
                        .font(.system(size: 10, weight: .semibold))
                    Text(draft.relationship?.rawValue.uppercased() ?? "ASK")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
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
                            Text("TARGET SIGNAL")
                                .fontWeight(.bold)
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
                            Text("ADVISORY ONLY")
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
                        }
                        .font(.system(size: 8, design: .monospaced))
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
                .frame(minHeight: 78, maxHeight: 118)
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
                            RelayText.clean(draft.text).isEmpty || model.submittingHandoffComposer
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
                    sectionTitle("ACTIVE HANDOFF")
                    if let handoff = model.primaryActivity {
                        activeHandoff(handoff)
                    } else {
                        Text("No collaboration is currently waiting or in flight.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.bottom, 12)
                    }
                    Divider()
                    sectionTitle("RUNTIME")
                    fact(
                        icon: "circle.fill",
                        label: "Coordination core",
                        value: WorkbenchChromeProjection.connectionLabel(model.connectionState),
                        color: connectionStatusColor
                    )
                    fact(icon: "bolt.horizontal", label: "Protocol", value: AgentProtocol.version, color: .secondary)
                    fact(icon: "rectangle.split.3x1", label: "Retained panes", value: "\(model.visiblePanes.count)", color: .secondary)
                    Divider().padding(.top, 10)
                    sectionTitle("RECENT")
                    if model.workspaceHandoffs.isEmpty {
                        Text("No handoffs recorded in this workspace.")
                            .font(.system(size: 10))
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

    private var connectionStatusColor: Color {
        switch model.connectionState {
        case .connected: .green
        case .coreDisconnected: .orange
        case .terminalDisconnected: .red
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func activeHandoff(_ handoff: RelayHandoff) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button(handoff.sourceName) { model.focus(handoff, target: false) }
                    .disabled(!model.canFocus(handoff.sourcePaneID))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Button(handoff.targetName) { model.focus(handoff, target: true) }
                    .disabled(!model.canFocus(handoff.targetPaneID))
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            Text(subject(handoff.text))
                .font(.system(size: 10))
                .lineLimit(3)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    Text(handoff.kind.rawValue.uppercased())
                    Spacer()
                    Text(timing(handoff, at: context.date))
                    Text(stateLabel(handoff))
                        .foregroundStyle(stateColor(handoff))
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func fact(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(color)
                .frame(width: 11)
            Text(label)
                .font(.system(size: 9))
            Spacer()
            Text(value)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
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
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(stateLabel(handoff))
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(stateColor(handoff))
                }
                Text(subject(handoff.text))
                    .font(.system(size: 9))
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
        case .permissionRequired: "PERMISSION"
        case .targetNotReady: "NOT READY"
        case .targetUnavailable: "UNAVAILABLE"
        case nil: handoff.state.rawValue.uppercased()
        }
    }

    private func stateColor(_ handoff: RelayHandoff) -> Color {
        if handoff.attention != nil { return .orange }
        return switch handoff.state {
        case .created, .delivered, .waiting, .answered: .accentColor
        case .failed, .interrupted: .red
        case .completed, .cancelled: .secondary
        }
    }
}
