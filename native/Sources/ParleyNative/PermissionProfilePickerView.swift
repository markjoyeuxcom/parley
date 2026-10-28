import AppKit
import ParleyCore
import SwiftUI

struct PermissionProfilePickerView: View {
    @ObservedObject var model: AppModel
    let request: PanePermissionRequest

    @State private var selectedProfileID: String
    @State private var approvedRoots: [String]
    @State private var editingProfile: PermissionProfileDefinition?
    @State private var runInContainer: Bool
    /// Filled while the body evaluates: a class, so storing a fact publishes
    /// nothing, and one per open review.
    @State private var claudeSandboxCache = ClaudeSandboxFactCache()
    @State private var bypassVendorPermissions: Bool
    @State private var containerConfiguration: ContainerConfiguration?
    @State private var approvals: PermissionApprovalHandling
    @State private var codexConfigurationFact: String?
    /// Read once per open review, off the main actor.
    @State private var agyAllowFact: AgyParleyAllowFact?
    @Environment(\.openWindow) private var openWindow
    /// The vendor this review will launch. A creation review lets the person
    /// change it; every other action reviews an existing pane, whose vendor
    /// cannot change.
    @State private var kind: PaneKind
    /// The identity a creation review gives the new pane. The name starts
    /// as Parley's proposal (empty while the vendor label is free in the
    /// workspace, "Claude 2" once it is taken) and is the person's as soon
    /// as they type; the role starts empty.
    @State private var name: String
    @State private var proposedName: String
    @State private var role = ""
    private let existingContainer: ContainerConfiguration?

