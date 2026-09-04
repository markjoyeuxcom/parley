import AppKit
import ParleyCore
import SwiftUI

struct PermissionProfilePickerView: View {
    @ObservedObject var model: AppModel
    let request: PanePermissionRequest

    @State private var selectedProfileID: String
    @State private var approvedRoots: [String]
    @State private var editingProfile: PermissionProfileDefinition?

    init(model: AppModel, request: PanePermissionRequest) {
        self.model = model
        self.request = request
        let selected = model.defaultPermissionProfileID(for: request)
        _selectedProfileID = State(initialValue: selected)
        let restoredRoots = request.existingSelection?.profileID == selected
            ? request.existingSelection?.approvedRoots
            : nil
        var initialRoots = restoredRoots ?? [request.folder]
        let paneRoot = URL(fileURLWithPath: request.folder).resolvingSymlinksInPath().standardizedFileURL.path
        if !initialRoots.contains(where: {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == paneRoot
        }) {
            initialRoots.insert(request.folder, at: 0)
        }
        _approvedRoots = State(initialValue: initialRoots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(request.isFolderAccessReview
                    ? "Folder Access for \(request.kind.label)"
                    : "Permissions for \(request.kind.label)")
                    .font(.title2.weight(.semibold))
                Text(request.isFolderAccessReview
                    ? "Review the exact folders this pane receives at launch. Applying a change restarts the vendor session; its working folder does not change."
                    : "Choose what this pane should be prepared to do. The vendor CLI still owns every confirmation it cannot express at launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let resumeDetail = request.resumeDetail {
                    Text(resumeDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileChoice
                    if let profile = selectedProfile {
                        capabilitySummary(profile)
                        rootScope(profile)
                        enforcementSummary(profile)
                    }
                    hardBoundary
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Cancel") { model.cancelPermissionProfileSelection() }
                    .keyboardShortcut(.cancelAction)
                if request.isFolderAccessReview, !hasChanges {
                    Text("No access changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(request.actionLabel) {
                    model.applyPermissionProfile(
                        to: request,
                        profileID: selectedProfileID,
                        approvedRoots: approvedRoots
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(16)
        }
        .frame(width: 610, height: 660)
        .interactiveDismissDisabled()
        .sheet(item: $editingProfile) { profile in
            CustomPermissionProfileEditorView(
                profile: profile,
                onCancel: { editingProfile = nil },
                onSave: { updated in
                    do {
                        try model.saveCustomPermissionProfile(updated)
                        selectedProfileID = updated.id
                        editingProfile = nil
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            )
        }
    }

    private var profileChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROFILE")
                .permissionSectionLabel()
            Picker("Profile", selection: $selectedProfileID) {
                ForEach(model.permissionProfiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            if let profile = selectedProfile {
                Text(profile.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(profile.defaultLifetime == .session ? "This choice lasts for this pane session." : "This profile becomes the default for new \(request.kind.label) panes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if profile.isBuiltIn {
                        Button("Clone as Custom…") { clone(profile) }
                    } else {
                        Button("Edit Custom…") { editingProfile = profile }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private func capabilitySummary(_ profile: PermissionProfileDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAPABILITY SUMMARY")
                .permissionSectionLabel()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                capabilityRow("Read project", rule: profile.rule(for: .projectRead))
                capabilityRow("Change project files", rule: profile.rule(for: .projectWrite))
                capabilityRow("Run project tools", rule: profile.rule(for: .projectToolExecution))
                capabilityRow("Use network", rule: profile.rule(for: .networkAccess))
                capabilityRow("Access files outside roots", rule: profile.rule(for: .externalFileAccess))
            }
            .font(.callout)
        }
    }

    private func capabilityRow(_ name: String, rule: PermissionRule) -> some View {
        GridRow {
            Text(name)
            Text(rule.permissionLabel)
                .fontWeight(.medium)
                .foregroundStyle(rule.permissionColor)
        }
    }

    @ViewBuilder
    private func rootScope(_ profile: PermissionProfileDefinition) -> some View {
        let projection = accessProjection(for: profile)
        let attachedAlternatives = projection.workspaceFolders.filter { !$0.isPaneFolder }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FOLDER ACCESS")
                    .permissionSectionLabel()
                Spacer()
                if profile.rootMode == .exactApprovedRoots {
                    Button("Add Other Folder…", action: addRoot)
                        .controlSize(.small)
                }
            }

            folderAccessLabel(
                request.folder,
                badge: "WORKING FOLDER",
                checked: true
            )

            if !attachedAlternatives.isEmpty {
                Text("ATTACHED TO \(request.workspaceName.uppercased())")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                ForEach(attachedAlternatives) { option in
                    Toggle(isOn: approvedRootBinding(option.path)) {
                        folderAccessLabel(
                            option.path,
                            badge: option.isApproved && profile.rootMode == .exactApprovedRoots ? "APPROVED" : nil,
                            checked: option.isApproved && profile.rootMode == .exactApprovedRoots
                        )
                    }
                    .toggleStyle(.checkbox)
                    .disabled(profile.rootMode != .exactApprovedRoots)
                }
                if profile.rootMode != .exactApprovedRoots {
                    Text("Choose Workspace folders or Broad workspace above to grant additional attached folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No other folders are attached to this workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if profile.rootMode == .exactApprovedRoots, !projection.otherApprovedRoots.isEmpty {
                Text("OTHER REVIEWED ROOTS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                ForEach(projection.otherApprovedRoots, id: \.self) { root in
                    HStack(spacing: 8) {
                        folderAccessLabel(root, badge: nil, checked: true)
                        Spacer(minLength: 8)
                        Button("Remove") {
                            approvedRoots.removeAll { canonical($0) == canonical(root) }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }

            Text(profile.rootMode == .paneFolder
                ? "This profile is limited to the pane's working folder. Workspace attachments remain metadata only."
                : "Only checked or manually reviewed roots are passed to the vendor CLI. Attaching another folder later does not grant it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderAccessLabel(_ root: String, badge: String?, checked: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(WorkspaceFolderIdentity.displayName(for: root))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    }
                }
                Text((WorkspaceFolderIdentity.normalized(root) as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func enforcementSummary(_ profile: PermissionProfileDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VENDOR ENFORCEMENT")
                .permissionSectionLabel()
            if let effectiveProfile {
                let plan = PermissionProfileAdapter.launchPlan(for: request.kind, profile: effectiveProfile)
                HStack(spacing: 8) {
                    Text(plan.enforcement.label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(plan.enforcement == .guidanceOnly ? Color.orange : Color.accentColor)
                    Text(plan.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose existing approved folders before starting the pane.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var hardBoundary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ALWAYS OUTSIDE THE PROFILE")
                .permissionSectionLabel()
            Text("No profile grants access to Parley control files, credentials or keychains, permission-bypass flags, privilege escalation, destructive host operations, Git pushes, deployments or infrastructure mutation. Vendor prompts remain explicit where the operating system cannot enforce the intent directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedProfile: PermissionProfileDefinition? {
        model.permissionProfiles.first(where: { $0.id == selectedProfileID })
    }

    private var effectiveProfile: EffectivePermissionProfile? {
        guard let profile = selectedProfile else { return nil }
        return try? PermissionProfileResolver.resolve(
            definition: profile,
            paneFolder: request.folder,
            approvedRoots: profile.rootMode == .exactApprovedRoots ? approvedRoots : []
        )
    }

    private var canContinue: Bool {
        guard let effectiveProfile else { return false }
        guard effectiveProfile.approvedRoots.contains(canonical(request.folder)) else { return false }
        return !request.isFolderAccessReview || hasChanges
    }

    private var hasChanges: Bool {
        guard let effectiveProfile else { return false }
        return effectiveProfile.selection != request.existingSelection
    }

    private func accessProjection(for profile: PermissionProfileDefinition) -> WorkspaceFolderAccessSnapshot {
        WorkspaceFolderAccessProjection.project(
            paneFolder: request.folder,
            workspaceFolders: request.workspaceFolders,
            approvedRoots: profile.rootMode == .exactApprovedRoots ? approvedRoots : [request.folder]
        )
    }

    private func approvedRootBinding(_ root: String) -> Binding<Bool> {
        Binding(
            get: { approvedRoots.contains { canonical($0) == canonical(root) } },
            set: { approved in
                if approved {
                    if !approvedRoots.contains(where: { canonical($0) == canonical(root) }) {
                        approvedRoots.append(WorkspaceFolderIdentity.normalized(root))
                    }
                } else {
                    approvedRoots.removeAll { canonical($0) == canonical(root) }
                }
            }
        )
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.title = "Add an exact approved root"
        panel.prompt = "Add Root"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: request.folder)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if !approvedRoots.contains(where: { canonical($0) == path }) {
                approvedRoots.append(path)
            }
        }
    }

    private func clone(_ profile: PermissionProfileDefinition) {
        let alert = NSAlert()
        alert.messageText = "Clone \(profile.name)"
        alert.informativeText = "The built-in stays unchanged. The clone can have its own capability decisions, root mode and lifetime."
        let field = NSTextField(string: "\(profile.name) custom")
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let clone = try model.clonePermissionProfile(profile, name: field.stringValue)
            selectedProfileID = clone.id
            editingProfile = clone
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private struct CustomPermissionProfileEditorView: View {
    let profile: PermissionProfileDefinition
    let onCancel: () -> Void
    let onSave: (PermissionProfileDefinition) -> Void

    @State private var name: String
    @State private var summary: String
    @State private var rootMode: PermissionRootMode
    @State private var lifetime: PermissionProfileLifetime
    @State private var rules: [PermissionCapability: PermissionRule]

    init(
        profile: PermissionProfileDefinition,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PermissionProfileDefinition) -> Void
    ) {
        self.profile = profile
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _summary = State(initialValue: profile.summary)
        _rootMode = State(initialValue: profile.rootMode)
        _lifetime = State(initialValue: profile.defaultLifetime)
        _rules = State(initialValue: profile.rules)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Edit Custom Permission Profile")
                    .font(.title2.weight(.semibold))
                Text("A custom profile changes vendor launch guidance. It cannot remove Parley’s hard boundary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Name", text: $name)
                    TextField("Summary", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                    HStack(spacing: 20) {
                        Picker("Root scope", selection: $rootMode) {
                            Text("Pane folder").tag(PermissionRootMode.paneFolder)
                            Text("Exact approved roots").tag(PermissionRootMode.exactApprovedRoots)
                        }
                        Picker("Lifetime", selection: $lifetime) {
                            Text("This session").tag(PermissionProfileLifetime.session)
                            Text("Remembered").tag(PermissionProfileLifetime.remembered)
                        }
                    }

                    Text("CAPABILITIES")
                        .permissionSectionLabel()
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        ForEach(PermissionCapability.allCases, id: \.self) { capability in
                            GridRow {
                                Text(capability.editorLabel)
                                Picker("", selection: ruleBinding(capability)) {
                                    ForEach(allowedRules(for: capability), id: \.self) { rule in
                                        Text(rule.permissionLabel).tag(rule)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 170)
                            }
                        }
                    }
                    .font(.callout)

                    Text("Git remote mutation, deployment and infrastructure mutation can require a decision or be denied; a reusable profile cannot pre-approve them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Profile") {
                    onSave(PermissionProfileDefinition(
                        id: profile.id,
                        name: name,
                        summary: summary,
                        isBuiltIn: false,
                        rootMode: rootMode,
                        defaultLifetime: lifetime,
                        rules: rules
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 610, height: 700)
        .interactiveDismissDisabled()
    }

    private func ruleBinding(_ capability: PermissionCapability) -> Binding<PermissionRule> {
        Binding(
            get: { rules[capability] ?? .deny },
            set: { rules[capability] = $0 }
        )
    }

    private func allowedRules(for capability: PermissionCapability) -> [PermissionRule] {
        switch capability {
        case .gitRemoteMutation, .deployment, .infrastructureMutation:
            [.requireApproval, .deny]
        default:
            PermissionRule.allCases
        }
    }
}

private extension PermissionRule {
    var permissionLabel: String {
        switch self {
        case .allow: "Allowed by profile"
        case .requireApproval: "Ask when needed"
        case .deny: "Not allowed"
        }
    }

    var permissionColor: Color {
        switch self {
        case .allow: .accentColor
        case .requireApproval: .secondary
        case .deny: .red
        }
    }
}

private extension PermissionCapability {
    var editorLabel: String {
        switch self {
        case .projectRead: "Read project"
        case .repositoryInspection: "Inspect repository"
        case .projectWrite: "Change project files"
        case .projectToolExecution: "Run project tools"
        case .localProcessExecution: "Run local processes"
        case .networkAccess: "Use network"
        case .externalFileAccess: "Access external files"
        case .gitRemoteMutation: "Mutate Git remotes"
        case .deployment: "Deploy"
        case .infrastructureMutation: "Change infrastructure"
        }
    }
}

private extension View {
    func permissionSectionLabel() -> some View {
        font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
