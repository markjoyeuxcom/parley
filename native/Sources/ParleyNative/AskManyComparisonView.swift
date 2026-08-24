import ParleyCore
import SwiftUI

struct AskManyComparisonView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTargetPaneIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            comparisonBody
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 560, idealHeight: 680)
        .onAppear { selectSuccessfulAnswersIfNeeded() }
        .onChange(of: successfulTargetPaneIDs) { _, _ in
            selectSuccessfulAnswersIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Independent Comparison", systemImage: "rectangle.split.3x1")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let run = model.askManyComparisonRun {
                    Text(run.isRunning ? "WAITING" : run.error == nil ? "COMPLETE" : "INTERRUPTED")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(run.isRunning ? Color.orange : run.error == nil ? Color.secondary : Color.red)
                }
            }
            if let question = model.askManyComparisonRun?.question {
                Text(question)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            Text("Each pane received the same question without seeing any peer answer. Parley does not manufacture a consensus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    @ViewBuilder
    private var comparisonBody: some View {
        if let run = model.askManyComparisonRun {
            VStack(alignment: .leading, spacing: 12) {
                if run.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(waitingSummary(run))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = run.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(run.targets) { target in
                            answerCard(target, answer: answer(for: target))
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .padding(18)
        } else {
            ContentUnavailableView(
                "No Comparison",
                systemImage: "rectangle.split.3x1",
                description: Text("Choose Compare Independently from the Ask menu.")
            )
        }
    }

    private func answerCard(
        _ target: AskManyComparisonTarget,
        answer: RelayAskManyAnswer?
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.headline)
                        Text(target.kind.label + locationSuffix(target.workspaceName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let answer {
                        Text(answer.status >= 200 && answer.status < 300 ? "ANSWERED" : "FAILED")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(answer.answer == nil ? Color.red : Color.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Divider()
                if let text = answer?.answer {
                    ScrollView {
                        Text(text)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                    Toggle(
                        "Include when forwarding",
                        isOn: selectionBinding(for: target.paneID)
                    )
                    Button("Forward This Answer…") {
                        model.forwardComparisonAnswers([target.paneID], asSynthesis: false)
                    }
                    .disabled(model.askManyComparisonLead == nil)
                } else if let error = answer?.error {
                    ScrollView {
                        Text(error)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                    Text("Failures stay visible but cannot be forwarded as answers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Spacer()
                    Text("Waiting for this pane to return through Parley.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(6)
        }
        .frame(width: 330, height: 390)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let lead = model.askManyComparisonLead {
                Label("Forward to lead: \(lead.displayName)", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Mark a ready workspace lead to forward results", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.askManyOutstandingConsultations.isEmpty {
                Button("Cancel Outstanding…", role: .destructive) {
                    model.cancelAskManyComparison()
                }
            }
            Spacer()
            Button("Close") { model.dismissAskManyComparison() }
                .keyboardShortcut(.cancelAction)
            Button("Draft Synthesis…") {
                model.forwardComparisonAnswers(successfulTargetPaneIDs, asSynthesis: true)
            }
            .disabled(successfulTargetPaneIDs.isEmpty || model.askManyComparisonLead == nil)
            Button("Forward Selected…") {
                model.forwardComparisonAnswers(selectedTargetPaneIDs, asSynthesis: false)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTargetPaneIDs.isEmpty || model.askManyComparisonLead == nil)
        }
        .padding(14)
    }

    private var successfulTargetPaneIDs: Set<String> {
        Set(model.askManyComparisonRun?.response?.bundle.answers.compactMap { answer in
            answer.answer == nil ? nil : answer.targetPaneID
        } ?? [])
    }

    private func answer(for target: AskManyComparisonTarget) -> RelayAskManyAnswer? {
        model.askManyComparisonRun?.response?.bundle.answers.first {
            $0.targetPaneID == target.paneID
        }
    }

    private func waitingSummary(_ run: AskManyComparisonRun) -> String {
        let outstanding = model.askManyOutstandingConsultations.count
        return outstanding == 0
            ? "Submitting the comparison…"
            : "Waiting for \(outstanding) of \(run.targets.count) answers"
    }

    private func selectionBinding(for paneID: String) -> Binding<Bool> {
        Binding(
            get: { selectedTargetPaneIDs.contains(paneID) },
            set: { selected in
                if selected {
                    selectedTargetPaneIDs.insert(paneID)
                } else {
                    selectedTargetPaneIDs.remove(paneID)
                }
            }
        )
    }

    private func selectSuccessfulAnswersIfNeeded() {
        if selectedTargetPaneIDs.isEmpty {
            selectedTargetPaneIDs = successfulTargetPaneIDs
        } else {
            selectedTargetPaneIDs.formIntersection(successfulTargetPaneIDs)
        }
    }

    private func locationSuffix(_ workspaceName: String?) -> String {
        workspaceName.map { " · \($0)" } ?? ""
    }
}
