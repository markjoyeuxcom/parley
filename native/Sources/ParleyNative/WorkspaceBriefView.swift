import ParleyCore
import SwiftUI

struct WorkspaceBriefView: View {
    @ObservedObject var model: AppModel
    @State private var goal: String
    @State private var constraints: String
    @State private var decisions: String
    @State private var conclusions: String
    @State private var rationale: String
    @State private var confidence: String
    @State private var openQuestions: String

    init(model: AppModel) {
        self.model = model
        let draft = model.workspaceBriefDraft
        _goal = State(initialValue: draft?.goal ?? "")
        _constraints = State(initialValue: draft?.constraints ?? "")
        _decisions = State(initialValue: draft?.decisions ?? "")
        _conclusions = State(initialValue: draft?.conclusions ?? "")
        _rationale = State(initialValue: draft?.rationale ?? "")
        _confidence = State(initialValue: draft?.confidence ?? "")
        _openQuestions = State(initialValue: draft?.openQuestions ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notice
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    editor(
                        "CURRENT GOAL",
                        help: "The outcome agents should work toward now.",
                        text: $goal,
                        minimumHeight: 90
                    )
                    HStack(alignment: .top, spacing: 16) {
                        editor(
                            "CONSTRAINTS",
                            help: "Boundaries, non-goals, safety rules and compatibility requirements.",
                            text: $constraints,
                            minimumHeight: 120
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        editor(
                            "IMPORTANT DECISIONS",
                            help: "Decisions already made that should not be silently reopened.",
                            text: $decisions,
                            minimumHeight: 120
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("INVESTIGATION RECORD")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Durable person-owned findings for this workspace. Empty fields remain explicitly unrecorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    editor(
                        "INVESTIGATION CONCLUSIONS",
                        help: "Findings the person has accepted from completed cross-vendor work.",
                        text: $conclusions,
                        minimumHeight: 120
                    )
                    HStack(alignment: .top, spacing: 16) {
                        editor(
                            "RATIONALE",
                            help: "Why those conclusions or decisions were accepted.",
                            text: $rationale,
                            minimumHeight: 120
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        editor(
                            "OPEN QUESTIONS",
                            help: "Unknowns or unresolved issues that future work should preserve.",
                            text: $openQuestions,
                            minimumHeight: 120
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    editor(
                        "PERSON-AUTHORED CONFIDENCE",
                        help: "The person's confidence and its basis; Parley never calculates this.",
                        text: $confidence,
                        minimumHeight: 70
                    )
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 700, idealHeight: 820)
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
                Text("Saving this person-authored record does not contact an agent or alter any agent session. Parley never infers its conclusions or confidence. Attach it only from an editable Context Pack preview, and do not store credentials, tokens or other secrets here.")
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
                    decisions: decisions,
                    conclusions: conclusions,
                    rationale: rationale,
                    confidence: confidence,
                    openQuestions: openQuestions
                )
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isSaveable)
        }
        .padding(18)
    }

    private var contentBytes: Int {
        [
            goal,
            constraints,
            decisions,
            conclusions,
            rationale,
            confidence,
            openQuestions,
        ].reduce(0) { $0 + ContextPackText.normalize($1).utf8.count }
    }

    private var isSaveable: Bool {
        !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && contentBytes <= WorkspaceBriefStore.maximumContentBytes
    }
}
