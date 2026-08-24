import ParleyCore
import SwiftUI

struct WorkspaceBriefView: View {
    @ObservedObject var model: AppModel
    @State private var goal: String
    @State private var constraints: String
    @State private var decisions: String

    init(model: AppModel) {
        self.model = model
        let draft = model.workspaceBriefDraft
        _goal = State(initialValue: draft?.goal ?? "")
        _constraints = State(initialValue: draft?.constraints ?? "")
        _decisions = State(initialValue: draft?.decisions ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notice
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editor(
                        "CURRENT GOAL",
                        help: "The outcome agents should work toward now.",
                        text: $goal,
                        minimumHeight: 110
                    )
                    editor(
                        "CONSTRAINTS",
                        help: "Boundaries, non-goals, safety rules and compatibility requirements.",
                        text: $constraints,
                        minimumHeight: 150
                    )
                    editor(
                        "IMPORTANT DECISIONS",
                        help: "Decisions already made that should not be silently reopened.",
                        text: $decisions,
                        minimumHeight: 170
                    )
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 650, idealHeight: 760)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label("Workspace Brief", systemImage: "doc.text")
                .font(.title2.weight(.semibold))
            if let draft = model.workspaceBriefDraft {
                Text(draft.workspaceName)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.workspaceBriefDraft?.existingBriefID == nil ? "NEW" : "SAVED LOCAL REFERENCE")
                .font(.caption.monospaced().weight(.semibold))
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
                Text("Saving contacts no agent and changes no agent session. Attach the brief only from an editable Context Pack preview. Do not store vendor credentials, tokens or other secrets here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.055))
    }

    private func editor(
        _ title: String,
        help: String,
        text: Binding<String>,
        minimumHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(text.wrappedValue.utf8.count.formatted()) bytes")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(minHeight: minimumHeight)
                .border(Color.secondary.opacity(0.25))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.workspaceBriefDraft?.existingBriefID != nil {
                Button("Delete Brief…", role: .destructive) { model.deleteWorkspaceBrief() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(contentBytes.formatted()) of \(WorkspaceBriefStore.maximumContentBytes.formatted()) content bytes")
                    .font(.caption.monospaced())
                    .foregroundStyle(contentBytes > WorkspaceBriefStore.maximumContentBytes ? Color.red : Color.secondary)
                Text("The brief stays local until you explicitly add its snapshot to a context pack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.dismissWorkspaceBrief() }
                .keyboardShortcut(.cancelAction)
            Button("Save Brief") {
                model.saveWorkspaceBrief(
                    goal: goal,
                    constraints: constraints,
                    decisions: decisions
                )
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isSaveable)
        }
        .padding(18)
    }

    private var contentBytes: Int {
        ContextPackText.normalize(goal).utf8.count
            + ContextPackText.normalize(constraints).utf8.count
            + ContextPackText.normalize(decisions).utf8.count
    }

    private var isSaveable: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && contentBytes <= WorkspaceBriefStore.maximumContentBytes
    }
}
