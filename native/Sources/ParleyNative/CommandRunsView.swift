import ParleyCore
import SwiftUI

/// A persistent native notice; active session trust never hides in a menu.
struct CommandRunNotice: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var alwaysShow = false
    private var active: [ReviewedCommandRun] { model.commandRuns.filter { !$0.state.isTerminal || $0.workerStillRunning } }
    private var pendingCount: Int { active.filter { $0.state == .pending }.count }
    var body: some View {
        if alwaysShow || !active.isEmpty || !model.commandRunGrants.isEmpty || model.commandRunError != nil {
            HStack(spacing: 10) {
                Image(systemName: pendingCount > 0 ? "hand.raised.fill" : model.commandRunGrants.isEmpty ? "terminal" : "lock.open")
                    .foregroundStyle(pendingCount > 0 ? Color.accentColor : Color.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pendingCount > 0 ? "Approval required" : "Requested command runs")
                        .font(.system(size: 12, weight: pendingCount > 0 ? .semibold : .medium))
                    Text(model.commandRunError ?? "\(pendingCount) awaiting approval · \(active.filter { $0.state == .running || $0.workerStillRunning }.count) running · \(model.commandRunGrants.count) session grants")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !model.commandRunGrants.isEmpty {
                        Text("Session trust active · runs as you outside the agent boundary")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                Spacer()
                if pendingCount > 0 {
                    Button("Review \(pendingCount) pending") { openWindow(id: "main"); model.reviewCommandRuns() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Review runs and trust") { openWindow(id: "main"); model.reviewCommandRuns() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(pendingCount > 0 ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
        }
    }
}

struct CommandRunsView: View {
    @ObservedObject var model: AppModel
    private var selected: ReviewedCommandRun? {
        model.commandRuns.first { $0.id == model.selectedCommandRunID }
            ?? model.commandRuns.first { $0.state == .pending } ?? model.commandRuns.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Requested command runs").font(.title2)
                Spacer()
                Button("Done") { model.dismissCommandRunReview() }.keyboardShortcut(.cancelAction)
            }
            Text("Each approved run opens a new visible Shell pane in the requesting workspace. The pane stays open as an ordinary Shell afterwards.")
                .foregroundStyle(.secondary)
            if let error = model.commandRunError { Text(error).foregroundStyle(.red) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.commandRuns.prefix(32)) { run in
                            Button {
                                model.selectCommandRun(run)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(run.source.displayName) · \(run.state.rawValue)")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(run.command.display).lineLimit(2).font(.system(size: 11, design: .monospaced))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(selected?.id == run.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            }.buttonStyle(.plain)
                        }
                        if model.commandRuns.isEmpty { Text("No command requests in this app session.").foregroundStyle(.secondary) }
                    }
                }.frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
                ScrollView {
                    if let selected {
                        CommandRunPreview(model: model, run: selected).id(selected.id + selected.revision)
                    } else {
                        Text("An agent can request a run with parley request-run. Approval happens here.")
                            .foregroundStyle(.secondary).padding()
                    }
                }.frame(minWidth: 440, maxWidth: .infinity)
            }
            Divider()
            Text("Session trust").font(.headline)
            if model.commandRunGrants.isEmpty {
                Text("No auto-approval grants. Per-run approval is the default.").foregroundStyle(.secondary)
            } else {
                Text(ReviewedCommandRunCoordinator.trustDisclosure).font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.commandRunGrants) { grant in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(grant.sourceName) · generation \(grant.sourceGeneration)")
                                    Text(grant.command.display).font(.system(size: 11, design: .monospaced))
                                    Text(grant.command.folder).font(.system(size: 11)).textSelection(.enabled)
                                }
                                Spacer()
                                Button("Revoke") { model.revokeCommandRunGrant(grant) }
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }
        }.padding(20).frame(minWidth: 800, idealWidth: 900, minHeight: 650)
    }
}

private struct CommandRunPreview: View {
    @ObservedObject var model: AppModel
    let run: ReviewedCommandRun
    @State private var argv: String
    @State private var folder: String
    @State private var autoApprove = false
    @State private var error: String?
    init(model: AppModel, run: ReviewedCommandRun) {
        self.model = model
        self.run = run
        _argv = State(initialValue: run.command.display)
        _folder = State(initialValue: run.command.folder)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(run.source.displayName) · \(run.source.kind.label)").font(.headline)
            Text("Workspace: \(run.source.workspaceName ?? run.source.workspaceID)\nRequest: \(run.id)")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(ReviewedCommandRunCoordinator.trustDisclosure).font(.system(size: 12))
            Text("Exact arguments (JSON array; first item is an absolute executable)")
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: $argv).font(.system(size: 12, design: .monospaced))
                .frame(height: 90).border(Color.secondary.opacity(0.3))
                .disabled(run.state != .pending)
                .accessibilityLabel("Approved executable and literal argument array")
            TextField("Working folder", text: $folder).textFieldStyle(.roundedBorder)
                .disabled(run.state != .pending)
            Text("Noninteractive run: stdin is closed and stdout/stderr are captured through pipes. Each captured stream is limited to 30 KB; truncation is reported. The Shell becomes interactive after the command exits. Cancel stops the owned command process group; detached children may continue.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if run.state == .pending {
                Toggle("Auto-approve this command for this session", isOn: $autoApprove)
                if autoApprove {
                    Text("Trust applies to this exact argv, canonical folder and requesting pane generation, including code changed between runs. It ends on restart, move, folder or policy change, revocation, Stop Everything or quit.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Reject") { model.rejectCommandRun(run) }
                    Spacer()
                    Button(autoApprove ? "Run and grant session trust" : "Run once in new Shell") {
                        do {
                            guard let data = argv.data(using: .utf8), data.count <= 100_000 else {
                                throw ReviewedCommandRunError.invalid("The argument preview is too large.")
                            }
                            let arguments = try JSONDecoder().decode([String].self, from: data)
                            try model.approveCommandRun(run, argv: arguments, folder: folder, autoApprove: autoApprove)
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                }
            } else {
                Text(run.detail ?? run.state.rawValue).foregroundStyle(.secondary)
                if !run.state.isTerminal {
                    Button(run.cancellationRequested ? "Cancellation requested" : "Cancel run") { model.cancelCommandRun(run) }
                        .disabled(run.cancellationRequested)
                }
                if run.workerStillRunning && run.state.isTerminal,
                   let shell = model.panes.first(where: { $0.id == run.shellPaneID }) {
                    Text("The command worker has not exited. Its process may still be running.").foregroundStyle(.secondary)
                    Button("Close Shell…", role: .destructive) { model.close(shell) }
                }
                if let result = run.result {
                    Text(result.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.padding(12)
    }
}
