import ParleyCore
import SwiftUI

struct TeamSessionNotice: View {
    @ObservedObject var model: AppModel
    private var pending: [TeamSession] { model.teamSessions.filter { $0.state == .pending } }
    private var active: [TeamSession] { model.teamSessions.filter { $0.state == .active } }

    var body: some View {
        if !pending.isEmpty || !active.isEmpty || model.teamSessionError != nil {
            HStack(spacing: 10) {
                Image(systemName: pending.isEmpty ? "person.3" : "hand.raised.fill")
                    .foregroundStyle(pending.isEmpty ? Color.primary : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.isEmpty ? "Team sessions" : "Team session approval required")
                        .font(.system(size: 12, weight: pending.isEmpty ? .medium : .semibold))
                    Text(model.teamSessionError
                        ?? "\(pending.count) awaiting approval · \(active.count) active · \(active.reduce(0) { $0 + $1.members.count }) panes created by sessions")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if pending.isEmpty {
                    Button("Show sessions") { model.reviewTeamSessions() }.controlSize(.small)
                } else {
                    Button("Review \(pending.count) pending") { model.reviewTeamSessions() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(pending.isEmpty ? Color.secondary.opacity(0.05) : Color.accentColor.opacity(0.1))
        }
    }
}

struct TeamSessionsView: View {
    @ObservedObject var model: AppModel
    private var selected: TeamSession? {
        model.teamSessions.first { $0.id == model.selectedTeamSessionID }
            ?? model.teamSessions.first { $0.state == .pending }
            ?? model.teamSessions.first { $0.state == .active }
            ?? model.teamSessions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Team sessions").font(.title2)
                Spacer()
                Button("Done") { model.dismissTeamSessionReview() }.keyboardShortcut(.cancelAction)
            }
            Text("A lead pane proposes one objective, folder and team size. Approval lets that pane create up to the pane limit of new agent panes in its workspace without another click per pane. Every new pane is an ordinary vendor session with its own permission prompts.")
                .foregroundStyle(.secondary)
            if let error = model.teamSessionError { Text(error).foregroundStyle(.red) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.teamSessions.prefix(32)) { session in
                            Button {
                                model.selectTeamSession(session)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(session.leadName) · \(session.state.label)")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(session.objective).lineLimit(2).font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(selected?.id == session.id ? Color.accentColor.opacity(0.12) : Color.clear)
                            }.buttonStyle(.plain)
                        }
                        if model.teamSessions.isEmpty {
                            Text("No team session requests in this app session.").foregroundStyle(.secondary)
                        }
                    }
                }.frame(minWidth: 200, idealWidth: 240, maxWidth: 300, maxHeight: .infinity)
                ScrollView {
                    if let selected {
                        if selected.state == .pending {
                            TeamSessionApproval(model: model, session: selected).id(selected.id + selected.revision)
                        } else {
                            TeamSessionDetail(model: model, session: selected)
                        }
                    } else {
                        Text("An agent can request a team with parley team request. Approval happens here.")
                            .foregroundStyle(.secondary).padding()
                    }
                }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(20).frame(minWidth: 880, idealWidth: 980, minHeight: 660)
    }
}

private struct TeamSessionApproval: View {
    @ObservedObject var model: AppModel
    let session: TeamSession
    @State private var objective: String
    @State private var folder: String
    @State private var vendors: Set<PaneKind>
    @State private var profileID: String
    @State private var paneLimit: Int
    @State private var hours: Int
    @State private var error: String?
    private let templateNote: String?

