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
    @State private var port: String
    private let onBypassChange: (Bool) -> Void
    /// The team approval keeps the toggle per vendor; the pane review drives
    /// `enabled` from its own Runs picker and hides it.
    private let showsToggle: Bool
    @State private var checking = false
    @State private var message: String?
    /// Advanced by every change of `checkInputs`. A check applies its result
    /// only under the revision it began with: its Task holds a copy of this
    /// view, whose `let` properties never change, so comparing them there
    /// could not notice that the review moved to another vendor or folder.
    @State private var checkRevision = 0

    init(model: AppModel, vendor: PaneKind, folder: String, plannedCommonDirectory: String? = nil, enabled: Binding<Bool>, configuration: Binding<ContainerConfiguration?>, existing: ContainerConfiguration?, showsToggle: Bool = true, onBypassChange: @escaping (Bool) -> Void = { _ in }) {
        self.model = model; self.vendor = vendor; self.folder = folder; self.plannedCommonDirectory = plannedCommonDirectory; _enabled = enabled; _configuration = configuration
        self.showsToggle = showsToggle
        _image = State(initialValue: existing?.imageName ?? "")
        _legacy = State(initialValue: existing?.legacyCodexSandbox ?? false)
        _bypass = State(initialValue: existing?.bypassVendorPermissions ?? false)
        _port = State(initialValue: existing?.publishedPort.map(String.init) ?? "")
        self.onBypassChange = onBypassChange
    }

    /// The typed port, or nil for none. `.some(nil)` is "leave it empty";
    /// `nil` means the text is not a port at all.
    private var parsedPort: Int?? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Int(trimmed) else { return nil }
        return .some(value)
    }

    /// Everything a check's result depends on. Every stored input of this
    /// view belongs here, so a change to any of them discards a check still
    /// running rather than letting its result land under the new choice.
    private var checkInputs: ContainerImageCheckInputs {
        ContainerImageCheckInputs(vendor: vendor, folder: folder, plannedCommonDirectory: plannedCommonDirectory, enabled: enabled,
            image: image, legacy: legacy, bypass: bypass, port: port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsToggle {
                Toggle("Run in a container (experimental)", isOn: $enabled)
            }
            if enabled {
                TextField("Locally installed image", text: $image).textFieldStyle(.roundedBorder)
                Text("The image must contain /usr/local/bin/\(vendor.rawValue). Parley does not build or download images. Checking executes code from this image in a disposable container with no network, project files or login. Trust the image and the local daemon before checking it.")
                Toggle("Bypass vendor permissions (container only)", isOn: $bypass)
                    .onChange(of: bypass) { _, value in
                        if value { legacy = false }
                        onBypassChange(value)
                    }
                if bypass {
                    Text(bypassDescription)
                    Text("Docker supplies the execution boundary. The agent can change mounted project files and shared Git metadata, run commands, use the network and access its saved vendor login without the usual vendor permission prompts. The selected profile’s restrictions are not applied. Native approval is still required for requested host command runs.")
                        .foregroundStyle(.orange)
                }
                if vendor == .codex {
                    Toggle("Use Codex’s legacy Landlock sandbox", isOn: $legacy)
                        .disabled(bypass)
                    Text("Codex has deprecated this option and plans to remove it. Use it only for testing a compatible image when its default Bubblewrap sandbox cannot start. This option applies only while vendor permissions are enabled.")
                }
                TextField("Published port (optional)", text: $port).textFieldStyle(.roundedBorder)
                Text(signInGuidance)
                if case .some(.some(let value)) = parsedPort {
                    Text("Port \(value) on this Mac will forward to port \(value) inside the container, on 127.0.0.1 only — nothing on your network can reach it. If another process on this Mac is already listening on \(value), Docker refuses to start the container.")
                        .foregroundStyle(.orange)
                } else if parsedPort == nil {
                    Text("The published port must be a whole number between 1024 and 65535.").foregroundStyle(.orange)
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
                Text(GitReadBoundary.containerDisclosure)
                Text("The container is the execution boundary. The working folder and this pane’s relay endpoint are writable; any additional shared Git mount is listed above. Docker runs outside Parley’s control. No Docker socket or host login is mounted. Sign in inside the pane; a private named volume keeps this pane’s vendor login, configuration and saved conversations until you delete them in Status Center. Closing the main window keeps the container running; closing the pane or quitting stops it. Docker output logging is disabled.")
                Text("Vendor sandbox availability varies by image. Claude’s and Agy’s own sandboxes may be unavailable. Vendor prompts apply unless you selected bypass above. Checks do not prove login, instruction uptake or a vendor session. Linked worktrees require review of their shared Git directory; arbitrary additional folders are not mounted.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { onBypassChange(bypass) }
        .onChange(of: checkInputs) { _, _ in
            checkRevision += 1
            configuration = nil; message = nil
        }
        // A view that leaves and comes back may be a new one, but a check
        // still running holds this one's storage and would apply its result.
        .onDisappear { checkRevision += 1 }
    }

    /// What the vendor's documented skip-all flag does inside the container.
    private var bypassDescription: String {
        switch vendor {
        case .codex: "Codex will skip its sandbox and approval prompts inside this container."
        case .agy: "Agy will approve every tool permission request inside this container without asking."
        case .copilot: "Copilot will allow every tool, path and URL inside this container without confirmation."
        case .claude, .shell: "Claude will skip its permission checks inside this container."
        }
    }

    /// Whether the vendor's sign-in needs the published port. Only Codex's
    /// browser flow calls back to a fixed localhost port; the others print a
    /// code or an address, or detect a headless host and use a device code.
    private var signInGuidance: String {
        switch vendor {
        case .codex: "Codex’s browser sign-in returns to localhost:1455, which cannot reach a container unless that port is published. Enter 1455 to sign in through your Mac browser. Leave it empty to use Sign in with Device Code, which needs no port."
        case .copilot: "Copilot detects a container and uses its device-code sign-in, which needs no port. Leave this empty unless the image runs something a browser on this Mac must reach."
        case .agy: "Agy prints a sign-in address to open in your Mac browser and asks for the code it gives you, which needs no port. Leave this empty unless the image runs something a browser on this Mac must reach."
        case .claude, .shell: "Claude’s paste-code sign-in needs no port. Leave this empty unless the image runs something a browser on this Mac must reach."
        }
    }

    private func check() {
        guard let service = model.controller?.containerService else { return }
        let inputs = checkInputs
        guard case .some(let selectedPort) = parsedPort else {
            message = "The published port must be a whole number between 1024 and 65535."
            return
        }
        let revision = checkRevision
        checking = true; configuration = nil; message = nil
        Task {
            let result: Result<ContainerConfiguration, Error>
            do {
                result = .success(try await Task.detached(priority: .userInitiated) {
                    var preview = try service.preview(image: inputs.image, vendor: inputs.vendor, legacyCodexSandbox: inputs.legacy,
                        bypassVendorPermissions: inputs.bypass, publishedPort: selectedPort)
                    preview.gitAccess = try inputs.plannedCommonDirectory.map { try ContainerGitAccess.planned(folder: inputs.folder, commonDirectory: $0) }
                        ?? ContainerGitAccess.inspect(folder: inputs.folder)
                    return preview
                }.value)
            } catch { result = .failure(error) }
            // One probe runs at a time, so this one always ends `checking`,
            // even when the inputs moved on and its result is discarded.
            checking = false
            // Read through @State, which this copy of the view shares with the live one.
            guard checkRevision == revision else { return }
            switch result {
            case let .success(preview): configuration = preview
            case let .failure(error): message = error.localizedDescription
            }
        }
    }
}

private struct ContainerImageCheckInputs: Equatable {
    let vendor: PaneKind
    let folder: String
    let plannedCommonDirectory: String?
    let enabled: Bool
    let image: String
    let legacy: Bool
    let bypass: Bool
    let port: String
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
                    if let port = record.configuration.publishedPort {
                        Text("Port \(port) forwarded from this Mac’s loopback into the container")
                    }
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
