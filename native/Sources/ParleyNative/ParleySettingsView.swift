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

                ScrollView {
                    TerminalFontSettingsView(model: model, dismissAfterApply: false, showsTitle: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
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
        .frame(width: 680, height: 590)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Agent lifecycle") {
                Toggle(
                    "Reap idle agents after 30 minutes",
                    isOn: Binding(
                        get: { model.idleAgentReaperEnabled },
                        set: { model.idleAgentReaperEnabled = $0 }
                    )
                )
                .help("Close agent panes whose process has reported no activity for 30 minutes")
                .accessibilityHint("Off by default; idleness comes from process facts, never terminal text")
                Text("Off by default. Parley never infers that an agent is idle from terminal text.")
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