    init(model: AppModel, session: TeamSession) {
        self.model = model
        self.session = session
        _objective = State(initialValue: session.objective)
        _folder = State(initialValue: session.folder)
        var initialVendors = Set(session.allowedVendors)
        var initialLimit = session.paneLimit
        var note: String?
        if let name = session.proposal.templateName {
            if let template = model.teamTemplates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let leaves = template.root.leaves.filter(\.kind.isAgent)
                if !leaves.isEmpty {
                    initialVendors = Set(leaves.map(\.kind))
                    initialLimit = min(max(leaves.count, 1), TeamSessionProposal.maximumPaneLimit)
                }
                note = "Prefilled from the portable template “\(template.name)”: \(leaves.map(\.kind.label).joined(separator: ", ")). Templates never carry folders; the folder below comes from this approval."
            } else {
                note = "The lead named a template “\(name)” that does not exist here. Nothing was prefilled from it."
            }
        }
        _vendors = State(initialValue: initialVendors)
        _paneLimit = State(initialValue: initialLimit)
        _hours = State(initialValue: session.proposal.hours)
        let profiles = model.permissionProfiles
        _profileID = State(initialValue: profiles.contains(where: { $0.id == "default" }) ? "default" : (profiles.first?.id ?? "default"))
        templateNote = note
    }

    private func vendorBinding(_ kind: PaneKind) -> Binding<Bool> {
        Binding(get: { vendors.contains(kind) }, set: { on in if on { vendors.insert(kind) } else { vendors.remove(kind) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(session.leadName) · \(session.source.kind.label)").font(.headline)
            Text("Workspace: \(session.source.workspaceName ?? session.source.workspaceID)\nRequest: \(session.id)\nRequested: \(session.proposal.paneLimit) pane\(session.proposal.paneLimit == 1 ? "" : "s") for \(session.proposal.hours) hour\(session.proposal.hours == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(TeamSessionDisclosure.approval).font(.system(size: 12))
            if let templateNote {
                Text(templateNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Objective (edit freely; the lead receives the approved text)")
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: $objective).font(.system(size: 12))
                .frame(height: 90).border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Approved objective")
            TextField("Working folder (inside the lead's working folder)", text: $folder).textFieldStyle(.roundedBorder)
            Text("Allowed vendors").font(.system(size: 11, weight: .medium))
            HStack(spacing: 14) {
                ForEach(PaneKind.allCases.filter(\.isAgent), id: \.self) { kind in
                    Toggle(kind.label, isOn: vendorBinding(kind))
                }
            }
            Picker("Permission profile for new panes", selection: $profileID) {
                ForEach(model.permissionProfiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            if let profile = model.permissionProfiles.first(where: { $0.id == profileID }) {
                Text(profile.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Stepper("Pane limit: \(paneLimit) (counts every pane the session creates, closed ones included)", value: $paneLimit, in: 1...TeamSessionProposal.maximumPaneLimit)
            Stepper("Provisioning deadline: \(hours) hour\(hours == 1 ? "" : "s") from approval (at most \(TeamSessionProposal.maximumHours))", value: $hours, in: 1...TeamSessionProposal.maximumHours)
            Text(TeamSessionDisclosure.deadline).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(TeamSessionDisclosure.stop + " " + TeamSessionDisclosure.expiry)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("After approval this sheet stays open as the session's monitoring surface; panes are created while it is open.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Reject") { model.rejectTeamSession(session) }
                Spacer()
                Button("Approve team session") {
                    do {
                        try model.approveTeamSession(session, objective: objective, folder: folder,
                            allowedVendors: PaneKind.allCases.filter { vendors.contains($0) }, permissionProfileID: profileID,
                            paneLimit: paneLimit, hours: hours)
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(12)
    }
}

private struct TeamSessionDetail: View {
    @ObservedObject var model: AppModel
    let session: TeamSession

    private var participantIDs: Set<String> { Set(session.members.map(\.paneID) + [session.source.id]) }
    private var work: [RelayHandoff] {
        Array(model.handoffs
            .filter { participantIDs.contains($0.sourcePaneID) || participantIDs.contains($0.targetPaneID) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(12))
    }
    private var decisions: [String] {
        var items: [String] = []
        for run in model.commandRuns where run.state == .pending && participantIDs.contains(run.source.id) {
            items.append("Command run requested by \(run.source.displayName): \(run.command.display)")
        }
        for handoff in model.handoffs where handoff.attention != nil
            && (participantIDs.contains(handoff.sourcePaneID) || participantIDs.contains(handoff.targetPaneID)) {
            items.append("\(handoff.kind.label) from \(handoff.sourceName) to \(handoff.targetName) needs your review")
        }
        return items
    }

    private static func remaining(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min left" : "\(minutes) min left"
    }

    private func liveState(for member: TeamSessionMember) -> String {
        guard let pane = model.panes.first(where: { $0.id == member.paneID }) else { return "closed" }
        guard member.owns(pane) else { return "restarted by you; no longer team-owned" }
        if pane.isDead { return "exited" }
        let moved = pane.workspaceID != member.workspaceID ? ", moved to another workspace" : ""
        return (pane.isStarted ? "running" : "stopped") + moved
    }

    private var ownedRunning: [TeamSessionMember] { session.ownedRunningMembers(in: model.panes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.objective).font(.headline).textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text([
                    session.state.label,
                    session.remainingTime.map { Self.remaining($0) + " to provision" },
                    "\(session.members.count) of \(session.paneLimit) pane\(session.paneLimit == 1 ? "" : "s") created",
                    session.deadline.map { "provisioning deadline \($0.formatted(date: .abbreviated, time: .shortened))" },
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
            }
            Text(TeamSessionDisclosure.deadline).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Folder: \(session.folder)\nVendors: \(session.allowedVendors.map(\.label).joined(separator: ", "))\nPermission profile: \(session.permissionProfileID.flatMap { id in model.permissionProfiles.first { $0.id == id }?.name } ?? session.permissionProfileID ?? "—")\nSession: \(session.id)")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            if let detail = session.detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }

            Text("Participants").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text("\(session.leadName) · \(session.source.kind.label) · lead")
                    Spacer()
                    Text("Person-created pane; requested this session").foregroundStyle(.secondary)
                }.font(.system(size: 11))
                ForEach(session.members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top) {
                            Text("\(member.name) · \(member.kind.label)\(member.role.map { " · @\($0)" } ?? "") · \(liveState(for: member))")
                            Spacer()
                            Text("Created by \(session.leadName) under this session's grant at \(member.createdAt.formatted(date: .omitted, time: .shortened)) · generation \(member.launchGeneration)")
                                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                        if let warning = member.warning {
                            Text(warning).foregroundStyle(.orange)
                        }
                    }.font(.system(size: 11))
                }
                if session.members.isEmpty { Text("No panes created yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }

            Text("Work").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(work) { handoff in
                    Text("\(handoff.kind.label): \(handoff.sourceName) → \(handoff.targetName) · \(handoff.state.rawValue)")
                        .font(.system(size: 11))
                }
                if work.isEmpty { Text("No handoffs between participants yet.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }

            Text("Decisions requiring you").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(decisions, id: \.self) { item in Text(item).font(.system(size: 11)) }
                if decisions.isEmpty { Text("None. Vendor permission prompts appear inside each pane.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }

            if let outcome = session.stopOutcome {
                Text("Last stop attempt: \(outcome)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if session.state == .active || !ownedRunning.isEmpty {
                Divider()
                Text(TeamSessionDisclosure.stop).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    if session.state == .active {
                        Button("Stop session…", role: .destructive) { model.stopTeamSession(session) }
                    }
                    if session.state != .active, !ownedRunning.isEmpty {
                        Button("Stop team panes… (\(ownedRunning.count) still running)", role: .destructive) { model.stopTeamPanes(session) }
                    }
                }
                if session.state != .active {
                    Text("Provisioning authority has ended; this only stops panes this session created and still owns.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.padding(12)
    }
}
