import AppKit
import ParleyCore
import SwiftUI

struct ContainerLaunchOptionsView: View {
    @ObservedObject var model: AppModel
    let vendor: PaneKind
    @Binding var enabled: Bool
    @Binding var configuration: ContainerConfiguration?
    @State private var image: String
    @State private var legacy: Bool
    @State private var checking = false
    @State private var message: String?

    init(model: AppModel, vendor: PaneKind, enabled: Binding<Bool>, configuration: Binding<ContainerConfiguration?>, existing: ContainerConfiguration?) {
        self.model = model; self.vendor = vendor; _enabled = enabled; _configuration = configuration
        _image = State(initialValue: existing?.imageName ?? "")
        _legacy = State(initialValue: existing?.legacyCodexSandbox ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Run in a container (experimental)", isOn: $enabled)
            if enabled {
                TextField("Locally installed image", text: $image).textFieldStyle(.roundedBorder)
                    .onChange(of: image) { _, _ in configuration = nil; message = nil }
                Text("The image must contain /usr/local/bin/\(vendor.rawValue). Parley does not build or download images. Trust the image and the local daemon before starting it.")
                if vendor == .codex {
                    Toggle("Use Codex’s legacy Landlock sandbox", isOn: $legacy)
                        .onChange(of: legacy) { _, _ in configuration = nil; message = nil }
                    Text("Codex has deprecated this option and plans to remove it. Use it only for testing a compatible image when its default Bubblewrap sandbox cannot start. Vendor permission prompts remain active.")
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
                if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                Text("The container is the execution boundary. Only this working folder is mounted writable, plus this pane’s relay endpoint. Docker runs outside Parley’s control. No Docker socket or host login is mounted. Sign in inside the pane; a private named volume keeps this pane’s vendor login, configuration and saved conversations until you delete them in Status Center. Closing the main window keeps the container running; closing the pane or quitting stops it. Docker output logging is disabled.")
                Text("Vendor sandbox availability varies by image. Claude’s own sandbox may be unavailable and its regular permission flow still applies. Checks do not prove login, instruction uptake or a vendor session. Linked worktrees, additional folders and container team provisioning are not supported yet.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func check() {
        guard let service = model.controller?.containerService else { return }
        let selectedImage = image
        let selectedLegacy = legacy
        checking = true; configuration = nil; message = nil
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try service.preview(image: selectedImage, vendor: vendor, legacyCodexSandbox: selectedLegacy)
                }.value
                if image == selectedImage && legacy == selectedLegacy { configuration = preview }
            } catch { message = error.localizedDescription }
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
                try await Task.detached(priority: .userInitiated) {
                    if deleteLogin { try service.deleteLoginState(record) } else { try service.remove(record) }
                }.value
                if !deleteLogin, let pane = model.panes.first(where: { $0.id == record.paneID && $0.launchGeneration == record.generation }) {
                    if let controller = model.controller {
                        try await Task.detached(priority: .userInitiated) { try controller.prepareContainerStop(pane) }.value
                        try controller.stopPaneProcess(pane.id)
                        try model.refresh()
                    }
                }
                reload()
            } catch { message = error.localizedDescription }
            working = false
        }
    }
}
