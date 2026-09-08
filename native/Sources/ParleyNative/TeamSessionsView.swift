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
            Text("A requesting agent pane proposes one objective, folder and team size. Approval lets that pane create up to the pane limit of new agent panes in its workspace without another click per pane. Every new pane is an ordinary vendor session with its own permission prompts.")
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
                                    Text("\(session.requesterName) · \(session.state.label)")
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
    @State private var worktreeMode: WorktreeMode
    @State private var existingWorktreePath: String = ""
    @State private var worktreeBranch: String
    @State private var worktreeBase: String
    @State private var worktreePreview: ManagedWorktreeService.CreatePreview?
    @State private var worktreePreviewError: String?
    @State private var busy = false
    private let worktreeNote: String?

    enum WorktreeMode: String, CaseIterable, Identifiable {
        case none, existing, create
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Ordinary folder"
            case .existing: "Existing worktree"
            case .create: "New worktree"
            }
        }
    }

    init(model: AppModel, session: TeamSession) {
        self.model = model
        self.session = session
        _objective = State(initialValue: session.objective)
        _folder = State(initialValue: session.folder)
        _worktreeMode = State(initialValue: session.proposal.worktreeBranch == nil ? .none : .create)
        _worktreeBranch = State(initialValue: session.proposal.worktreeBranch ?? "")
        _worktreeBase = State(initialValue: session.proposal.worktreeBase ?? "HEAD")
        worktreeNote = session.proposal.worktreeBranch.map {
            "The requesting pane proposed a new worktree on branch “\($0)” from \(session.proposal.worktreeBase ?? "HEAD"). Nothing is created until you preview and approve it here."
        }
        _vendors = State(initialValue: Set(session.allowedVendors))
        _paneLimit = State(initialValue: session.paneLimit)
        _hours = State(initialValue: session.proposal.hours)
        let profiles = model.permissionProfiles
        _profileID = State(initialValue: profiles.contains(where: { $0.id == "default" }) ? "default" : (profiles.first?.id ?? "default"))
    }

    private func vendorBinding(_ kind: PaneKind) -> Binding<Bool> {
        Binding(get: { vendors.contains(kind) }, set: { on in if on { vendors.insert(kind) } else { vendors.remove(kind) } })
    }

    /// Linked worktrees of the repository containing the working folder, from
    /// the read-only discovery scan. The primary checkout is the folder itself.
    private var selectableWorktrees: [GitWorktreeRecord] {
        let canonical = GitWorktreeResolver.canonicalPath(folder)
        guard let repository = model.worktreeScan.repositories.first(where: { repository in
            repository.worktrees.contains { WorktreeCleanupPolicy.isNested(canonical, in: $0.path) }
        }) else { return [] }
        return repository.worktrees.filter { !$0.isPrimary && $0.pruneReason == nil }
    }

    private var worktreeChoice: AppModel.TeamWorktreeChoice? {
        switch worktreeMode {
        case .none: return .ordinaryFolder
        case .existing: return existingWorktreePath.isEmpty ? nil : .existing(path: existingWorktreePath)
        case .create:
            guard let preview = worktreePreview, preview.branch == worktreeBranch.trimmingCharacters(in: .whitespaces),
                  preview.baseRef == worktreeBase.trimmingCharacters(in: .whitespaces) else { return nil }
            return .create(preview: preview)
        }
    }

    private func previewWorktree() {
        let branch = worktreeBranch.trimmingCharacters(in: .whitespaces)
        let base = worktreeBase.trimmingCharacters(in: .whitespaces)
        let repository = folder
        worktreePreview = nil
        worktreePreviewError = nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let result = await model.previewManagedWorktree(repositoryFolder: repository, branch: branch, baseRef: base)
            // A preview answers exactly the inputs it was asked about; edits made
            // while Git was reading discard the answer instead of approving it.
            guard repository == folder, branch == worktreeBranch.trimmingCharacters(in: .whitespaces),
                  base == worktreeBase.trimmingCharacters(in: .whitespaces) else { return }
            switch result {
            case let .success(preview): worktreePreview = preview
            case let .failure(error): worktreePreviewError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var worktreeSection: some View {
        Text("Git worktree for this team").font(.system(size: 11, weight: .medium))
        if let worktreeNote { Text(worktreeNote).font(.system(size: 11)).foregroundStyle(.secondary) }
        Picker("Worktree", selection: $worktreeMode) {
            ForEach(WorktreeMode.allCases) { mode in Text(mode.label).tag(mode) }
        }.pickerStyle(.segmented).labelsHidden()
        switch worktreeMode {
        case .none:
            Text("Panes are created in the working folder above.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .existing:
            let candidates = selectableWorktrees
            if candidates.isEmpty {
                Text("Git discovery lists no linked worktree for this repository. Ordinary folders remain supported.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Picker("Existing worktree", selection: $existingWorktreePath) {
                    Text("Choose…").tag("")
                    ForEach(candidates) { tree in
                        Text("\(tree.shortIdentity) · \(tree.path)").tag(tree.path)
                    }
                }
                Text("Selecting an existing tree binds the team to exactly that folder. Parley records no ownership and no base for it, and never removes it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .create:
            HStack {
                TextField("Branch (new, e.g. feat/parser)", text: $worktreeBranch).textFieldStyle(.roundedBorder)
                    .onChange(of: worktreeBranch) { _, _ in worktreePreview = nil; worktreePreviewError = nil }
                TextField("Base ref (branch, tag or commit)", text: $worktreeBase).textFieldStyle(.roundedBorder)
                    .onChange(of: worktreeBase) { _, _ in worktreePreview = nil; worktreePreviewError = nil }
                Button("Preview") { previewWorktree() }.disabled(busy || worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty || worktreeBase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let preview = worktreePreview {
                Text("Will run: git worktree add -b \(preview.branch) \(preview.path) \(preview.baseCommit.prefix(12))\nRepository: \(preview.repositoryToplevel)\nBase \(preview.baseRef) resolves now to \(preview.baseCommit); creation is refused if it moves before you approve.\n\(preview.excludeEntryPresent ? ".worktrees/ is already in the repository's local exclude file." : "Parley appends one .worktrees/ line to .git/info/exclude (local, untracked).")")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text(ManagedWorktreeService.CreatePreview.executionNotice).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let worktreePreviewError {
                Text(worktreePreviewError).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                Text("Preview resolves the base commit and the exact folder before anything runs. The working folder above must be the repository whose .worktrees/ directory the requesting pane can see.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        Text(TeamSessionDisclosure.worktree).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(session.requesterName) · \(session.source.kind.label)").font(.headline)
            Text("Workspace: \(session.source.workspaceName ?? session.source.workspaceID)\nRequest: \(session.id)\nRequested: \(session.proposal.paneLimit) pane\(session.proposal.paneLimit == 1 ? "" : "s") for \(session.proposal.hours) hour\(session.proposal.hours == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(TeamSessionDisclosure.approval).font(.system(size: 12))
            Text("Objective (edit freely; the requesting pane receives the approved text)")
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: $objective).font(.system(size: 12))
                .frame(height: 90).border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Approved objective")
            TextField("Working folder (inside the requesting pane's working folder)", text: $folder).textFieldStyle(.roundedBorder)
                .onChange(of: folder) { _, _ in worktreePreview = nil; worktreePreviewError = nil; existingWorktreePath = "" }
            worktreeSection
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
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reject") { model.rejectTeamSession(session) }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(worktreeMode == .create ? "Create worktree and approve" : "Approve team session") {
                    guard let choice = worktreeChoice else { return }
                    busy = true
                    error = nil
                    Task { @MainActor in
                        defer { busy = false }
                        do {
                            try await model.approveTeamSession(session, objective: objective, folder: folder,
                                allowedVendors: PaneKind.allCases.filter { vendors.contains($0) }, permissionProfileID: profileID,
                                paneLimit: paneLimit, hours: hours, worktree: choice)
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(busy || worktreeChoice == nil)
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
        let pane = model.panes.first { $0.id == member.paneID }
        switch member.ownership(of: pane) {
        case .closed: return "closed"
        case .restartedByPerson: return "restarted by you; no longer team-owned"
        case .stopped: return "stopped" + (pane.map { $0.workspaceID != member.workspaceID } == true ? ", moved to another workspace" : "")
        case .owned:
            guard let pane else { return "closed" }
            if pane.isDead { return "exited" }
            let moved = pane.workspaceID != member.workspaceID ? ", moved to another workspace" : ""
            return (pane.isStarted ? "running" : "stopped") + moved
        }
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
            if let binding = session.worktree {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Worktree: \(binding.summary)").font(.system(size: 11, weight: .medium))
                    if let record = model.managedWorktree(atPath: binding.path) {
                        Text("Now: \(model.managedWorktreeSummary(record))").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("Parley no longer has a record of this worktree; it may have been removed.").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Text("The recorded base is the commit the tree was created from. It is not the tree's current HEAD, and nothing here says who changed a file.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.textSelection(.enabled)
            }
            if let detail = session.detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }

            Text("Participants").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text("\(session.requesterName) · \(session.source.kind.label) · requester")
                    Spacer()
                    Text("Person-created pane; requested this session. Members address it by its exact pane id; “lead” still means the workspace lead.").foregroundStyle(.secondary)
                }.font(.system(size: 11))
                ForEach(session.members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top) {
                            Text("\(member.name) · \(member.kind.label)\(member.role.map { " · @\($0)" } ?? "") · \(liveState(for: member))")
                            Spacer()
                            Text("Created by \(session.requesterName) under this session's grant at \(member.createdAt.formatted(date: .omitted, time: .shortened)) · generation \(member.launchGeneration)")
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
                Text("Last stop attempt (\(session.stopAttempts.last.map { $0.attemptedAt.formatted(date: .abbreviated, time: .shortened) + " " + (TimeZone.current.abbreviation() ?? "local") } ?? "")): \(outcome)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
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
