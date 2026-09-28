import Darwin
import Foundation
import ParleyCore

private func hostExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "HostAgentPermissions", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func checkHostVendorTools(executable: URL) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-host-tools-\(UUID().uuidString)")
    let project = root.appendingPathComponent("project with spaces")
    let application = root.appendingPathComponent("app")
    let endpoint = application.appendingPathComponent("own-endpoint")
    let bin = root.appendingPathComponent("bin")
    let codexHome = root.appendingPathComponent("codex-home")
    for directory in [project, application, endpoint, bin, codexHome, project.appendingPathComponent(".git")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: executable)
    let environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": NSHomeDirectory(), "CODEX_HOME": codexHome.path]
    let writable = try PermissionProfileResolver.resolve(
        definition: PermissionProfileDefinition.builtIns.first { $0.rule(for: .projectWrite) == .allow }!, paneFolder: project.path)
    let readonly = try PermissionProfileResolver.resolve(
        definition: PermissionProfileDefinition.builtIns.first { $0.id == "review-only" }!, paneFolder: project.path)
    func permissions(_ profile: EffectivePermissionProfile) -> HostAgentPermissions {
        HostAgentPermissions(applicationDirectory: application, protocolDirectory: application.appendingPathComponent("agent-protocol"),
            shimDirectory: application.appendingPathComponent("bin"), transportDirectory: root.appendingPathComponent("transport"),
            endpointDirectory: endpoint, profile: profile)
    }
    func probe() throws {
        try HostAgentPermissions.preflight(applicationDirectory: application,
            protocolDirectory: application.appendingPathComponent("agent-protocol"), shimDirectory: application.appendingPathComponent("bin"),
            transportDirectory: root.appendingPathComponent("transport"), folder: project.path, profile: writable, environment: environment)
    }
    try probe()
    print("PASS real Codex preflight: ordinary tool launch, private read/write denial, own endpoint read/write")
    let runner = ProcessCommandRunner(timeout: 20)
    func run(_ profile: EffectivePermissionProfile, _ argv: [String]) throws -> CommandOutput {
        try runner.run(executable: executable, arguments: ["sandbox", "-P", permissions(profile).profileName, "-C", project.path] + permissions(profile).configurationArguments + ["--"] + argv,
            environment: environment)
    }
    let file = project.appendingPathComponent("file.txt")
    let write = ["/bin/sh", "-c", "printf before >\"$1\"", "probe", file.path]
    try hostExpect(try run(writable, write).status == 0, "workspace-write failed")
    let patch = "--- file.txt\n+++ file.txt\n@@ -1 +1 @@\n-before\n\\ No newline at end of file\n+after\n"
    let patchFile = project.appendingPathComponent("edit.patch")
    try patch.write(to: patchFile, atomically: true, encoding: .utf8)
    let patched = try run(writable, ["/usr/bin/patch", "--directory", project.path, "--input", patchFile.path])
    try hostExpect(patched.status == 0 && (try String(contentsOf: file, encoding: .utf8)) == "after\n", "ordinary sandboxed patch failed: \(patched.stderrText)")
    try hostExpect(try run(readonly, write).status != 0, "read-only profile allowed project mutation")
    try hostExpect(try run(writable, ["/usr/bin/touch", project.appendingPathComponent(".git/blocked").path]).status != 0,
        "Codex's inherited Git protection was lost")
    print("PASS real Codex workspace write, patch, read-only refusal and inherited .git protection")
    try "sandbox_mode = \"workspace-write\"\n".write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    var refused = false
    do { try probe() } catch { refused = true }
    try hostExpect(refused, "legacy sandbox configuration silently replaced the native profile")
    print("PASS real Codex preflight refuses legacy configuration that ignores private-path denials")
}