    init(model: AppModel, request: PanePermissionRequest) {
        self.model = model
        self.request = request
        let paneID: String?
        switch request.action {
        case .create: paneID = nil
        case let .restart(id), let .start(id), let .folderAccess(id): paneID = id
        case let .resume(id, _): paneID = id
        }
        let proposed: String
        if case .create = request.action {
            proposed = PaneNaming.defaultName(for: request.kind, among: model.activeWorkspacePanes) ?? ""
        } else {
            proposed = ""
        }
        _name = State(initialValue: proposed)
        _proposedName = State(initialValue: proposed)
        existingContainer = model.panes.first(where: { $0.id == paneID })?.containerConfiguration
        _runInContainer = State(initialValue: existingContainer != nil)
        _bypassVendorPermissions = State(initialValue: existingContainer?.bypassVendorPermissions ?? false)
        _containerConfiguration = State(initialValue: nil)
        _kind = State(initialValue: request.kind)
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
        _approvals = State(initialValue: request.existingSelection?.approvals ?? .person)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(request.isFolderAccessReview
                    ? "Folder Access for \(kind.label)"
                    : isCreation ? "New Agent Pane" : "Permissions for \(kind.label)")
                    .font(ChromeFont.sheetTitle)
                Text(request.isFolderAccessReview
                    ? "Review the exact folders this pane receives at launch. Applying a change restarts the vendor session; its working folder does not change."
                    : isCreation ? "Choose on the left. The right side is the exact review Parley attaches to the launch."
                    : "Review this pane’s folders and launch permissions. The right side is what the launch carries.")
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

            // Choices on the left; on the right, the review Parley attaches to
            // the launch, on its own paper so it reads as the record it is.
            // The text of that review is the same whichever column it sits in.
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        if isCreation { vendorSection }
                        if isCreation, kind.isAgent { identitySection }
                        runsSection
                        if !(runInContainer && bypassVendorPermissions) { profileChoice }
                        if let profile = selectedProfile {
                            if runInContainer && bypassVendorPermissions {
                                Text("The saved permission profile is not applied to this container. Turning bypass off restores the profile controls.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                capabilitySummary(profile)
                                approvalsSection
                            }
                            rootScope(profile)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let profile = selectedProfile {
                        VStack(alignment: .leading, spacing: 18) {
                            carriedSection(profile)
                            notCarriedSection(profile)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ChromeSurface.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(ChromeRule.hairline, lineWidth: 1)
                                .accessibilityHidden(true)
                        }
                    }
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
                if model.applyingPanePermissions { ProgressView().controlSize(.small) }
                Button(request.actionLabel) {
                    Task { await model.applyPermissionProfile(
                        to: effectiveRequest,
                        profileID: selectedProfileID,
                        approvedRoots: approvedRoots,
                        approvals: approvals,
                        containerConfiguration: runInContainer ? containerConfiguration : nil,
                        name: isCreation ? name : nil,
                        role: isCreation ? trimmedRole : nil
                    ) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(16)
        }
        // The middle scrolls, so the review may be shorter than its ideal on
        // a small display and wider or taller for larger text.
        .frame(minWidth: 760, idealWidth: 840, maxWidth: 1100, minHeight: 440, idealHeight: 680, maxHeight: .infinity)
        .disabled(model.applyingPanePermissions)
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
                Text(profile.defaultLifetime == .session ? "This choice lasts for this pane session." : "This profile becomes the default for new \(kind.label) panes.")
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

    private var isCreation: Bool {
        if case .create = request.action { true } else { false }
    }

    /// The request with the vendor the person chose. Same id, so the model
    /// still recognises it as the review it opened.
    private var effectiveRequest: PanePermissionRequest {
        var request = request
        request.kind = kind
        return request
    }

    /// The vendor, chosen here for a new pane. Changing it re-derives what
    /// depends on the vendor: the remembered profile default, an approvals
    /// choice Agy cannot honour, and a checked image, whose probe was for the
    /// previous vendor.
    private var vendorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VENDOR")
                .permissionSectionLabel()
            Picker("Vendor", selection: $kind) {
                ForEach(PaneKind.allCases.filter(\.isAgent), id: \.self) { vendor in
                    Text(vendor.label).tag(vendor)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, newKind in
                selectedProfileID = model.defaultPermissionProfileID(for: effectiveRequest)
                if newKind == .agy { approvals = .person }
                containerConfiguration = nil
                codexConfigurationFact = nil
                // A name the person has not touched follows the vendor; one
                // they typed is theirs whichever vendor they settle on.
                if name == proposedName {
                    let fresh = PaneNaming.defaultName(for: newKind, among: model.activeWorkspacePanes) ?? ""
                    name = fresh
                    proposedName = fresh
                }
            }
        }
    }

    /// Who this pane is to the person and to other agents. The vendor is
    /// the default name, which stops telling panes apart as soon as a
    /// workspace holds two of one vendor; the broker then refuses the bare
    /// vendor as a target, so the role is the address that always works.
    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IDENTITY")
                .permissionSectionLabel()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $name, prompt: Text(kind.label))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Pane name")
                        .accessibilityHint("Optional. Shown in the pane header and menus and used as a target name; the vendor name when empty")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Routing role")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Text("@")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Routing role", text: $role, prompt: Text("reviewer"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .autocorrectionDisabled()
                            .accessibilityLabel("Routing role")
                            .accessibilityHint("Optional. Lowercase letters, numbers and hyphens, unique in this workspace; agents address the pane as at-role")
                    }
                }
            }
            if let issue = identityIssue ?? identityNote {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(identityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trimmedRole: String { role.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Start Pane is held back by the identity, under the same rules the
    /// controller applies, so the review never proposes what it would refuse.
    private var identityIssue: String? {
        if let error = PaneNaming.nameValidationError(name) { return "Name: \(error)." }
        let role = trimmedRole
        guard !role.isEmpty else { return nil }
        if let error = PaneRoleRules.validationError(role) { return "Role: \(error)." }
        if model.activeWorkspacePanes.contains(where: { $0.role == role }) {
            return "The role @\(role) is already assigned in this workspace."
        }
        return nil
    }

    /// A name another pane here already has is allowed, as Rename allows
    /// it, but agents will then need the role or id; the person hears so
    /// before Start rather than from a refusal later.
    private var identityNote: String? {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty,
              let other = model.activeWorkspacePanes.first(where: { $0.displayName.caseInsensitiveCompare(typed) == .orderedSame }) else {
            return nil
        }
        return "Another pane here is already named \(other.displayName); agents will need this pane's role or id to tell them apart."
    }

    private var identityHint: String {
        let sameVendor = model.activeWorkspacePanes.filter { $0.kind == kind }.count
        if sameVendor > 0 {
            return "This workspace already has \(sameVendor) \(kind.label) pane\(sameVendor == 1 ? "" : "s"). “\(kind.label.lowercased())” alone reaches a pane only while it matches one pane besides the sender, so with several \(kind.label) panes agents need a role; give this pane one, and they address it as @\(trimmedRole.isEmpty ? "role" : trimmedRole)."
        }
        return "Optional. A role is a stable address for other agents, such as @reviewer; the name is what you see."
    }

    /// Where the pane's process runs. Every agent vendor has a container
    /// form; a Shell pane has none, and would see the fact rather than a
    /// control that does nothing.
    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RUNS")
                .permissionSectionLabel()
            if kind.isAgent {
                Picker("Runs", selection: $runInContainer) {
                    Text("On this machine").tag(false)
                    Text("In a container (experimental)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                ContainerLaunchOptionsView(model: model, vendor: kind, folder: request.folder, enabled: $runInContainer,
                    configuration: $containerConfiguration, existing: existingContainer, showsToggle: false,
                    onBypassChange: { bypassVendorPermissions = $0 })
            } else {
                Text("On this machine")
                    .font(.callout)
                Text("Shell panes run on this Mac as your account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line of the carried or not-carried lists: what, who keeps it and
    /// the fact behind it. A tag appears only where someone enforces the line.
    private struct ReviewLine: Identifiable {
        let title: String
        var tag: String? = nil
        var tagColor: Color = .accentColor
        let detail: String
        var id: String { title + detail }
    }

    private func reviewLines(_ lines: [ReviewLine]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(line.title)
                            .font(.callout.weight(.medium))
                        if let tag = line.tag {
                            Text(tag)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(line.tagColor)
                        }
                    }
                    Text(line.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var launchPlan: PermissionProfileLaunchPlan? {
        effectiveProfile.map { PermissionProfileAdapter.launchPlan(for: kind, profile: $0) }
    }

    private var displayFolder: String {
        (WorkspaceFolderIdentity.normalized(request.folder) as NSString).abbreviatingWithTildeInPath
    }

    /// What this launch passes to the vendor, or to Docker, and who keeps each
    /// rule. Every line is a fact of the launch plan or the reviewed container
    /// configuration, never a prediction of what the vendor will do.
    private func carriedSection(_ profile: PermissionProfileDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT IS CARRIED")
                .permissionSectionLabel()
            reviewLines(carriedLines(profile))
        }
    }

    private func carriedLines(_ profile: PermissionProfileDefinition) -> [ReviewLine] {
        let vendor = kind.label
        let enforcedByVendor = "ENFORCED BY \(vendor.uppercased())"
        var lines: [ReviewLine] = []
        if runInContainer {
            var mounted = "\(displayFolder) is mounted writable, with this pane's own relay endpoint; the protocol and shim files are read-only."
            if containerConfiguration?.gitAccess != nil {
                mounted += " The shared Git directory listed above is mounted writable too."
            }
            mounted += " Nothing else from this Mac is mounted."
            lines.append(ReviewLine(title: "Folders", tag: "ENFORCED BY DOCKER", detail: mounted))
        } else {
            let others = profile.rootMode == .exactApprovedRoots
                ? approvedRoots.filter { canonical($0) != canonical(request.folder) }
                : []
            let detail = others.isEmpty
                ? "\(displayFolder) only. The pane starts here, and no other folder is passed."
                : "\(displayFolder) and \(others.count == 1 ? "one other reviewed root" : "\(others.count) other reviewed roots"), each passed at launch."
            lines.append(ReviewLine(title: "Folders", tag: enforcedByVendor, detail: detail))
        }
        if runInContainer && bypassVendorPermissions {
            lines.append(ReviewLine(
                title: "Bypass vendor permissions",
                tag: "NOT ENFORCED", tagColor: .orange,
                detail: ContainerLaunchProjection.bypassDisclosure(for: kind)))
            return lines
        }
        guard let effectiveProfile, let plan = launchPlan else { return lines }
        var profileDetail = plan.mode
        if let execution = plan.execution, execution.carried { profileDetail += " " + execution.text }
        lines.append(ReviewLine(
            title: "Profile: \(profile.name)",
            tag: plan.enforcement == .guidanceOnly ? "GUIDANCE ONLY" : "\(plan.enforcement.label.uppercased()) BY \(vendor.uppercased())",
            tagColor: plan.enforcement == .guidanceOnly ? .orange : .accentColor,
            detail: profileDetail))
        lines.append(ReviewLine(
            title: approvals == .vendorReviewer ? "Approvals: \(vendor)'s reviewer" : "Approvals: you",
            tag: enforcedByVendor,
            detail: approvals == .vendorReviewer
                ? (plan.reviewer ?? approvalsCaption)
                : "\(vendor) asks you before it acts, as it normally would."))
        if let network = plan.network, network.carried {
            lines.append(ReviewLine(title: "Network", tag: enforcedByVendor, detail: network.text))
        }
        if ticketPolicy.requirement == .required {
            lines.append(ReviewLine(title: "Peer-attested requests", tag: "ENFORCED BY PARLEY",
                detail: "Every parley command from this pane must present a one-use ticket that Parley issued over its ticket socket to a process descended from this launch of the pane. A copied capability alone is refused, and so is a process left over from an earlier launch."))
        }
        switch kind {
        case .claude where !runInContainer && PermissionProfileAdapter.shellCommandRule(effectiveProfile) == .allow:
            lines.append(ReviewLine(title: "Parley's command", tag: "ALLOWED WITHOUT A PROMPT",
                detail: "This profile allows shell commands, so parley runs without a prompt. Every other command keeps Claude's prompt."))
        case .copilot:
            lines.append(ReviewLine(title: "Parley's command", tag: "ALLOWED WITHOUT A PROMPT",
                detail: "Copilot permits shell(parley) without a tool confirmation. Every other tool keeps Copilot's confirmation."))
        case .codex where !runInContainer:
            lines.append(ReviewLine(title: "Codex sandbox check", tag: "CHECKED AT START",
                detail: "Starting checks Codex's native tool sandbox and private-file rules first. Your existing Codex configuration is kept."))
        default:
            break
        }
        return lines
    }

    /// What this launch passes nowhere, so a reviewed intention is never read
    /// as an operating-system boundary.
    private func notCarriedSection(_ profile: PermissionProfileDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT IS NOT CARRIED")
                .permissionSectionLabel()
            reviewLines(notCarriedLines(profile))
        }
    }

    private var ticketPolicy: RelayTicketPolicy {
        RelayTicketPolicy.policy(kind: kind, inContainer: runInContainer, socketListening: model.ticketSocketListening,
            claudeSandbox: claudeSandboxCache.fact(kind: kind, folder: request.folder, inContainer: runInContainer),
            codexNetworkAllowed: kind == .codex && !runInContainer ? selectedProfile.map { $0.rule(for: .networkAccess) == .allow } : nil)
    }

    private func notCarriedLines(_ profile: PermissionProfileDefinition) -> [ReviewLine] {
        let vendor = kind.label
        var lines: [ReviewLine] = []
        if ticketPolicy.requirement != .required {
            lines.append(ReviewLine(title: "Peer attestation",
                detail: ticketPolicy.reason.prefix(1).uppercased() + ticketPolicy.reason.dropFirst()
                    + (ticketPolicy.requirement == .optional
                        ? ". A ticket is redeemed when one arrives and not demanded; requests are otherwise authenticated by the pane capability alone."
                        : ". Requests from this pane are authenticated by the pane capability alone, which any process running as you could read.")))
        }
        if runInContainer {
            if bypassVendorPermissions {
                lines.append(ReviewLine(title: "Profile: \(profile.name)",
                    detail: "Not applied inside this container. Turning bypass off restores the profile controls."))
                lines.append(ReviewLine(title: "Approvals",
                    detail: "\(vendor) asks no questions in this container, so the choice does not apply."))
            } else {
                lines.append(ReviewLine(title: "Operating-system enforcement",
                    detail: "The profile's rules are \(vendor)'s to keep inside the container. Parley asks for them at launch and shows what it asked. Docker's boundary is the mounts and user in this review, not the profile."))
                if let execution = launchPlan?.execution, !execution.carried {
                    lines.append(ReviewLine(title: "Execution rules", detail: execution.text))
                }
                if let network = launchPlan?.network, !network.carried {
                    lines.append(ReviewLine(title: "Network", detail: network.text))
                }
            }
            lines.append(ReviewLine(title: "Host command runs",
                detail: bypassVendorPermissions
                    ? "Container bypass does not authorize host command runs. A request-run from this pane still opens a Shell on this Mac only after your separate approval."
                    : "A request-run from this pane still opens a Shell on this Mac only after your separate approval; the container does not run it."))
            lines.append(ReviewLine(title: "This Mac",
                detail: "The Docker socket, your host vendor login and Parley's control files are not mounted. Parley cannot constrain what the Docker daemon itself does outside the container."))
        } else {
            lines.append(ReviewLine(title: "Operating-system enforcement",
                detail: "These rules are \(vendor)'s to keep. Parley asks for them at launch and shows you what it asked; it adds no sandbox of its own, and the pane runs as your account with \(vendor)'s permissions."))
            if let execution = launchPlan?.execution, !execution.carried {
                lines.append(ReviewLine(title: "Execution rules", detail: execution.text))
            }
            if let network = launchPlan?.network, !network.carried {
                lines.append(ReviewLine(title: "Network", detail: network.text))
            }
            lines.append(ReviewLine(title: "Always outside the profile",
                detail: "Parley control files, credentials and keychains, host permission bypass, privilege escalation, destructive host operations, Git pushes, deployments and infrastructure mutation. A profile cannot pre-approve these; \(vendor) decides and asks."))
            lines.append(ReviewLine(title: "Isolation from other panes",
                detail: "An unrestricted process running as your account can read local records and other panes' credentials. Attribution is not isolation; a reviewed container gives stronger separation."))
        }
        return lines
    }

    private var selectedProfile: PermissionProfileDefinition? {
        model.permissionProfiles.first(where: { $0.id == selectedProfileID })
    }

    private var effectiveProfile: EffectivePermissionProfile? {
        guard let profile = selectedProfile else { return nil }
        return try? PermissionProfileResolver.resolve(
            definition: profile,
            paneFolder: request.folder,
            approvedRoots: profile.rootMode == .exactApprovedRoots ? approvedRoots : [],
            approvals: approvals
        )
    }

    /// Who answers the vendor's prompts. A vendor's own automatic reviewer
    /// keeps its sandbox and rules and can still refuse; it is not a bypass,
    /// and Agy has none, so the picker is disabled there and says why.
    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPROVALS")
                .permissionSectionLabel()
            Picker("Approvals", selection: $approvals) {
                ForEach(PermissionApprovalHandling.allCases, id: \.self) { handling in
                    Text(handling.label).tag(handling)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(kind == .agy || (runInContainer && bypassVendorPermissions))
            Text(approvalsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .agy, !runInContainer {
                agyAllowSection
            }
            if kind == .codex, !runInContainer {
                Text(codexConfigurationFact ?? "Reading Codex's own configuration for this folder…")
                    .font(.caption)
                    .foregroundStyle(codexConfigurationFact?.contains("auto_review") == true ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .task(id: request.folder) {
                        codexConfigurationFact = await model.codexApprovalsReviewerFact(folder: request.folder)
                    }
            }
        }
    }

    /// Whether Agy's own settings allow Parley's command, read without
    /// changing them; the recipe and its reasons are in Help.
    private var agyAllowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agyAllowFact.map(AgyHostConfiguration.describe) ?? "Reading Agy's settings…")
                .font(.caption)
                .foregroundStyle(agyAllowFact.map(isAllowed) == true ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let fact = agyAllowFact, !isAllowed(fact) {
                HStack(spacing: 8) {
                    Button("Copy Allow Entry") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgyHostConfiguration.allowEntry, forType: .string)
                    }
                    .help("Copies \(AgyHostConfiguration.allowEntry) for permissions.allow in ~/.gemini/antigravity-cli/settings.json. Parley never edits that file.")
                    Button("Why This Form?") {
                        model.requestHelp(topicID: "command-runs")
                        openWindow(id: "help")
                    }
                    .buttonStyle(.link)
                }
                .controlSize(.small)
            }
        }
        .task(id: kind) {
            guard kind == .agy else { return }
            agyAllowFact = await Task.detached(priority: .userInitiated) {
                AgyHostConfiguration.parleyAllowFact()
            }.value
        }
    }

    private func isAllowed(_ fact: AgyParleyAllowFact) -> Bool {
        if case .allowed = fact { return true }
        return false
    }

    private var approvalsCaption: String {
        if runInContainer && bypassVendorPermissions {
            return "Container bypass answers nothing: the vendor asks no questions in that container, so this choice does not apply."
        }
        switch kind {
        case .claude:
            return "Vendor's reviewer means Claude's auto mode: its classifier approves routine actions and blocks irreversible, destructive or outward-aimed ones. Deny and ask rules from this profile still apply first. Not a bypass; Claude can still refuse or ask."
        case .codex:
            return "Vendor's reviewer means Codex auto review: a reviewer agent decides sandbox escalation requests inside the same sandbox. It grants no network or extra folders and can refuse. Not a bypass."
        case .copilot:
            return "Vendor's reviewer means Copilot assisted approval: its judge reviews tool permission requests. It needs Copilot's AUTO_APPROVAL feature flag; Copilot reports if that is off."
        case .agy:
            return "Agy has no automatic reviewer, only a skip-all-permissions flag Parley never passes on the host, so Agy asks before commands unless its own settings allow them."
        case .shell:
            return "Shell panes have no vendor prompts."
        }
    }

    private var canContinue: Bool {
        guard let effectiveProfile else { return false }
        if isCreation, identityIssue != nil { return false }
        if runInContainer && (containerConfiguration == nil || effectiveProfile.approvedRoots != [canonical(request.folder)]) { return false }
        guard effectiveProfile.approvedRoots.contains(canonical(request.folder)) else { return false }
        return !request.isFolderAccessReview || hasChanges
    }

    private var hasChanges: Bool {
        guard let effectiveProfile else { return false }
        return effectiveProfile.selection != request.existingSelection || runInContainer != (existingContainer != nil) || (runInContainer && containerConfiguration != existingContainer)
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
        .frame(minWidth: 610, idealWidth: 610, maxWidth: 900, minHeight: 440, idealHeight: 700, maxHeight: .infinity)
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
    /// The review's section labels share the chrome's one heading style.
    func permissionSectionLabel() -> some View {
        font(ChromeFont.heading)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
