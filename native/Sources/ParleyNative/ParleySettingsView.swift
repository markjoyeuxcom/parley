import AppKit
import ParleyCore
import SwiftUI

struct ParleySettingsView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<ApplicationSettingsSection> {
        Binding(
            get: { model.selectedSettingsSection },
            set: { model.selectSettingsSection($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBanner(runtime: model.runtime)
            if model.runtime.visibleMarker != nil { Divider() }
            TabView(selection: selection) {
                GeneralSettingsView(model: model)
                    .tabItem {
                        Label(
                            ApplicationSettingsSection.general.title,
                            systemImage: ApplicationSettingsSection.general.systemImage
                        )
                    }
                    .tag(ApplicationSettingsSection.general)

                TerminalSettingsView(model: model)
                    .tabItem {
                        Label(
                            ApplicationSettingsSection.terminal.title,
                            systemImage: ApplicationSettingsSection.terminal.systemImage
                        )
                    }
                    .tag(ApplicationSettingsSection.terminal)

                VoiceSettingsView(voice: model.voice)
                    .tabItem { Label(ApplicationSettingsSection.voice.title, systemImage: ApplicationSettingsSection.voice.systemImage) }
                    .tag(ApplicationSettingsSection.voice)

                AppearanceSettingsView(model: model)
                .tabItem {
                    Label(
                        ApplicationSettingsSection.appearance.title,
                        systemImage: ApplicationSettingsSection.appearance.systemImage
                    )
                }
                .tag(ApplicationSettingsSection.appearance)

                NotificationSettingsView(model: model)
                    .tabItem {
                        Label(
                            ApplicationSettingsSection.notifications.title,
                            systemImage: ApplicationSettingsSection.notifications.systemImage
                        )
                    }
                    .tag(ApplicationSettingsSection.notifications)
            }
            .padding(.top, 8)
        }
        // Flexible, so larger text or a long section can grow the window
        // rather than clip; the minimum is the size it always had.
        .frame(minWidth: 680, idealWidth: 680, maxWidth: 1000, minHeight: 590, idealHeight: 590, maxHeight: .infinity)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Software updates") {
                if model.automaticUpdatesAvailable {
                    Toggle(
                        "Check for stable updates automatically",
                        isOn: Binding(
                            get: { model.automaticUpdateChecksEnabled },
                            set: { model.setAutomaticUpdateChecksEnabled($0) }
                        )
                    )
                    .help("Check the stable channel in the background; nothing installs without your confirmation")
                    HStack {
                        Text(model.automaticUpdateDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now…") { model.checkForStableAutomaticUpdate() }
                            .disabled(!model.automaticUpdateCanCheck)
                            .help("Check the stable channel for a newer Parley release now")
                            .accessibilityLabel("Check for updates now")
                    }
                } else {
                    Label("Automatic update channel unavailable", systemImage: "lock.shield")
                    Text(model.automaticUpdateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker(
                    "Manual release channel",
                    selection: Binding(
                        get: { model.releaseChannel },
                        set: { model.setReleaseChannel($0) }
                    )
                ) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .help("Which release channel manual update checks use")
                .accessibilityLabel("Manual release channel")

                Text(model.releaseChannel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Swift package builds") {
                Toggle(
                    "Enable SwiftPM compatibility for new agent panes",
                    isOn: Binding(
                        get: { model.swiftPMCompatibilityEnabled },
                        set: { model.setSwiftPMCompatibilityEnabled($0) }
                    )
                )
                .accessibilityHint("Off by default. Applies when an agent pane is next started or restarted.")
                Text(SwiftPMCompatibility.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Off by default. Vendor prompts may show the original command without the added flag. Restart an existing agent pane to apply a setting change; Parley does not restart it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local history") {
                Picker(
                    "Keep up to",
                    selection: Binding(
                        get: { model.historyRetentionPolicy.maximumRecords },
                        set: { model.setHistoryRetention(maximumRecords: $0) }
                    )
                ) {
                    ForEach(CollaborationHistoryRetentionPolicy.allowedMaximumRecords, id: \.self) { limit in
                        Text("\(limit) records").tag(limit)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.coreAvailable)
                .help("How many finished handoff and activity records Parley keeps on this Mac; a lower limit asks before pruning")
                .accessibilityLabel("History retention")
                HStack {
                    Text("Finished handoffs and activity records are kept separately, up to this many of each, across all workspaces. Active work is never pruned. A lower limit asks for confirmation before anything is removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage History…") {
                        model.requestStatusCenterSegment(.history)
                        openWindow(id: "status-center")
                    }
                    .help("Open Status Center › History for search, dismissed records and export")
                }
            }

            Section("Configuration") {
                if model.configurationLoadIssues.isEmpty {
                    Label("Every configuration store loaded when Parley started.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.configurationLoadIssues) { issue in
                        HStack(alignment: .top) {
                            Label {
                                Text(issue.summary)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                            Spacer()
                            if case let .file(name) = issue.store.location {
                                Button("Reveal in Finder") {
                                    model.revealConfigurationFile(named: name)
                                }
                                .help("Show the unreadable file and its kept copy; repair or remove them, then relaunch Parley")
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Parley is running on defaults for these stores and will not write over the unreadable files. Repair or remove them, then relaunch; Export Configuration leaves them out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Label("These two choices last for this app session only and reset to off when Parley quits.", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Approve agent command runs automatically",
                    isOn: Binding(
                        get: { model.automaticCommandRunApprovalEnabled },
                        set: { model.setAutomaticCommandRunApprovalEnabled($0) }
                    )
                )
                .help("Start every parley request-run command as requested, in a new Shell pane, without the editable preview")
                .accessibilityHint("Off by default. While on, requested commands run as you outside the agent boundary without a preview.")
                Text(ReviewedCommandRunCoordinator.automaticApprovalDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Off by default. Requested runs stay visible under Review runs and trust and in Status Center, and Cancel still stops a running command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Close the Shell pane when a run finishes cleanly",
                    isOn: Binding(
                        get: { model.automaticCommandRunPaneCloseEnabled },
                        set: { model.setAutomaticCommandRunPaneCloseEnabled($0) }
                    )
                )
                .help("Close a run's new Shell pane once a clean result is recorded; failed, cancelled or truncated runs keep their pane")
                .accessibilityHint("Off by default. Applies to runs that finish after it is turned on.")
                Text(ReviewedCommandRunPaneClosePolicy.disclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Agent command runs")
                    Spacer()
                    Text("This session only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Agent command runs apply to this session only")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }
}

/// The terminal type panes advertise, which takes effect for panes started
/// or restarted afterwards, and the curated Ghostty surface options about
/// how a pane behaves (the ones about how it looks sit in Appearance), which
/// apply to every surface at once except where Ghostty reads them only at
/// creation.
private struct TerminalSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var copiedRemoteCommand = false

    var body: some View {
        Form {
            Section("Terminal type") {
                Picker(
                    "Terminal type",
                    selection: Binding(
                        get: { model.terminalTypePreference },
                        set: { model.setTerminalTypePreference($0) }
                    )
                ) {
                    ForEach(TerminalTypePreference.allCases) { preference in
                        Text("\(preference.label) — \(preference.termValue)").tag(preference)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .help("Which TERM value new shell and agent panes advertise to the programs they run")
                .accessibilityLabel("Terminal type")
                Text(model.terminalTypePreference.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TerminalTypePreference.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TerminalTypePreference.scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote hosts") {
                Text("To keep the Ghostty terminal type and still use a remote host, install Ghostty's terminfo there once from any pane on this Mac. Parley never runs this for you; replace <host> with the ssh destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(TerminalTypePreference.remoteTerminfoCommand)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(copiedRemoteCommand ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TerminalTypePreference.remoteTerminfoCommand, forType: .string)
                        copiedRemoteCommand = true
                    }
                    .help("Copy the terminfo install command to the clipboard")
                    .accessibilityLabel("Copy the remote terminfo command")
                }
                Text("The delete key moving the cursor the wrong way on a remote host has the same cause: the host cannot look up which byte the key sends. Choosing Compatible, or keeping Ghostty and installing its terminfo on that host, resolves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TerminalSurfaceSettingsSections(model: model, tab: .terminal, restoreTitle: "Restore Ghostty Defaults")
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }
}

private struct NotificationSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Workspace notifications") {
                if model.workspaces.isEmpty {
                    Text("Create a workspace before enabling notifications.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.workspaces) { workspace in
                        Toggle(
                            workspace.name,
                            isOn: Binding(
                                get: { model.notificationsEnabled(for: workspace) },
                                set: { model.setNotificationsEnabled($0, for: workspace) }
                            )
                        )
                        .help("Send local notifications for \(workspace.name) when a result returns or attention is required")
                        .accessibilityLabel("Notifications for \(workspace.name)")
                    }
                }
            }

            Section {
                Text("Parley sends local notifications only for enabled workspaces when results return or authoritative attention is required. Banners contain pane, workspace and event-state labels, never prompt, result or terminal content. The Status Center bell shows this setting and opens it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
    }
}