func checkHostLaunchesPreserveVendorControls() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("parley-host-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("app")
    let shim = app.appendingPathComponent("bin")
    let transport = root.appendingPathComponent("transport")
    let controller = try WorkbenchController(applicationDirectory: app, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    try controller.bootstrap(cwd: root.path)
    let credentials = try RelayCredentials(file: app.appendingPathComponent("tokens.json"))
    controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("relay-url"), shimDirectory: shim,
        transportDirectory: transport, credentials: credentials))
    for kind in PaneKind.allCases.filter(\.isAgent) {
        let profile = try PermissionProfileResolver.resolve(definition: PermissionProfileDefinition.builtIns.first { $0.id == "default" }!, paneFolder: root.path)
        let pane = try controller.createPane(kind: kind, cwd: root.path, permissionProfile: profile)
        var priorToken: String?
        for mode in [AgentLaunchMode.fresh] + (VendorResumeAdapter.plan(for: kind) == nil ? [] : [.resume]) {
            if mode == .resume { try controller.restartPane(pane.id, permissionProfile: profile, launchMode: mode) }
            let launch = try controller.launchConfiguration(for: pane.id)
            let token = try credentials.token(for: pane.id)
            let endpoint = RelayFileTransport.endpointDirectory(runtimeDirectory: transport, paneToken: token)
            // The launch carries the profile's execution rule, so the expected
            // argv has to be built with the same rule or this compares a
            // restricted launch against a permissive one.
            var expected = AgentProtocol.command(
                for: kind, protocolDirectory: controller.protocolDirectory, launchMode: mode,
                shellCommandRule: PermissionProfileAdapter.shellCommandRule(profile))
            if kind == .codex {
                let permissions = HostAgentPermissions(applicationDirectory: app, protocolDirectory: controller.protocolDirectory,
                    shimDirectory: shim, transportDirectory: transport, endpointDirectory: endpoint, profile: profile)
                expected += permissions.launchArguments
                try hostExpect(permissions.filesystem[app.path] == "deny" && permissions.filesystem[transport.path] == "deny"
                    && permissions.filesystem[endpoint.path] == "write" && permissions.filesystem[shim.path] == "read",
                    "native Codex permissions lost private paths or the exact endpoint")
                try hostExpect(!permissions.launchArguments.contains("--sandbox"), "legacy sandbox flag overrides native Codex rules")
                let ticketSocket = RelayTicketServer.socketURL(transportDirectory: transport)
                try hostExpect(permissions.filesystem[ticketSocket.path] == "read",
                    "the host rules omit explicit read access for the ticket socket")
                // Cover the short socket path as well as the long-path fallback
                // used by this fixture's temporary directory.
                let shortTransport = URL(fileURLWithPath: "/tmp/parley-ticket-permission-check")
                let shortPermissions = HostAgentPermissions(applicationDirectory: app, protocolDirectory: controller.protocolDirectory,
                    shimDirectory: shim, transportDirectory: shortTransport,
                    endpointDirectory: shortTransport.appendingPathComponent("own-endpoint"), profile: profile)
                let shortSocket = RelayTicketServer.socketURL(transportDirectory: shortTransport)
                try hostExpect(shortPermissions.filesystem[shortSocket.path] == "read"
                    && shortPermissions.filesystem[shortSocket.resolvingSymlinksInPath().path] == "read"
                    && shortPermissions.filesystem[shortTransport.path] == "deny"
                    && shortPermissions.filesystem[shortTransport.appendingPathComponent("other-endpoint").path] == nil,
                    "the socket exception lost a path alias or exposed sibling endpoints")
            } else { expected += PermissionProfileAdapter.launchPlan(for: kind, profile: profile).arguments }
            try hostExpect(launch.command == GhosttyLaunchCommand.render(["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE", "-u", "PARLEY_RUNTIME"] + expected),
                "\(kind) \(mode) changed the vendor argv or retained a host wrapper")
            try hostExpect(launch.paneID == pane.id && launch.workingDirectory == root.path && launch.environment["PARLEY_RELAY_TOKEN"] == token,
                "host launch lost its folder or pane identity")
            try hostExpect(FileManager.default.fileExists(atPath: endpoint.path), "host launch omitted endpoint preparation")
            if let priorToken { try hostExpect(priorToken != token && launch.generation > pane.launchGeneration, "resume reused old launch authority") }
            priorToken = token
        }
    }
}

func checkHostLaunchPermissionSnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-host-snapshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("app")
    let controller = try WorkbenchController(applicationDirectory: app, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    try controller.bootstrap(cwd: root.path)
    let credentials = try RelayCredentials(file: app.appendingPathComponent("tokens.json"))
    controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("relay-url"), shimDirectory: app.appendingPathComponent("bin"),
        transportDirectory: root.appendingPathComponent("transport"), credentials: credentials))
    let store = PermissionProfileStore(file: app.appendingPathComponent("permission-profiles.json"))
    let original = PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }!.clone(id: "custom-snapshot", name: "Snapshot")
    let edited = PermissionProfileDefinition.builtIns.first { $0.id == "flexible-network" }!.clone(id: original.id, name: original.name)
    try store.saveCustom(original)
    let profile = try PermissionProfileResolver.resolve(definition: original, paneFolder: root.path)
    let pane = try controller.createPane(kind: .codex, cwd: root.path, permissionProfile: profile)
    let token = try credentials.token(for: pane.id)
    let broker = RelayBroker(credentials: credentials, panes: { try controller.listPanes() }, paste: { _, _ in }, submit: { _, _ in })
    broker.hostNetworkAllowed = { controller.hostNetworkAllowed(for: $0) }
    try hostExpect(controller.hostNetworkAllowed(for: pane) == false, "the reviewed launch permission was not captured before surface creation")
    let first = try controller.launchConfiguration(for: pane.id)
    try hostExpect(controller.hostNetworkAllowed(for: pane) == false
        && broker.ticketPolicy(token: token, socketListening: true)?.requirement == .optional,
        "a launch without network requires a ticket")
    try store.saveCustom(edited)
    try hostExpect(try controller.launchConfiguration(for: pane.id) == first,
        "editing a stored profile changed the permissions reported for an existing launch")
    try hostExpect(controller.hostNetworkAllowed(for: pane) == false
        && broker.ticketPolicy(token: token, socketListening: true)?.requirement == .optional,
        "a profile edit changed the running pane's ticket requirement")
    try controller.restartPane(pane.id)
    let current = try controller.listPanes().first { $0.id == pane.id }!
    try controller.terminalDidClose(paneID: pane.id, generation: pane.launchGeneration, processAlive: false)
    try hostExpect(try controller.listPanes().first { $0.id == pane.id }?.isDead == false,
        "a close callback from the previous surface killed the replacement generation")
    try hostExpect(controller.hostNetworkAllowed(for: pane) == nil && controller.hostNetworkAllowed(for: current) == true,
        "a restarted generation reused the old launch's network fact")
    let restarted = try controller.launchConfiguration(for: pane.id)
    try hostExpect(restarted.generation != first.generation && restarted.command.contains("network={enabled=true}"),
        "the next launch did not pick up the edited network permission")
    let newToken = try credentials.token(for: pane.id)
    try hostExpect(controller.hostNetworkAllowed(for: current) == true
        && broker.ticketPolicy(token: newToken, socketListening: true)?.requirement == .required,
        "the networked replacement did not require a ticket")
    try store.deleteCustom(id: original.id)
    try hostExpect(try controller.launchConfiguration(for: pane.id) == restarted,
        "deleting a stored profile invalidated an existing launch")
    try hostExpect(broker.ticketPolicy(token: newToken, socketListening: true)?.requirement == .required,
        "deleting a profile relaxed the running pane's ticket requirement")
    try controller.stopPaneProcess(pane.id, expectedGeneration: nil)
    try hostExpect(controller.hostNetworkAllowed(for: current) == nil, "a stopped pane retained a live network fact")
}
