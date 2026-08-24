import ParleyCore
import SwiftUI

struct SupervisedWorkflowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let run = model.presentedSupervisedWorkflow {
                workflow(run)
            } else {
                ContentUnavailableView(
                    "No Active Workflow",
                    systemImage: "checklist",
                    description: Text("Start the bounded sequence from Recipes in the workspace toolbar.")
                )
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 640)
    }

    private func workflow(_ run: SupervisedWorkflowRun) -> some View {
        VStack(spacing: 0) {
            header(run)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    phaseTrack(run)
                    checkpoint(run)
                    participants(run)
                    artifacts(run)
                    history(run)
                }
                .padding(20)
            }
            Divider()
            footer(run)
        }
    }

    private func header(_ run: SupervisedWorkflowRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.name)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(run.workspaceName) · started \(run.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(run.phase.label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(phaseColor(run.phase))
            Button("Close") { model.supervisedWorkflowPresented = false }
        }
        .padding(16)
    }

    private func phaseTrack(_ run: SupervisedWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEQUENCE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                phaseChip("Plan", reached: reached(.planning, in: run), current: run.phase == .planning)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                phaseChip("Review", reached: reached(.reviewingPlan, in: run), current: run.phase == .reviewingPlan)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                phaseChip("Approve", reached: reached(.awaitingImplementationApproval, in: run), current: run.phase == .awaitingImplementationApproval)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                phaseChip("Implement", reached: reached(.implementing, in: run), current: run.phase == .implementing)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                phaseChip("Verify", reached: reached(.verifying, in: run), current: run.phase == .verifying)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                phaseChip("Complete", reached: reached(.awaitingCompletionApproval, in: run), current: run.phase == .awaitingCompletionApproval)
            }
        }
    }

    private func phaseChip(_ label: String, reached: Bool, current: Bool) -> some View {
        Text(label)
            .font(.system(size: 9, weight: current ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(current ? Color.accentColor : (reached ? Color.primary : Color.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(current ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("\(label), \(current ? "current" : (reached ? "reached" : "not reached"))")
    }

    private func checkpoint(_ run: SupervisedWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT CHECKPOINT")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(checkpointTitle(run.phase))
                .font(.system(size: 14, weight: .semibold))
            Text(checkpointDetail(run.phase))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func participants(_ run: SupervisedWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PARTICIPANTS")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                participant("Lead", run.lead)
                participant("Reviewer", run.reviewer)
                participant("Verifier", run.verifier)
            }
        }
    }

    private func participant(_ role: String, _ participant: SupervisedWorkflowParticipant) -> some View {
        Button {
            model.focusWorkflowParticipant(participant)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(participant.name)
                    .font(.system(size: 11, weight: .medium))
                Text(participant.kind.label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(model.pane(for: participant) == nil)
        .accessibilityHint("Focus this workflow participant in the Grid")
    }

    @ViewBuilder
    private func artifacts(_ run: SupervisedWorkflowRun) -> some View {
        if !run.artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("CAPTURED ARTIFACTS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                ForEach(run.artifacts) { artifact in
                    DisclosureGroup {
                        ScrollView(.horizontal) {
                            Text(artifact.text)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .frame(maxHeight: 180)
                    } label: {
                        HStack {
                            Text(artifact.kind.label)
                            Spacer()
                            Text("\(artifact.text.utf8.count) bytes")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func history(_ run: SupervisedWorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("HUMAN-AUTHORIZED HISTORY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(run.transitions) { transition in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(phaseColor(transition.to))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transition.to.label)
                            .font(.system(size: 10, weight: .medium))
                        if let detail = transition.detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Text(transition.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func footer(_ run: SupervisedWorkflowRun) -> some View {
        HStack {
            if !run.phase.isTerminal {
                Button("End Workflow…", role: .destructive) { model.interruptSupervisedWorkflow() }
            }
            Spacer()
            switch run.phase {
            case .planning:
                Button("Capture Plan and Review…") { model.sendWorkflowPlanForReview() }
                    .keyboardShortcut(.defaultAction)
            case .reviewingPlan:
                Button("Capture Review…") { model.captureWorkflowPlanReview() }
                    .keyboardShortcut(.defaultAction)
            case .awaitingImplementationApproval:
                Button("Review and Approve Implementation…") { model.approveWorkflowImplementation() }
                    .keyboardShortcut(.defaultAction)
            case .implementing:
                Button("Capture Changes and Verify…") { model.sendWorkflowImplementationForVerification() }
                    .keyboardShortcut(.defaultAction)
            case .verifying:
                Button("Capture Verification…") { model.captureWorkflowVerification() }
                    .keyboardShortcut(.defaultAction)
            case .awaitingCompletionApproval:
                Button("Review and Mark Complete…") { model.completeSupervisedWorkflow() }
                    .keyboardShortcut(.defaultAction)
            case .completed, .interrupted:
                Button("Close") { model.supervisedWorkflowPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func reached(_ phase: SupervisedWorkflowPhase, in run: SupervisedWorkflowRun) -> Bool {
        run.transitions.contains { $0.to == phase }
    }

    private func phaseColor(_ phase: SupervisedWorkflowPhase) -> Color {
        switch phase {
        case .awaitingImplementationApproval, .awaitingCompletionApproval: .orange
        case .completed: .green
        case .interrupted: .red
        default: .accentColor
        }
    }

    private func checkpointTitle(_ phase: SupervisedWorkflowPhase) -> String {
        switch phase {
        case .planning: "Wait for the lead's plan"
        case .reviewingPlan: "Wait for the independent plan review"
        case .awaitingImplementationApproval: "You decide whether implementation starts"
        case .implementing: "Wait for implementation and local checks"
        case .verifying: "Wait for independent verification"
        case .awaitingCompletionApproval: "You decide whether the workflow is complete"
        case .completed: "Workflow completed"
        case .interrupted: "Workflow interrupted"
        }
    }

    private func checkpointDetail(_ phase: SupervisedWorkflowPhase) -> String {
        switch phase {
        case .planning:
            "Inspect the lead pane. When its plan is ready, capture and edit exactly what the reviewer will receive."
        case .reviewingPlan:
            "Inspect the reviewer pane. Capturing its answer records it locally but does not send anything to the lead."
        case .awaitingImplementationApproval:
            "The plan and independent review are preserved below. Review the exact combined instruction before granting write work."
        case .implementing:
            "Inspect the lead's work. The next action captures the current Git changes into an editable verification request."
        case .verifying:
            "Inspect the verifier pane. Its prose is evidence for you to assess, not an automatic success signal."
        case .awaitingCompletionApproval:
            "Review the saved verification below. Only you can mark the sequence complete."
        case .completed:
            "All checkpoints were explicitly authorized by a person."
        case .interrupted:
            "Sequence tracking ended without declaring the work complete."
        }
    }
}
