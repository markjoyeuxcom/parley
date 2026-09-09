import AppKit
import ParleyCore
import SwiftUI

struct ContainerLaunchOptionsView: View {
    @ObservedObject var model: AppModel
    let vendor: PaneKind
    let folder: String
    let plannedCommonDirectory: String?
    @Binding var enabled: Bool
    @Binding var configuration: ContainerConfiguration?
    @State private var image: String
    @State private var legacy: Bool
    @State private var bypass: Bool
    private let onBypassChange: (Bool) -> Void
    @State private var checking = false
    @State private var message: String?

    init(model: AppModel, vendor: PaneKind, folder: String, plannedCommonDirectory: String? = nil, enabled: Binding<Bool>, configuration: Binding<ContainerConfiguration?>, existing: ContainerConfiguration?, onBypassChange: @escaping (Bool) -> Void = { _ in }) {
        self.model = model; self.vendor = vendor; self.folder = folder; self.plannedCommonDirectory = plannedCommonDirectory; _enabled = enabled; _configuration = configuration
        _image = State(initialValue: existing?.imageName ?? "")
        _legacy = State(initialValue: existing?.legacyCodexSandbox ?? false)
        _bypass = State(initialValue: existing?.bypassVendorPermissions ?? false)
        self.onBypassChange = onBypassChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Run in a container (experimental)", isOn: $enabled)
            if enabled {
                TextField("Locally installed image", text: $image).textFieldStyle(.roundedBorder)
                    .onChange(of: image) { _, _ in configuration = nil; message = nil }
                Text("The image must contain /usr/local/bin/\(vendor.rawValue). Parley does not build or download images. Checking executes code from this image in a disposable container with no network, project files or login. Trust the image and the local daemon before checking it.")
                Toggle("Bypass vendor permissions (container only)", isOn: $bypass)
                    .onChange(of: bypass) { _, value in
                        if value { legacy = false }
                        configuration = nil; message = nil; onBypassChange(value)
                    }
                if bypass {
                    Text(vendor == .codex
                        ? "Codex will skip its sandbox and approval prompts inside this container."
                        : "Claude will skip its permission checks inside this container.")
                    Text("Docker supplies the execution boundary. The agent can change mounted project files and shared Git metadata, run commands, use the network and access its saved vendor login without the usual vendor permission prompts. The selected profile’s restrictions are not applied. Native approval is still required for requested host command runs.")
                        .foregroundStyle(.orange)
                }
                if vendor == .codex {
                    Toggle("Use Codex’s legacy Landlock sandbox", isOn: $legacy)
                        .disabled(bypass)
                        .onChange(of: legacy) { _, _ in configuration = nil; message = nil }
                    Text("Codex has deprecated this option and plans to remove it. Use it only for testing a compatible image when its default Bubblewrap sandbox cannot start. This option applies only while vendor permissions are enabled.")
                    Text("For Codex sign-in, choose Sign in with Device Code and open the supplied link in your Mac browser. This container does not publish the browser-login callback port.")
                }
                HStack {
                    Button(checking ? "Checking…" : "Check Image and Daemon", action: check)
                        .disabled(checking || image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if configuration != nil { Text("Ready for your review").foregroundStyle(.secondary) }
                }
                if let configuration {
                    Text("Daemon: \(configuration.daemonEndpoint)\nImage: \(configuration.imageID)")
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                if let access = configuration?.gitAccess {
                    Text("Additional writable Git mount: \(access.commonDirectory)\nThis shares repository objects, refs, hooks and configuration with the other worktrees. It does not mount the primary checkout. Git writes follow the vendor permission mode selected above. Changes to shared hooks or executable Git configuration can cause commands to run on your Mac, outside the container, during later host Git operations. Parley does not review those changes again.")
                        .textSelection(.enabled)
                }
                if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                Text("The container is the execution boundary. The working folder and this pane’s relay endpoint are writable; any additional shared Git mount is listed above. Docker runs outside Parley’s control. No Docker socket or host login is mounted. Sign in inside the pane; a private named volume keeps this pane’s vendor login, configuration and saved conversations until you delete them in Status Center. Closing the main window keeps the container running; closing the pane or quitting stops it. Docker output logging is disabled.")
                Text("Vendor sandbox availability varies by image. Claude’s own sandbox may be unavailable. Vendor prompts apply unless you selected bypass above. Checks do not prove login, instruction uptake or a vendor session. Linked worktrees require review of their shared Git directory; arbitrary additional folders are not mounted.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { onBypassChange(bypass) }
        .onChange(of: enabled) { _, _ in configuration = nil; message = nil }
        .onChange(of: folder) { _, _ in configuration = nil; message = nil }
        .onChange(of: plannedCommonDirectory) { _, _ in configuration = nil; message = nil }
    }

    private func check() {
        guard let service = model.controller?.containerService else { return }
        let selectedImage = image
        let selectedLegacy = legacy
        let selectedBypass = bypass
        let selectedFolder = folder
        let selectedCommon = plannedCommonDirectory
        checking = true; configuration = nil; message = nil
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    var preview = try service.preview(image: selectedImage, vendor: vendor, legacyCodexSandbox: selectedLegacy, bypassVendorPermissions: selectedBypass)
                    preview.gitAccess = try selectedCommon.map { try ContainerGitAccess.planned(folder: selectedFolder, commonDirectory: $0) }
                        ?? ContainerGitAccess.inspect(folder: selectedFolder)
                    return preview
                }.value
                if enabled && image == selectedImage && legacy == selectedLegacy && bypass == selectedBypass && folder == selectedFolder && plannedCommonDirectory == selectedCommon { configuration = preview }
            } catch {
                if enabled && image == selectedImage && legacy == selectedLegacy && bypass == selectedBypass && folder == selectedFolder && plannedCommonDirectory == selectedCommon { message = error.localizedDescription }
            }
            checking = false
        }
    }
}

struct ContainerRecordsView: View {
    @ObservedObject var model: AppModel
    @State private var records: [ContainerPaneRecord] = []
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Container ownership and saved login state").font(.headline)
                Spacer()
                Button("Refresh", action: reload).disabled(working)
            }
            Text("Recorded containers are never adopted after an app restart. Removal uses their exact creation receipts. Labels alone grant no cleanup authority. Processes inside containers are not listed in Processes below.")
                .font(.caption).foregroundStyle(.secondary)
            if records.isEmpty { Text("No recorded containers or saved container login state.").foregroundStyle(.secondary) }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.panes.first(where: { $0.id == record.paneID })?.displayName ?? "Closed pane")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(record.configuration.imageName) · generation \(record.generation) · \(record.runtime)")
                    Text(record.configuration.permissionModeLabel)
                    Text(record.removed ? "Container removed · vendor state retained" : "Creation recorded · running state not inferred")
                    if let id = record.containerID { Text(String(id.prefix(16))).font(.system(size: 10, design: .monospaced)) }
                    HStack {
                        if !record.removed {
                            Button("Stop and Remove…") { mutate(record, deleteLogin: false) }
                        } else {
                            Button("Delete Saved Vendor State…") { mutate(record, deleteLogin: true) }
                        }
                    }.disabled(working)
                }.font(.caption).padding(.vertical, 6)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.task { reload() }
    }

    private func reload() {
        guard let service = model.controller?.containerService else { return }
        Task {
            do {
                records = try await Task.detached(priority: .utility) { try service.records().sorted { $0.createdAt > $1.createdAt } }.value
                message = nil
            } catch { message = error.localizedDescription }
        }
    }

    private func mutate(_ record: ContainerPaneRecord, deleteLogin: Bool) {
        guard let service = model.controller?.containerService else { return }
        let alert = NSAlert()
        alert.messageText = deleteLogin ? "Delete this pane’s saved vendor state?" : "Stop and remove this recorded container?"
        alert.informativeText = deleteLogin
            ? "This permanently deletes its named volume, including vendor login, configuration and saved conversations. Project files and Parley history are kept. A volume still referenced by any container is refused."
            : "This ends work in that exact container. Its project files and saved vendor state remain. A changed daemon or ownership receipt is refused."
        alert.addButton(withTitle: deleteLogin ? "Delete Vendor State" : "Stop and Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        Task {
            do {
                if deleteLogin {
                    try await Task.detached(priority: .userInitiated) { try service.deleteLoginState(record) }.value
                } else if let controller = model.controller {
                    let pane = try await Task.detached(priority: .userInitiated) { try controller.removeRecordedContainer(record) }.value
                    if let pane { try controller.stopPaneProcess(pane.id, expectedGeneration: pane.launchGeneration) }
                    try model.refresh()
                }
                reload()
            } catch { message = error.localizedDescription }
            working = false
        }
    }
}
