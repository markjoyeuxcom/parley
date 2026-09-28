import Darwin
import Foundation
import ParleyCore

private func containerExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "ContainerPaneChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// These checks deliberately consult the real Production/Development roots;
/// an agent boundary cannot inspect them. Refusal stays a failed prerequisite,
/// never a silent skip or a weakened production check.
private func requireContainerControllerShell() throws {
    for directory in ParleyRuntime.controlDirectories() {
        if let resolved = realpath(directory.path, nil) { free(resolved); continue }
        if errno == EPERM || errno == EACCES {
            throw NSError(domain: "ContainerCheckPrerequisite", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This check requires a human Shell pane with access to Parley's protected runtime paths. Use parley request-run; the check was not run."])
        }
    }
}

var containerPaneChecks: [(String, () throws -> Void)] { [
    ("container reviewed bypass stays inside the container", checkContainerReviewedBypass),
    ("container reviewed port forwards loopback only and never widens the boundary", checkContainerPublishedPort),
    ("container bypass preflight checks vendor startup without an inner sandbox", checkContainerBypassPreflight),
    ("container bypass controller binds review and restores host permissions", checkContainerBypassController),
    ("container Git review canonicalizes planned aliases and names submodule refusal", checkContainerGitReviewRefusals),
    ("container bulk cleanup includes prepared host placeholders", checkContainerPreparedBulkStop),
    ("container team controller preserves creation, activation and Stop ownership", checkContainerTeamController),
    ("container follow-up image probe checks Linux utility contract", checkContainerImageUtilities),
    ("container follow-up linked worktree accepts reviewed Git access", checkContainerLinkedWorktree),
    ("container follow-up record reads stay responsive during Docker work", checkContainerResponsiveRecords),
    ("container follow-up cleanup continues after one failed receipt", checkContainerCleanupContinuation),
    ("container recorded removal recovers a failed preparation", checkContainerPreparedRemovalRecovery),
    ("container old receipt removal preserves a replacement at the same generation", checkContainerOldReceiptRemoval),
    ("container controller refuses folders inside relay transport before mutation", checkContainerTransportFolderRefusal),
    ("container projection refuses both directions of control-path overlap", checkContainerControlPathOverlap),
    ("container controller keeps Docker outside its lock and binds restart receipts", checkContainerControllerLifecycle),
    ("container creation stays inert until explicit preparation", checkContainerInertCreation),
    ("container launch preserves reviewed boundaries", checkContainerLaunchProjection),
    ("container ownership store fails closed on damaged records", checkContainerReceiptStore),
    ("container cleanup refuses another owner, daemon and generation", checkContainerOwnershipRefusals),
    ("container initializer timeout retains its creation receipt", checkContainerInitializationReceipt),
    ("container vendor-state deletion is scoped to its daemon", checkContainerVolumeDaemonScope),
    ("container shim preserves the protocol and refuses host opening", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parley-linux-shim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try RelayShim.installCommand(in: directory.appendingPathComponent("bin"),
            transportDirectory: directory.appendingPathComponent("transport"), platform: .linux)
        let source = try String(contentsOf: command, encoding: .utf8)
        try containerExpect(source.contains("stat -c") && !source.contains("stat -f"), "Linux shim still uses BSD stat")
        try containerExpect(source.contains("/proc/sys/kernel/random/uuid"), "Linux UUID fallback missing")
        let runner = ProcessCommandRunner()
        let protocolResult = try runner.run(executable: command, arguments: ["protocol"], environment: [:])
        try containerExpect(protocolResult.status == 0 && protocolResult.stdoutText == AgentProtocol.text, "protocol changed across platforms")
        let openResult = try runner.run(executable: command, arguments: ["open", "/"], environment: [:])
        try containerExpect(openResult.status != 0 && openResult.stderrText.contains("container"), "Linux shim attempted host opening")
    }),
] }

/// Explicit integration command, never counted as a passing skipped check.
/// Uses a disposable broker and credentials; no installed pane is impersonated.
func checkContainerTransportSpike(image: String, docker: String) throws {
    let fm = FileManager.default
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-spike-\(UUID().uuidString.lowercased())")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    var preserveFixture = false
    defer { if !preserveFixture { try? fm.removeItem(at: directory) } }
    let project = directory.appendingPathComponent("project")
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("credentials.json"))
    let source = WorkbenchPane(id: "container-source", kind: .codex, customName: "Source", terminalTitle: "", cwd: project.path,
        currentCommand: "codex", isActive: false, workspaceID: "spike", relayEnabled: true,
        protocolVersion: AgentProtocol.version, inputAvailable: true)
    let target = WorkbenchPane(id: "container-target", kind: .claude, customName: "Target", terminalTitle: "", cwd: project.path,
        currentCommand: "claude", isActive: false, workspaceID: "spike", relayEnabled: true,
        protocolVersion: AgentProtocol.version, inputAvailable: true)
    let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in },
        contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context.json")))
    let sourceToken = try credentials.token(for: source.id)
    let targetToken = try credentials.token(for: target.id)
    let transportRoot = directory.appendingPathComponent("transport")
    for token in [sourceToken, targetToken] {
        _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportRoot, paneToken: token)
    }
    let shim = try RelayShim.installCommand(in: directory.appendingPathComponent("linux-bin"), transportDirectory: transportRoot, platform: .linux)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportRoot)
    try transport.start()
    defer { transport.stop() }
    let runner = ProcessCommandRunner(timeout: 30, maximumCapturedBytes: 200_000)
    let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"]
    func invoke(_ token: String, _ arguments: [String], status: Int32 = 0, mountToken: String? = nil) throws -> String {
        let endpoint = transportRoot.appendingPathComponent(mountToken ?? token).path
        let argv = ["run", "--rm", "--log-driver=none", "--network=none", "--user", "\(getuid()):\(getgid())",
            "--env", "PARLEY_RELAY_TOKEN=\(token)",
            "--mount", "type=bind,source=\(endpoint),target=\(endpoint)",
            "--mount", "type=bind,source=\(shim.deletingLastPathComponent().path),target=\(shim.deletingLastPathComponent().path),readonly",
            "--mount", "type=bind,source=\(project.path),target=\(project.path)",
            "--entrypoint", shim.path, image] + arguments
        let output = try runner.run(executable: URL(fileURLWithPath: docker), arguments: argv, environment: environment)
        try containerExpect(output.status == status, "Docker shim \(arguments.first ?? "") failed (\(output.status)): \(output.stderrText) \(output.stdoutText)")
        return output.stdoutText
    }
    let identity = try invoke(sourceToken, ["whoami"])
    try containerExpect(identity.contains(source.id), "container identity lost its source")
    print("PASS Docker Linux whoami: same-path mount, UID/mode checks and heartbeat accepted")
    _ = try invoke(sourceToken, ["relay", target.id, "Container transport probe"])
    print("PASS Docker Linux Relay to a distinct fixture pane")
    let pending = ContainerPendingInvocation { try invoke(sourceToken, ["ask", target.id, "Answer this fixture consultation"]) }
    pending.start()
    let deadline = Date().addingTimeInterval(10)
    while broker.consultations().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    guard let consultation = broker.consultations().first else { throw NSError(domain: "no container consultation", code: 1) }
    _ = try invoke(targetToken, ["answer", consultation.id, "Exact correlated answer"])
    try containerExpect(try pending.wait() == "Exact correlated answer", "container Ask returned another response")
    print("PASS Docker Linux correlated Ask and Answer")
    _ = try invoke(targetToken, ["whoami"], status: 2, mountToken: sourceToken)
    print("PASS Docker valid sibling capability cannot use another mounted endpoint")
    let delegated = try invoke(sourceToken, ["delegate", target.id, "Return the fixture file"])
    let receipt = try JSONSerialization.jsonObject(with: Data(delegated.utf8)) as? [String: Any]
    guard let handoffID = receipt?["handoffID"] as? String else { throw NSError(domain: "ContainerSpike", code: 1) }
    let file = project.appendingPathComponent("result.md")
    try "## Implemented\nFixture only\n## Tested\nLinux file transport\n## Unable to test\nVendor login\n".write(to: file, atomically: true, encoding: .utf8)
    _ = try invoke(targetToken, ["done", "current", "--file", file.path])
    _ = try invoke(sourceToken, ["wait", handoffID])
    print("PASS Docker Linux Delegate, done --file and result recovery")
    _ = try invoke(sourceToken, ["context", "draft", "--name", "Linux probe", "--file", file.path])
    _ = try invoke(sourceToken, ["context", "list"])
    print("PASS Docker Linux context staging and list")
    // A heartbeat that is gone for a moment (the transport held back, or the
    // Mac just woke) is waited out, and the shim's wake entry, written inside
    // the Linux VM, reaches the Mac's inbox watcher through the bind mount.
    transport.stop()
    let inbox = transportRoot.appendingPathComponent(sourceToken).appendingPathComponent("inbox")
    let inboxDescriptor = open(inbox.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
    try containerExpect(inboxDescriptor >= 0, "could not watch the source inbox")
    final class Wakes: @unchecked Sendable { let lock = NSLock(); var count = 0 }
    let wakes = Wakes()
    let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: inboxDescriptor, eventMask: [.write, .link], queue: .global())
    watcher.setEventHandler { wakes.lock.withLock { wakes.count += 1 } }
    watcher.setCancelHandler { close(inboxDescriptor) }
    watcher.resume()
    defer { watcher.cancel() }
    // The Linux VM can keep showing the removed heartbeat for a moment; a shim
    // started inside that window sends at once and meets the restart below.
    Thread.sleep(forTimeInterval: 1.5)
    let stalled = ContainerPendingInvocation { try invoke(sourceToken, ["whoami"]) }
    stalled.start()
    Thread.sleep(forTimeInterval: 2)
    try containerExpect(wakes.lock.withLock { wakes.count } > 0, "the Linux shim's wake entry never reached the Mac's inbox watcher")
    try transport.start()
    // Either the shim waited and finished, or it had already sent and the
    // restart discarded its request, which it must report. Never a hang.
    do {
        let identity = try stalled.wait()
        try containerExpect(identity.contains(source.id), "the Linux shim did not complete once the transport was back")
        print("PASS Docker Linux shim waits out a missing heartbeat and wakes the Mac's transport")
    } catch let error as NSError where error.localizedDescription.contains("restarted before replying") {
        print("PASS Docker Linux shim reports the transport restart that discarded its request (it had sent before the VM saw the heartbeat go)")
    } catch {
        let endpointRoot = transportRoot.appendingPathComponent(sourceToken)
        let listing = (FileManager.default.enumerator(atPath: endpointRoot.path)?.allObjects as? [String] ?? []).sorted()
        throw NSError(domain: "ContainerPaneChecks", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "the Linux shim neither completed nor reported the restart (\(error)); endpoint held: \(listing)"])
    }
    if image == "parley-container-spike:local" {
        let service = try ContainerPaneService(directory: directory.appendingPathComponent("containers"), environment: environment)
        defer {
            do {
                try service.stopAll()
                for record in try service.records() where record.removed { try service.deleteLoginState(record) }
            } catch {
                preserveFixture = true
                print("Container test cleanup was not confirmed; receipts retained at \(directory.path): \(error.localizedDescription)")
            }
        }
        let protocolFolder = directory.appendingPathComponent("protocol")
        try fm.createDirectory(at: protocolFolder, withIntermediateDirectories: true)
        let configuration = try service.preview(image: image, vendor: .codex, legacyCodexSandbox: true)
        let id = try service.prepare(configuration: configuration, pane: source,
            endpoint: transportRoot.appendingPathComponent(sourceToken).path, protocolDirectory: protocolFolder.path,
            shimDirectory: directory.appendingPathComponent("linux-bin").path, token: sourceToken, vendorArguments: ["--version"], runtime: "DEV")
        let output = try runner.run(executable: URL(fileURLWithPath: docker),
            arguments: ContainerLaunchProjection.attachArguments(configuration: configuration, containerID: id), environment: environment)
        try containerExpect(output.status == 0, "created container could not attach: \(output.stderrText)")
        try service.stop(paneID: source.id, generation: source.launchGeneration)
        let records = try service.records()
        try containerExpect(records.allSatisfy(\.removed), "container stop did not reconcile its receipt")
        try service.deleteLoginState(records[0])
        print("PASS Docker pinned image, recorded creation ID, attach, stop and login-volume removal")
        let repository = directory.appendingPathComponent("git-repository")
        let tree = directory.appendingPathComponent("git-linked")
        for arguments in [["init", repository.path], ["-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"],
                          ["-C", repository.path, "worktree", "add", "-b", "container-fixture", tree.path]] {
            let output = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1"])
            try containerExpect(output.status == 0, "worktree spike fixture failed: \(output.stderrText)")
        }
        try "fixture".write(to: tree.appendingPathComponent("container-fixture.txt"), atomically: true, encoding: .utf8)
        var worktreeConfiguration = configuration
        worktreeConfiguration.gitAccess = try ContainerGitAccess.inspect(folder: tree.path)
        try service.validateFolder(tree.path, protectedDirectories: [transportRoot.path], gitAccess: worktreeConfiguration.gitAccess)
        var worktreePane = source; worktreePane.id = "worktree-container-source"; worktreePane.cwd = tree.path
        let worktreeID = try service.prepare(configuration: worktreeConfiguration, pane: worktreePane,
            endpoint: transportRoot.appendingPathComponent(sourceToken).path, protocolDirectory: protocolFolder.path,
            shimDirectory: directory.appendingPathComponent("linux-bin").path, token: sourceToken,
            vendorArguments: ["sandbox", "--", "/usr/bin/git", "-C", tree.path, "status", "--porcelain"], runtime: "DEV")
        let worktreeOutput = try runner.run(executable: URL(fileURLWithPath: docker),
            arguments: ContainerLaunchProjection.attachArguments(configuration: worktreeConfiguration, containerID: worktreeID).filter { $0 != "--interactive" }, environment: environment)
        try containerExpect(worktreeOutput.status == 0 && worktreeOutput.stdoutText.contains("container-fixture.txt"),
            "Codex sandbox could not read the linked worktree with its shared Git mount (\(worktreeOutput.status)): \(worktreeOutput.stdoutText) \(worktreeOutput.stderrText)")
        try service.stop(paneID: worktreePane.id)
        for record in try service.records() where record.removed { try service.deleteLoginState(record) }
        print("PASS Docker linked worktree Git status through Codex sandbox and exact shared metadata mount")
    }
    // Negative boundary: mounting one endpoint must not grant its sibling.
    _ = try invoke(String(repeating: "a", count: 48), ["whoami"], status: 125)
    print("PASS Docker refuses a missing endpoint mount")
}

func checkContainerLaunchProjection() throws {
    let config = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "reviewed-image", legacyCodexSandbox: false)
    let facts = ContainerLaunchFacts(paneID: "pane-fixture", generation: 2, vendor: .codex, folder: "/project with spaces",
        endpoint: "/transport/" + String(repeating: "a", count: 48), protocolDirectory: "/runtime/agent-protocol",
        shimDirectory: "/runtime/linux-bin", uid: 501, gid: 20, volume: "parley-home-fixture", owner: "owner-fixture", runtime: "DEV")
    let argv = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: ["-c", "developer_instructions=fixture"])
    try containerExpect(argv.prefix(4) == ["--host", "unix:///tmp/docker.sock", "create", "--rm"], "daemon was not pinned explicitly")
    try containerExpect(argv.contains("--log-driver=none") && argv.contains("--cap-drop=ALL"), "container defaults gained logging or capabilities")
    try containerExpect(argv.contains("type=bind,source=/project with spaces,target=/project with spaces"), "project path spelling or argument boundaries changed")
    try containerExpect(argv.filter { $0.hasPrefix("type=bind,") }.count == 4, "unexpected host mount")
    // The home volume is never populated from the image: an image that carries
    // /home/parley would otherwise hand root ownership back to the volume on
    // every create while it is empty, undoing the initializer's chown.
    try containerExpect(argv.contains("type=volume,source=parley-home-fixture,target=/home/parley,volume-nocopy=true"), "home volume mount copies the image directory: \(argv)")
    try containerExpect(!argv.contains(where: { $0.contains("PARLEY_RELAY_TOKEN=") }), "credential value leaked into argv")
    try containerExpect(argv.contains("PARLEY_RELAY_TOKEN"), "credential is not passed by environment name")
    for bypass in [["--yolo"], ["--sandbox=danger-full-access"], ["--permission-mode", "bypassPermissions"], ["-c", "sandbox_mode='danger-full-access'"], ["--ask-for-approval=never"]] {
        do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: bypass); throw NSError(domain: "accepted vendor approval bypass", code: 1) }
        catch is ContainerPaneError {}
    }
    var legacy = config; legacy.legacyCodexSandbox = true
    let sandbox = try ContainerLaunchProjection.createArguments(configuration: legacy, facts: facts, vendorArguments: ["sandbox", "--", "/bin/true"])
    try containerExpect(sandbox.firstIndex(of: "features.use_legacy_landlock=true")! < sandbox.firstIndex(of: "--")!,
        "Codex compatibility option was passed to the sandboxed command instead of Codex")
    var unsafe = facts
    unsafe.folder = "/"
    do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: unsafe, vendorArguments: []); throw NSError(domain: "accepted broad root", code: 1) }
    catch is ContainerPaneError {}
    unsafe = facts; unsafe.folder = "/project,readonly"
    do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: unsafe, vendorArguments: []); throw NSError(domain: "accepted mount injection", code: 1) }
    catch is ContainerPaneError {}
    do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: ["--dangerously-skip-permissions"]); throw NSError(domain: "accepted bypass", code: 1) }
    catch is ContainerPaneError {}
    var remote = config; remote.daemonEndpoint = "ssh://host"
    do { _ = try ContainerLaunchProjection.createArguments(configuration: remote, facts: facts, vendorArguments: []); throw NSError(domain: "accepted remote daemon", code: 1) }
    catch is ContainerPaneError {}

    // Every agent vendor has a container form; a Shell pane never does.
    for vendor in PaneKind.allCases where vendor.isAgent {
        var vendorFacts = facts; vendorFacts.vendor = vendor
        let args = try ContainerLaunchProjection.createArguments(configuration: config, facts: vendorFacts, vendorArguments: [])
        try containerExpect(args.contains("/usr/local/bin/\(vendor.rawValue)") && args[args.firstIndex(of: "--entrypoint")! + 1] == "/usr/local/bin/\(vendor.rawValue)", "\(vendor.label) entrypoint is wrong")
        try containerExpect(!args.contains { $0.hasPrefix("COPILOT_") }, "\(vendor.label) received vendor environment nobody passed")
    }
    var shell = facts; shell.vendor = .shell
    do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: shell, vendorArguments: []); throw NSError(domain: "accepted a shell container", code: 1) }
    catch is ContainerPaneError {}
    // Copilot's own skip-all flags are refused as vendor arguments exactly like
    // the other vendors' flags; the review adds --allow-all, nothing else does.
    for bypass in [["--allow-all"], ["--allow-all-tools"], ["--allow-all-paths"], ["--allow-all-urls"], ["--allow-tool=shell(parley)", "--allow-all-tools"]] {
        do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: bypass); throw NSError(domain: "accepted Copilot allow-all", code: 1) }
        catch is ContainerPaneError {}
    }
    _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: ["--allow-tool=shell(parley)"])
    // Vendor environment: one documented key, placed before the image, and
    // nothing else, so a mistaken caller is refused rather than widened.
    var copilotFacts = facts; copilotFacts.vendor = .copilot
    let copilot = try ContainerLaunchProjection.createArguments(configuration: config, facts: copilotFacts, vendorArguments: ["--allow-tool=shell(parley)"],
        vendorEnvironment: ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/runtime/agent-protocol"])
    let entry = copilot.firstIndex(of: "COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/runtime/agent-protocol")
    try containerExpect(entry != nil && copilot[entry! - 1] == "--env" && entry! < copilot.firstIndex(of: config.imageID)!, "Copilot's environment is missing or landed after the image: \(copilot)")
    for environment in [["COPILOT_ALLOW_ALL": "1"], ["PARLEY_COMMAND": "/x"], ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": ""], ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/a\nb"], ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": String(repeating: "x", count: 5000)]] {
        do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: copilotFacts, vendorArguments: [], vendorEnvironment: environment); throw NSError(domain: "accepted vendor environment \(environment)", code: 1) }
        catch is ContainerPaneError {}
    }
}

func checkContainerReceiptStore() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parley-container-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try ContainerPaneService(directory: dir, environment: [:])
    try containerExpect(try store.records().isEmpty, "new container store was not empty")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: dir.appendingPathComponent("container-panes.json"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("container-panes.json").path)
    do { _ = try store.records(); throw NSError(domain: "accepted damaged ownership store", code: 1) }
    catch is DecodingError {}
}

private final class ContainerRecordingRunner: CommandRunning {
    var calls: [[String]] = []
    var daemon = "daemon-one"
    var owner = "owner-fixture"
    var listed = String(repeating: "c", count: 64)
    func run(executable: URL, arguments: [String], environment: [String: String], input: Data?) throws -> CommandOutput {
        calls.append(arguments)
        let text: String
        if arguments.contains("info") { text = daemon }
        else if arguments.contains("ls") { text = listed }
        else if arguments.contains("inspect") { text = owner }
        else { throw NSError(domain: "unexpected Docker mutation", code: 1) }
        return CommandOutput(stdout: Data(text.utf8))
    }
}

func checkContainerOwnershipRefusals() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parley-container-owner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ContainerRecordingRunner()
    let service = try ContainerPaneService(directory: directory, environment: [:], runner: runner)
    let json: [String: Any] = ["owner": "runtime-owner", "records": [["id": "owner-fixture", "paneID": "pane-fixture", "generation": 3,
        "configuration": ["dockerExecutable": "/usr/local/bin/docker", "daemonEndpoint": "unix:///tmp/docker.sock", "daemonID": "daemon-one",
            "imageID": "sha256:" + String(repeating: "b", count: 64), "imageName": "fixture", "legacyCodexSandbox": false],
        "volume": "parley-fixture", "runtime": "DEV", "containerID": String(repeating: "c", count: 64), "removed": false, "createdAt": 0]]]
    let file = directory.appendingPathComponent("container-panes.json")
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    runner.owner = "another-creator"
    do { try service.stop(paneID: "pane-fixture", generation: 3); throw NSError(domain: "accepted foreign owner", code: 1) }
    catch is ContainerPaneError {}
    try containerExpect(!runner.calls.contains { $0.contains("stop") || $0.contains("rm") }, "foreign container was mutated")
    runner.calls = []; runner.daemon = "another-daemon"
    do { try service.stop(paneID: "pane-fixture", generation: 3); throw NSError(domain: "accepted different daemon", code: 1) }
    catch is ContainerPaneError {}
    try containerExpect(runner.calls.count == 1 && runner.calls[0].contains("info"), "daemon identity was not checked first")
    runner.calls = []
    try service.stop(paneID: "pane-fixture", generation: 4)
    try containerExpect(runner.calls.isEmpty, "a different pane generation stopped the old container")
    runner.daemon = "daemon-one"; runner.listed = ""
    try service.stop(paneID: "pane-fixture", generation: 3)
    try containerExpect(try service.records().allSatisfy(\.removed), "confirmed absent container retained running ownership")
    try containerExpect(!runner.calls.contains { $0.contains("stop") || $0.contains("rm") }, "missing container triggered destructive work")
}

private final class ContainerInitFailureRunner: CommandRunning {
    var volumeOwner = ""
    func run(executable: URL, arguments a: [String], environment: [String: String], input: Data?) throws -> CommandOutput {
        var text = ""
        if a.contains("info") { text = "daemon-one" }
        else if a.contains("image") { text = "sha256:" + String(repeating: "b", count: 64) }
        else if a.contains("volume") && a.contains("create") {
            volumeOwner = String((a.first { $0.hasPrefix("com.parley.volume-owner=") } ?? "").dropFirst("com.parley.volume-owner=".count))
        } else if a.contains("volume") && a.contains("inspect") { text = volumeOwner }
        else if a.contains("create") {
            text = String(repeating: "d", count: 64)
            if let index = a.firstIndex(of: "--cidfile") { try text.write(toFile: a[index + 1], atomically: true, encoding: .utf8) }
        } else if a.contains("start") || a.contains("run") { return CommandOutput(status: 124) }
        return CommandOutput(stdout: Data(text.utf8))
    }
}

func checkContainerInitializationReceipt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parley-container-init-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let service = try ContainerPaneService(directory: dir, environment: [:], runner: ContainerInitFailureRunner())
    let configuration = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let pane = WorkbenchPane(id: "pane-fixture", kind: .codex, customName: nil, terminalTitle: "", cwd: "/project", currentCommand: "codex", isActive: true, workspaceID: "workspace")
    do {
        _ = try service.prepare(configuration: configuration, pane: pane, endpoint: "/transport/" + String(repeating: "a", count: 48),
            protocolDirectory: "/protocol", shimDirectory: "/shim", token: String(repeating: "a", count: 48), vendorArguments: [], runtime: "DEV")
        throw NSError(domain: "initializer timeout was accepted", code: 1)
    } catch is ContainerPaneError {}
    try containerExpect(try service.records().contains { $0.containerID == String(repeating: "d", count: 64) && !$0.removed }, "timed-out volume initializer has no retained container ID")
}

private final class ContainerPendingInvocation: @unchecked Sendable {
    private let operation: () throws -> String
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<String, Error>?
    init(_ operation: @escaping () throws -> String) { self.operation = operation }
    func start() { Thread.detachNewThread { self.result = Result { try self.operation() }; self.done.signal() } }
    func wait() throws -> String {
        guard done.wait(timeout: .now() + 20) == .success, let result else { throw NSError(domain: "container consultation timeout", code: 1) }
        return try result.get()
    }
}

private final class ContainerVolumeRunner: CommandRunning {
    func run(executable: URL, arguments: [String], environment: [String: String], input: Data?) throws -> CommandOutput {
        var text = ""
        if arguments.contains("info") { text = "daemon-one" }
        else if arguments.contains("inspect") { text = "runtime-owner" }
        else if arguments.contains("volume") && arguments.contains("ls") { text = "parley-fixture" }
        return CommandOutput(stdout: Data(text.utf8))
    }
}

func checkContainerVolumeDaemonScope() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parley-container-volume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let service = try ContainerPaneService(directory: dir, environment: [:], runner: ContainerVolumeRunner())
    func record(_ suffix: String, _ daemon: String) -> [String: Any] {
        ["id": "owner-" + suffix, "paneID": "pane-fixture", "generation": 1,
         "configuration": ["dockerExecutable": "/usr/local/bin/docker", "daemonEndpoint": "unix:///tmp/" + suffix + ".sock", "daemonID": daemon,
            "imageID": "sha256:" + String(repeating: "b", count: 64), "imageName": "fixture", "legacyCodexSandbox": false],
         "volume": "parley-fixture", "runtime": "DEV", "removed": true, "createdAt": 0]
    }
    let file = dir.appendingPathComponent("container-panes.json")
    try JSONSerialization.data(withJSONObject: ["owner": "runtime-owner", "records": [record("one", "daemon-one"), record("two", "daemon-two")]]).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let before = try service.records()
    try service.deleteLoginState(before[0])
    try containerExpect(try service.records() == [before[1]], "deleting a volume forgot another daemon's identically named volume")
}

func checkContainerInertCreation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parley-container-inert-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = try WorkbenchController(applicationDirectory: directory, environment: ["PATH": "/usr/bin:/bin"])
    try controller.bootstrap(cwd: directory.path)
    let configuration = ContainerConfiguration(dockerExecutable: "/missing/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let pane = try controller.createPane(kind: .codex, cwd: directory.path, containerConfiguration: configuration)
    try containerExpect(!pane.isStarted && !pane.inputAvailable, "container pane claimed to run before preparation")
    do {
        try controller.startPane(pane.id, containerConfiguration: configuration)
        throw NSError(domain: "unprepared container started", code: 1)
    } catch is ContainerPaneError {}
    try containerExpect(try controller.listPanes().first(where: { $0.id == pane.id })?.isStarted == false,
        "failed preparation changed stopped placeholder")
    let data = try JSONEncoder().encode(pane)
    var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    legacy.removeValue(forKey: "containerConfiguration")
    let restored = try JSONDecoder().decode(WorkbenchPane.self, from: JSONSerialization.data(withJSONObject: legacy))
    try containerExpect(restored.containerConfiguration == nil, "older pane gained a container boundary")
}

private final class ContainerLifecycleRunner: CommandRunning, @unchecked Sendable {
    var calls: [[String]] = []
    var daemon = "daemon-one"
    var volumeOwner = ""
    var containers: [String: String] = [:]
    var sequence = 0
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var pauseNextCreate = false
    func run(executable: URL, arguments a: [String], environment: [String: String], input: Data?) throws -> CommandOutput {
        calls.append(a)
        var text = ""
        if a.contains("context") { text = "unix:///tmp/docker.sock" }
        else if a.contains("info") { text = daemon }
        else if a.contains("image") { text = "sha256:" + String(repeating: "b", count: 64) }
        else if a.contains("volume") {
            if a.contains("create") {
                volumeOwner = String((a.first { $0.hasPrefix("com.parley.volume-owner=") } ?? "").dropFirst("com.parley.volume-owner=".count))
            } else if a.contains("inspect") { text = volumeOwner }
        } else if a.contains("create") {
            if pauseNextCreate {
                pauseNextCreate = false
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "test release timed out", code: 1) }
            }
            sequence += 1
            text = String(format: "%064x", sequence)
            containers[text] = String((a.first { $0.hasPrefix("com.parley.owner=") } ?? "").dropFirst("com.parley.owner=".count))
            if let index = a.firstIndex(of: "--cidfile") { try text.write(toFile: a[index + 1], atomically: true, encoding: .utf8) }
        } else if a.contains("start") || a.contains("rm") || a.contains("stop") {
            containers[a.last ?? ""] = nil
        } else if a.contains("ls") {
            if let filter = a.first(where: { $0.hasPrefix("id=") }), containers[String(filter.dropFirst(3))] != nil { text = String(filter.dropFirst(3)) }
        } else if a.contains("inspect") {
            text = a.contains("{{.State.Running}}") ? "false" : (containers[a.last ?? ""] ?? "")
        } else { throw NSError(domain: "unexpected fake Docker argv", code: 1) }
        return CommandOutput(stdout: Data(text.utf8))
    }
}

func checkContainerControllerLifecycle() throws {
    try requireContainerControllerShell()
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-controller-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let project = directory.appendingPathComponent("project"), app = directory.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let runner = ContainerLifecycleRunner()
    let service = try ContainerPaneService(directory: app, environment: [:], runner: runner)
    let controller = try WorkbenchController(applicationDirectory: app, environment: ["PATH": "/usr/bin:/bin"], containerService: service)
    try controller.bootstrap(cwd: project.path)
    let credentials = try RelayCredentials(file: app.appendingPathComponent("relay-tokens.json"))
    controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("relay-url"), shimDirectory: app.appendingPathComponent("bin"),
        transportDirectory: app.appendingPathComponent("relay"), credentials: credentials, runtimeMarker: "DEV"))
    let configuration = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let definition = try PermissionProfileStore(file: app.appendingPathComponent("permission-profiles.json")).profiles().first { $0.id == "default" }!
    let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: project.path, approvedRoots: [])
    let pane = try controller.createPane(kind: .codex, cwd: project.path, permissionProfile: profile, containerConfiguration: configuration)
    runner.pauseNextCreate = true
    let preparation = ContainerPendingInvocation {
        try controller.prepareContainerStart(pane.id, configuration: configuration, permissionProfile: profile)
        return "prepared"
    }
    preparation.start()
    guard runner.entered.wait(timeout: .now() + 5) == .success else { _ = try preparation.wait(); throw NSError(domain: "preparation never reached Docker", code: 1) }
    let reader = ContainerPendingInvocation { String(try controller.listPanes().count) }
    reader.start()
    // wait() is bounded. Always release Docker before propagating a failed assertion.
    let readResult: Result<String, Error>
    do { readResult = .success(try reader.wait()) } catch { readResult = .failure(error) }
    runner.release.signal()
    try containerExpect(try readResult.get() == "2", "Docker held the workbench lock during creation")
    _ = try preparation.wait()
    do {
        try controller.startPane(pane.id, permissionProfile: profile, launchMode: .resume, containerConfiguration: configuration)
        throw NSError(domain: "wrong launch mode consumed prepared container", code: 1)
    } catch is ContainerPaneError {}
    try controller.startPane(pane.id, permissionProfile: profile, containerConfiguration: configuration)
    let active = try controller.listPanes().first { $0.id == pane.id }!
    try containerExpect(active.launchGeneration == pane.launchGeneration + 1 && active.isStarted, "prepared generation did not activate")
    try controller.terminalDidChangeWorkingDirectory(paneID: pane.id, path: "/home/parley")
    try containerExpect(try controller.listPanes().first { $0.id == pane.id }?.cwd == project.path,
        "guest working-directory metadata changed the approved host folder")
    let callCount = runner.calls.count
    let firstLaunch = try controller.launchConfiguration(for: pane.id)
    let secondLaunch = try controller.launchConfiguration(for: pane.id)
    try containerExpect(firstLaunch == secondLaunch && runner.calls.count == callCount, "rendering launch configuration called Docker")
    try containerExpect(firstLaunch.command.contains("sandbox-exec") && firstLaunch.command.contains("--attach"), "Docker attach lost the host client boundary")
    let token = try credentials.token(for: pane.id)
    runner.daemon = "changed-daemon"
    do { try controller.prepareContainerStop(active); throw NSError(domain: "stopped through changed daemon", code: 1) }
    catch is ContainerPaneError {}
    try containerExpect(try credentials.token(for: pane.id) == token, "failed cleanup rotated the active pane credential")
    try containerExpect(try controller.listPanes().first { $0.id == pane.id }?.isStarted == true, "failed cleanup claimed the pane stopped")
    runner.daemon = "daemon-one"
    try controller.prepareContainerStop(active)
    try controller.stopPaneProcess(pane.id, expectedGeneration: nil)
    try controller.prepareContainerStart(pane.id, configuration: configuration, permissionProfile: profile, launchMode: .resume)
    try controller.startPane(pane.id, permissionProfile: profile, launchMode: .resume, containerConfiguration: configuration)
    let restarted = try controller.launchConfiguration(for: pane.id)
    try containerExpect(restarted.generation > firstLaunch.generation && restarted.command != firstLaunch.command, "restart reused the old container ID")
    try controller.prepareAllContainerStops()
    try controller.shutdown()
    do { try controller.startPane(pane.id, permissionProfile: profile); throw NSError(domain: "late launch survived shutdown", code: 1) }
    catch is ParleyWorkbenchError {}
    try containerExpect(runner.containers.isEmpty && (try service.records()).allSatisfy(\.removed), "shutdown left an owned fake container")
}


private final class ContainerReviewFixture {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-review-\(UUID().uuidString)")
    let runner = ContainerLifecycleRunner()
    let service: ContainerPaneService
    let controller: WorkbenchController
    let credentials: RelayCredentials
    let configuration = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    var project: URL { directory.appendingPathComponent("project") }
    var transport: URL { directory.appendingPathComponent("transport") }
    init() throws {
        let app = directory.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("project"), withIntermediateDirectories: true)
        service = try ContainerPaneService(directory: app, environment: [:], runner: runner)
        controller = try WorkbenchController(applicationDirectory: app, environment: ["PATH": "/usr/bin:/bin"], containerService: service)
        credentials = try RelayCredentials(file: app.appendingPathComponent("relay-tokens.json"))
        try controller.bootstrap(cwd: directory.appendingPathComponent("project").path)
        controller.configureRelay(RelayRuntime(infoFile: app.appendingPathComponent("relay-url"), shimDirectory: app.appendingPathComponent("bin"),
            transportDirectory: directory.appendingPathComponent("transport"), credentials: credentials, runtimeMarker: "DEV"))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func profile(folder: String) throws -> EffectivePermissionProfile {
        let definition = try PermissionProfileStore(file: directory.appendingPathComponent("profiles.json")).profiles().first { $0.id == "default" }!
        return try PermissionProfileResolver.resolve(definition: definition, paneFolder: folder, approvedRoots: [])
    }
    func stoppedPane(folder: String) throws -> WorkbenchPane {
        let pane = try controller.createPane(kind: .codex, cwd: folder, permissionProfile: profile(folder: folder))
        try controller.stopPaneProcess(pane.id, expectedGeneration: nil)
        return try controller.listPanes().first { $0.id == pane.id }!
    }
}

func checkContainerPreparedRemovalRecovery() throws {
    try requireContainerControllerShell()
    for recovery in ["close", "host", "container"] {
        let fixture = try ContainerReviewFixture()
        let pane = try fixture.stoppedPane(folder: fixture.project.path)
        let profile = try fixture.profile(folder: pane.cwd)
        try fixture.controller.prepareContainerStart(pane.id, configuration: fixture.configuration, permissionProfile: profile)
        // A real rejected activation leaves a next-generation receipt on a host placeholder.
        do {
            try fixture.controller.startPane(pane.id, permissionProfile: profile, launchMode: .resume, containerConfiguration: fixture.configuration)
            throw NSError(domain: "mismatched activation accepted", code: 1)
        } catch is ContainerPaneError {}
        let record = try fixture.service.records().first { $0.paneID == pane.id && !$0.removed }!
        try containerExpect(record.generation == pane.launchGeneration + 1 && pane.containerConfiguration == nil,
            "fixture did not reach the failed next-generation preparation")
        let token = try fixture.credentials.token(for: pane.id)
        let containers = fixture.runner.containers
        fixture.runner.daemon = "changed-daemon"
        do {
            _ = try fixture.controller.removeRecordedContainer(record)
            throw NSError(domain: "recorded removal accepted a changed daemon", code: 1)
        } catch is ContainerPaneError {}
        try containerExpect(fixture.runner.containers == containers && (try fixture.credentials.token(for: pane.id)) == token,
            "failed recorded removal changed containers or credentials")
        do {
            try fixture.controller.closePane(pane.id)
            throw NSError(domain: "failed removal authorized pane closure", code: 1)
        } catch is ContainerPaneError {}
        fixture.runner.daemon = "daemon-one"
        let recovered = try fixture.controller.removeRecordedContainer(record)
        try containerExpect(recovered?.id == pane.id, "Status Center removal did not recover the prepared-but-never-started pane")
        try containerExpect(fixture.runner.containers.isEmpty, "removal left a fixture container")
        switch recovery {
        case "host":
            try fixture.controller.startPane(pane.id, permissionProfile: profile)
            do {
                try fixture.controller.stopPaneProcess(pane.id, expectedGeneration: recovered!.launchGeneration)
                throw NSError(domain: "late cleanup stopped a replacement host session", code: 1)
            } catch is ContainerPaneError {}
            try containerExpect(try fixture.controller.listPanes().first { $0.id == pane.id }?.isStarted == true, "host restart stayed wedged or was stopped by late cleanup")
        case "container":
            try fixture.controller.prepareContainerStart(pane.id, configuration: fixture.configuration, permissionProfile: profile)
            try fixture.controller.startPane(pane.id, permissionProfile: profile, containerConfiguration: fixture.configuration)
            let active = try fixture.controller.listPanes().first { $0.id == pane.id }!
            try fixture.controller.prepareContainerStop(active)
            try fixture.controller.stopPaneProcess(pane.id, expectedGeneration: nil)
        default:
            try fixture.controller.closePane(pane.id)
            try containerExpect(try !fixture.controller.listPanes().contains { $0.id == pane.id }, "recovered pane could not close")
        }
    }
}

func checkContainerTransportFolderRefusal() throws {
    let fixture = try ContainerReviewFixture()
    let endpoint = fixture.transport.appendingPathComponent(String(repeating: "a", count: 48)).appendingPathComponent("inbox")
    try FileManager.default.createDirectory(at: endpoint, withIntermediateDirectories: true)
    let pane = try fixture.stoppedPane(folder: endpoint.path)
    let token = try fixture.credentials.token(for: pane.id)
    do {
        try fixture.controller.prepareContainerStart(pane.id, configuration: fixture.configuration, permissionProfile: fixture.profile(folder: pane.cwd))
        throw NSError(domain: "container accepted a sibling relay endpoint as its project", code: 1)
    } catch is ContainerPaneError {}
    try containerExpect(fixture.runner.calls.isEmpty, "transport folder reached Docker before refusal")
    try containerExpect(try fixture.credentials.token(for: pane.id) == token, "refusal rotated the pane capability")
    try containerExpect(try fixture.service.records().isEmpty, "refusal created ownership state")
}

func checkContainerControlPathOverlap() throws {
    let fixture = try ContainerReviewFixture()
    let facts = ContainerLaunchFacts(paneID: "pane-fixture", generation: 2, vendor: .codex, folder: "/project",
        endpoint: "/transport/own-endpoint", protocolDirectory: "/runtime/agent-protocol",
        shimDirectory: "/runtime/linux-bin", uid: 501, gid: 20, volume: "parley-home-fixture", owner: "owner-fixture", runtime: "DEV")
    for path in ["/transport", facts.endpoint, facts.protocolDirectory, facts.shimDirectory] {
        for folder in [path, path + "/child", URL(fileURLWithPath: path).deletingLastPathComponent().path] {
            var overlap = facts; overlap.folder = folder
            do {
                _ = try ContainerLaunchProjection.createArguments(configuration: fixture.configuration, facts: overlap, vendorArguments: [])
                throw NSError(domain: "control-path overlap accepted: \(folder)", code: 1)
            } catch is ContainerPaneError {}
        }
    }
    var adjacent = facts; adjacent.folder = "/transport-project"
    _ = try ContainerLaunchProjection.createArguments(configuration: fixture.configuration, facts: adjacent, vendorArguments: [])
}


func checkContainerOldReceiptRemoval() throws {
    try requireContainerControllerShell()
    let fixture = try ContainerReviewFixture()
    let pane = try fixture.stoppedPane(folder: fixture.project.path)
    let profile = try fixture.profile(folder: pane.cwd)
    try fixture.controller.prepareContainerStart(pane.id, configuration: fixture.configuration, permissionProfile: profile)
    let oldRecord = try fixture.service.records().first { $0.paneID == pane.id && !$0.removed }!
    try fixture.controller.prepareContainerStop(pane)
    let removedRecord = try fixture.service.records().first { $0.id == oldRecord.id }!
    var replacement = fixture.configuration
    replacement.daemonID = "daemon-two"
    fixture.runner.daemon = "daemon-two"
    try fixture.controller.prepareContainerStart(pane.id, configuration: replacement, permissionProfile: profile)
    try fixture.controller.startPane(pane.id, permissionProfile: profile, containerConfiguration: replacement)
    let active = try fixture.controller.listPanes().first { $0.id == pane.id }!
    try containerExpect(active.launchGeneration == oldRecord.generation, "replacement must share the unstarted attempt's proposed generation")
    let containers = fixture.runner.containers
    let token = try fixture.credentials.token(for: pane.id)
    let candidate = try fixture.controller.removeRecordedContainer(removedRecord)
    try containerExpect(candidate == nil && fixture.runner.containers == containers, "old receipt removal stopped a newer container at the reused generation")
    try containerExpect(try fixture.credentials.token(for: pane.id) == token, "old receipt removal changed the replacement capability")
    try containerExpect(try fixture.controller.listPanes().first { $0.id == pane.id }?.isStarted == true, "replacement pane lost its running state")
    try fixture.controller.prepareContainerStop(active)
    try fixture.controller.stopPaneProcess(pane.id, expectedGeneration: nil)
}

func checkContainerResponsiveRecords() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-responsive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ContainerLifecycleRunner()
    let service = try ContainerPaneService(directory: directory, environment: [:], runner: runner)
    let config = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let pane = WorkbenchPane(id: "pane-fixture", kind: .codex, customName: nil, terminalTitle: "", cwd: "/project", currentCommand: "codex", isActive: true, workspaceID: "workspace")
    runner.pauseNextCreate = true
    let operation = ContainerPendingInvocation {
        try service.prepare(configuration: config, pane: pane, endpoint: "/transport/endpoint", protocolDirectory: "/protocol",
            shimDirectory: "/shim", token: "fixture", vendorArguments: [], runtime: "DEV")
    }
    operation.start()
    guard runner.entered.wait(timeout: .now() + 3) == .success else { throw NSError(domain: "Docker was not reached", code: 1) }
    let readCompleted = DispatchSemaphore(value: 0)
    let reader = ContainerPendingInvocation { defer { readCompleted.signal() }; return String(try service.records().count) }
    reader.start()
    let responsive = readCompleted.wait(timeout: .now() + 0.5) == .success
    runner.release.signal()
    _ = try operation.wait()
    _ = try reader.wait()
    try containerExpect(responsive, "Status Center record reads waited for Docker")
}

func checkContainerCleanupContinuation() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ContainerRecordingRunner()
    runner.listed = ""
    let service = try ContainerPaneService(directory: directory, environment: [:], runner: runner)
    func record(_ daemon: String) -> [String: Any] {
        ["id": "owner-" + daemon, "paneID": "pane-fixture", "generation": 1,
         "configuration": ["dockerExecutable": "/usr/local/bin/docker", "daemonEndpoint": "unix:///tmp/docker.sock", "daemonID": daemon,
             "imageID": "sha256:" + String(repeating: "b", count: 64), "imageName": "fixture", "legacyCodexSandbox": false],
         "volume": "home-fixture", "runtime": "DEV", "containerID": String(repeating: "a", count: 64), "removed": false, "createdAt": 0]
    }
    let file = directory.appendingPathComponent("container-panes.json")
    try JSONSerialization.data(withJSONObject: ["owner": "runtime-owner", "records": [record("unavailable"), record("daemon-one")]]).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    do { try service.stop(paneID: "pane-fixture"); throw NSError(domain: "cleanup hid its failure", code: 1) }
    catch is ContainerPaneError {}
    let records = try service.records()
    try containerExpect(!records[0].removed && records[1].removed, "first cleanup failure prevented later cleanup")
}

func checkContainerImageUtilities() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-image-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ContainerLifecycleRunner()
    let service = try ContainerPaneService(directory: directory, environment: [:], runner: runner)
    _ = try service.preview(image: "fixture", vendor: .claude, legacyCodexSandbox: false)
    let probes = runner.calls.filter { $0.contains("create") && $0.contains("--network=none") }
    try containerExpect(probes.contains { $0.contains("/bin/sh") && $0.contains(where: { $0.contains("/usr/bin/stat") && $0.contains("/bin/chown") && $0.contains("/proc/sys/kernel/random/uuid") }) },
        "image was accepted without checking the shim and initializer utilities")
}

func checkContainerLinkedWorktree() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-container-worktree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = directory.appendingPathComponent("repository"), tree = directory.appendingPathComponent("linked")
    let git = ProcessCommandRunner()
    func run(_ args: [String]) throws {
        let output = try git.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1"])
        try containerExpect(output.status == 0, "fixture Git failed: \(output.stderrText)")
    }
    try run(["init", repository.path])
    try run(["-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
    try run(["-C", repository.path, "worktree", "add", "-b", "fixture-worktree", tree.path])
    let service = try ContainerPaneService(directory: directory.appendingPathComponent("app"), environment: [:])
    let access = try ContainerGitAccess.inspect(folder: tree.path)
    try containerExpect(access?.commonDirectory == repository.path + "/.git", "shared Git access did not resolve the exact common directory")
    try service.validateFolder(tree.path, protectedDirectories: [directory.appendingPathComponent("app").path], gitAccess: access)
    do { try service.validateFolder(tree.path, protectedDirectories: []); throw NSError(domain: "unreviewed Git access accepted", code: 1) }
    catch is ContainerPaneError {}
    do { try service.validateFolder(tree.path, protectedDirectories: [repository.path], gitAccess: access); throw NSError(domain: "protected Git mount accepted", code: 1) }
    catch is ContainerPaneError {}
    let facts = ContainerLaunchFacts(paneID: "pane-fixture", generation: 1, vendor: .codex, folder: tree.path,
        endpoint: "/transport/endpoint", protocolDirectory: "/protocol", shimDirectory: "/shim", uid: 501, gid: 20,
        volume: "fixture-home", owner: "fixture-owner", runtime: "DEV")
    let config = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock", daemonID: "fixture",
        imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false, gitAccess: access)
    let mounts = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: []).filter { $0.hasPrefix("type=bind") }
    try containerExpect(mounts.count == 5 && mounts.contains("type=bind,source=\(repository.path)/.git,target=\(repository.path)/.git"), "shared Git mount missing")
    try containerExpect(!mounts.contains("type=bind,source=\(repository.path),target=\(repository.path)"), "primary checkout was exposed")
    try FileManager.default.moveItem(at: repository.appendingPathComponent(".git"), to: repository.appendingPathComponent(".oldgit"))
    try FileManager.default.copyItem(at: repository.appendingPathComponent(".oldgit"), to: repository.appendingPathComponent(".git"))
    do { try service.validateFolder(tree.path, protectedDirectories: [], gitAccess: access); throw NSError(domain: "replaced Git identity accepted", code: 1) }
    catch is ContainerPaneError {}
}

func checkContainerTeamController() throws {
    try requireContainerControllerShell()
    let fixture = try ContainerReviewFixture()
    let controller = fixture.controller
    let workspace = try controller.listWorkspaces()[0]
    try controller.setWorkspaceAutomationPolicy(workspace.workspaceID, policy: .askAndDelegate)
    let profile = try fixture.profile(folder: fixture.project.path)
    let lead = try controller.createPane(kind: .claude, cwd: fixture.project.path, permissionProfile: profile)
    let coordinator = TeamSessionCoordinator(authenticate: { $0 == "fixture-token" ? lead.id : nil },
        panes: { try controller.listPanes() }, profiles: { PermissionProfileDefinition.builtIns }, record: { _, _, _ in })
    let proposal = try coordinator.request(token: "fixture-token", proposal: TeamSessionProposal(objective: "fixture",
        folder: fixture.project.path, paneLimit: 1, hours: 1))
    try coordinator.approve(id: proposal.id, revision: proposal.revision, objective: "fixture", folder: fixture.project.path,
        allowedVendors: [.codex], permissionProfileID: profile.definition.id, paneLimit: 1, hours: 1,
        containerConfigurations: ["codex": fixture.configuration])
    let provision = try coordinator.requestPane(token: "fixture-token", kind: .codex, name: "Container member", role: nil)
    coordinator.fulfilProvisions(create: { session, grant, provision in
        try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
    })
    let pending = try coordinator.containerPreparation(id: provision.id)
    try containerExpect(!pending.pane.isStarted && pending.pane.containerConfiguration == fixture.configuration && fixture.runner.calls.isEmpty,
        "team creation ran Docker or lost its reviewed container configuration")
    try controller.prepareContainerStart(pending.pane.id, configuration: fixture.configuration, permissionProfile: profile)
    try coordinator.finishContainerProvision(id: provision.id, activate: { _, pane in
        try controller.startPane(pane.id, permissionProfile: profile, containerConfiguration: fixture.configuration)
        return try controller.listPanes().first { $0.id == pane.id }!
    })
    let started = try controller.listPanes().first { $0.id == pending.pane.id }!
    let members = try coordinator.stop(id: proposal.id, reason: "fixture Stop")
    try containerExpect(members.count == 1 && members[0].owns(started), "team Stop lost the initial activated generation")
    try controller.prepareContainerStop(started)
    try controller.stopPaneProcess(started.id, expectedGeneration: started.launchGeneration)
    try containerExpect(fixture.runner.containers.isEmpty && (try fixture.service.records()).allSatisfy(\.removed), "team Stop left its owned container")
    try containerExpect(try controller.listPanes().first { $0.id == lead.id }?.isStarted == true, "team Stop touched the requesting pane")
}

func checkContainerPreparedBulkStop() throws {
    try requireContainerControllerShell()
    let fixture = try ContainerReviewFixture()
    let pane = try fixture.stoppedPane(folder: fixture.project.path)
    try fixture.controller.prepareContainerStart(pane.id, configuration: fixture.configuration, permissionProfile: fixture.profile(folder: pane.cwd))
    try fixture.controller.prepareAllContainerStops()
    try containerExpect(fixture.runner.containers.isEmpty && (try fixture.service.records()).allSatisfy(\.removed),
        "bulk cleanup skipped a prepared container on a host placeholder")
    try fixture.controller.shutdown()
}

func checkContainerGitReviewRefusals() throws {
    let root = URL(fileURLWithPath: "/private/tmp/parley-container-git-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("parent"), child = root.appendingPathComponent("child")
    let runner = ProcessCommandRunner()
    func git(_ arguments: [String]) throws {
        let result = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1"])
        try containerExpect(result.status == 0, "submodule fixture failed: \(result.stderrText)")
    }
    for repository in [parent, child] {
        try git(["init", repository.path])
        try git(["-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
    }
    try git(["-C", parent.path, "-c", "protocol.file.allow=always", "submodule", "add", child.path, "module"])
    var correctRefusal = false
    do { _ = try ContainerGitAccess.inspect(folder: parent.appendingPathComponent("module").path) }
    catch { correctRefusal = error.localizedDescription.lowercased().contains("submodule") }
    try containerExpect(correctRefusal, "submodule refusal did not explain that submodules are unsupported")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    let planned = try ContainerGitAccess.planned(folder: alias.appendingPathComponent("new-worktree").path, commonDirectory: parent.appendingPathComponent(".git").path)
    try containerExpect(planned.folder == parent.appendingPathComponent("new-worktree").path, "planned worktree kept an alias that can never match the inspected path")
    let existing = try ContainerGitAccess.planned(folder: alias.path, commonDirectory: parent.appendingPathComponent(".git").path)
    try containerExpect(existing.folder == parent.path, "existing reviewed folder did not canonicalize")
}

func checkContainerReviewedBypass() throws {
    let standard = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(standard)) as! [String: Any]
    json["bypassVendorPermissions"] = true
    let reviewed = try JSONDecoder().decode(ContainerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    for (vendor, flag) in [(PaneKind.codex, "--dangerously-bypass-approvals-and-sandbox"), (.claude, "--dangerously-skip-permissions"), (.agy, "--dangerously-skip-permissions"), (.copilot, "--allow-all")] {
        for mode in [AgentLaunchMode.fresh, .resume] {
            let facts = ContainerLaunchFacts(paneID: "pane-fixture", generation: 1, vendor: vendor, folder: "/project",
                endpoint: "/transport/fixture", protocolDirectory: "/runtime/protocol", shimDirectory: "/runtime/bin",
                uid: 501, gid: 20, volume: "fixture-home", owner: "fixture-owner", runtime: "DEV")
            let command = Array(AgentProtocol.command(for: vendor, protocolDirectory: URL(fileURLWithPath: "/runtime/protocol"), launchMode: mode).dropFirst())
            let args = try ContainerLaunchProjection.createArguments(configuration: reviewed, facts: facts, vendorArguments: command)
            guard let image = args.firstIndex(of: reviewed.imageID) else { throw NSError(domain: "missing image", code: 1) }
            try containerExpect(args[image + 1] == flag, "reviewed container bypass flag missing or outside the image command")
            try containerExpect(Array(args.dropFirst(image + 2)) == command, "bypass changed protocol, hooks or Resume arguments")
            try containerExpect(args.contains("--cap-drop=ALL") && args.contains("--security-opt=no-new-privileges=true") && !args.contains("--privileged"), "bypass weakened Docker isolation")
            try containerExpect(args.filter { $0.hasPrefix("type=bind,") }.count == 4, "bypass widened mounts")
            let defaultArgs = try ContainerLaunchProjection.createArguments(configuration: standard, facts: facts, vendorArguments: command)
            try containerExpect(!defaultArgs.contains(flag), "normal container acquired bypass")
            try containerExpect(!AgentProtocol.command(for: vendor, protocolDirectory: URL(fileURLWithPath: "/runtime/protocol"), launchMode: mode).contains(flag), "host command acquired container bypass")
        }
    }
    let roundtrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed)) as! [String: Any]
    try containerExpect(roundtrip["bypassVendorPermissions"] as? Bool == true, "reviewed bypass was lost on persistence")
    json.removeValue(forKey: "bypassVendorPermissions")
    let old = try JSONDecoder().decode(ContainerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    try containerExpect(oldJSON["bypassVendorPermissions"] as? Bool != true, "older configuration acquired bypass")
}

/// A reviewed port forwards one loopback port on the Mac to the same port in
/// the container — enough for a vendor's browser sign-in callback (Codex:
/// 1455) — and nothing else: loopback only, one port, the network mode,
/// mounts and capabilities unchanged, privileged ports refused, and an older
/// record without the field publishing nothing.
func checkContainerPublishedPort() throws {
    let base = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "c", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    let facts = ContainerLaunchFacts(paneID: "pane-fixture", generation: 1, vendor: .codex, folder: "/project",
        endpoint: "/transport/fixture", protocolDirectory: "/runtime/protocol", shimDirectory: "/runtime/bin",
        uid: 501, gid: 20, volume: "fixture-home", owner: "fixture-owner", runtime: "DEV")

    let plain = try ContainerLaunchProjection.createArguments(configuration: base, facts: facts, vendorArguments: [])
    try containerExpect(!plain.contains("--publish") && !plain.contains("-p"), "a container with no reviewed port published one")

    var reviewed = base
    reviewed.publishedPort = 1455
    let args = try ContainerLaunchProjection.createArguments(configuration: reviewed, facts: facts, vendorArguments: [])
    guard let publish = args.firstIndex(of: "--publish") else { throw NSError(domain: "reviewed port 1455 was not published", code: 1) }
    try containerExpect(args[publish + 1] == "127.0.0.1:1455:1455", "the published port is not loopback-only on the same port: \(args[publish + 1])")
    try containerExpect(args.filter { $0 == "--publish" }.count == 1, "more than one port was published")
    try containerExpect(publish < args.firstIndex(of: reviewed.imageID)!, "the port reached the vendor command instead of Docker")
    try containerExpect(args.contains("--network=bridge"), "publishing a port changed the network mode")
    try containerExpect(args.filter { $0.hasPrefix("type=bind,") }.count == 4 && args.contains("--cap-drop=ALL")
        && args.contains("--security-opt=no-new-privileges=true"), "publishing a port widened mounts or capabilities")

    for bad in [0, 80, 443, 1023, 65536, -1] {
        var config = base
        config.publishedPort = bad
        do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: []); throw NSError(domain: "accepted port \(bad)", code: 1) }
        catch is ContainerPaneError {}
    }

    let roundtrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed)) as! [String: Any]
    try containerExpect(roundtrip["publishedPort"] as? Int == 1455, "the reviewed port was lost on persistence")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
    json.removeValue(forKey: "publishedPort")
    let old = try JSONDecoder().decode(ContainerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    try containerExpect(old.publishedPort == nil, "an older configuration acquired a published port")
    try containerExpect(old != reviewed, "a reviewed port does not distinguish the exact configuration")
}

func checkContainerBypassPreflight() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-bypass-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ContainerLifecycleRunner()
    let service = try ContainerPaneService(directory: directory, environment: [:], runner: runner)
    for (vendor, flag) in [(PaneKind.codex, "--dangerously-bypass-approvals-and-sandbox"), (.claude, "--dangerously-skip-permissions"), (.agy, "--dangerously-skip-permissions"), (.copilot, "--allow-all")] {
        runner.calls = []
        let configuration = try service.preview(image: "fixture", vendor: vendor, legacyCodexSandbox: false, bypassVendorPermissions: true)
        let probe = runner.calls.first { $0.contains("create") && $0.contains("--network=none") }!
        try containerExpect(configuration.bypassVendorPermissions && probe.suffix(3) == ["/usr/local/bin/\(vendor.rawValue)", flag, "--version"], "image preflight used an inner sandbox or lost bypass mode")
        try containerExpect(probe.contains { $0.hasPrefix(ContainerLaunchProjection.home + ":") && $0.contains(",exec") && $0.contains("size=") }, "the probe home is noexec or default-sized: Copilot's launcher cannot map its native addon there")
        try containerExpect(!probe.contains("--mount") && !probe.contains("sandbox") && probe.contains(ContainerPaneService.imageUtilityProbe), "bypass probe exposed files or skipped the utility contract")
        try containerExpect((try service.records()).allSatisfy(\.removed), "bypass probe retained a live receipt")
    }
    runner.calls = []
    _ = try service.preview(image: "fixture", vendor: .codex, legacyCodexSandbox: false)
    let normal = runner.calls.first { $0.contains("create") && $0.contains("--network=none") }!
    try containerExpect(normal.suffix(3) == ["sandbox", "--", "/bin/true"], "normal mode stopped checking the inner sandbox")
    runner.calls = []
    do {
        _ = try service.preview(image: "fixture", vendor: .codex, legacyCodexSandbox: true, bypassVendorPermissions: true)
        throw NSError(domain: "conflicting modes accepted", code: 1)
    } catch is ContainerPaneError {}
    try containerExpect(!runner.calls.contains { $0.contains("create") }, "conflicting modes created a container")
}

func checkContainerBypassController() throws {
    try requireContainerControllerShell()
    for (vendor, expectedFlag) in [(PaneKind.codex, "--dangerously-bypass-approvals-and-sandbox"), (.claude, "--dangerously-skip-permissions"), (.agy, "--dangerously-skip-permissions"), (.copilot, "--allow-all")] {
        let fixture = try ContainerReviewFixture()
        let profile = try fixture.profile(folder: fixture.project.path)
        let pane = try fixture.controller.createPane(kind: vendor, cwd: fixture.project.path, permissionProfile: profile)
        try fixture.controller.stopPaneProcess(pane.id, expectedGeneration: nil)
        var reviewed = fixture.configuration; reviewed.bypassVendorPermissions = true
        try fixture.controller.prepareContainerStart(pane.id, configuration: reviewed, permissionProfile: profile, launchMode: .resume)
        let create = fixture.runner.calls.first { $0.contains("create") && $0.contains(reviewed.imageID) && $0.contains("--network=bridge") }!
        try containerExpect(create.contains(expectedFlag), "controller lost reviewed bypass for \(vendor.label)")
        let initializer = fixture.runner.calls.first { $0.contains("create") && $0.contains("/bin/chown") }
        try containerExpect(initializer != nil && initializer!.contains { $0.hasPrefix("type=volume,") && $0.hasSuffix(",volume-nocopy=true") }
            && create.contains { $0.hasPrefix("type=volume,") && $0.hasSuffix(",volume-nocopy=true") },
            "the home initializer or the pane mounts the volume with image copy enabled for \(vendor.label)")
        try containerExpect(!create.contains("--sandbox") && !create.contains("--permission-mode") && !create.contains("--ask-for-approval") && !create.contains("--mode") && !create.contains("--plan"),
            "profile arguments conflicted with bypass for \(vendor.label)")
        // Copilot reads its instructions directory from the environment, so the
        // container carries that one key, before the image, at the protocol
        // mount's own path; no other vendor gets it. Agy's protocol directory
        // travels as its --add-dir argument, after the image.
        let instructions = create.filter { $0.hasPrefix("COPILOT_CUSTOM_INSTRUCTIONS_DIRS=") }
        let imageIndex = create.firstIndex(of: reviewed.imageID)!
        if vendor == .copilot {
            try containerExpect(instructions.count == 1 && instructions[0].hasSuffix("/agent-protocol") && create.firstIndex(of: instructions[0])! < imageIndex
                && create[create.firstIndex(of: instructions[0])! - 1] == "--env", "Copilot's instructions directory did not reach the container as environment: \(create)")
            let mounted = create.first { $0.hasPrefix("type=bind,") && $0.contains("/agent-protocol,") }
            try containerExpect(mounted != nil && instructions[0].hasSuffix(String(mounted!.split(separator: ",")[1].dropFirst("source=".count))),
                "Copilot's instructions path is not the mounted protocol directory")
            try containerExpect(create.contains("--plugin-dir") && create.contains("--allow-tool=shell(parley)"), "Copilot lost its hooks or its Parley allow rule in the container")
        } else {
            try containerExpect(instructions.isEmpty, "\(vendor.label) received Copilot's environment")
        }
        if vendor == .agy {
            let addDir = create.firstIndex(of: "--add-dir")
            try containerExpect(addDir != nil && addDir! > imageIndex && create[addDir! + 1].hasSuffix("/agent-protocol"), "Agy's protocol directory did not follow the image as --add-dir")
        }
        do {
            try fixture.controller.startPane(pane.id, permissionProfile: profile, launchMode: .resume, containerConfiguration: fixture.configuration)
            throw NSError(domain: "changed bypass review activated", code: 1)
        } catch is ContainerPaneError {}
        try fixture.controller.startPane(pane.id, permissionProfile: profile, launchMode: .resume, containerConfiguration: reviewed)
        let started = try fixture.controller.listPanes().first { $0.id == pane.id }!
        try containerExpect(started.containerConfiguration == reviewed && started.permissionEnforcement == .guidanceOnly, "bypass pane falsely advertised enforced profile")
        let saved = try JSONDecoder().decode(WorkbenchPane.self, from: JSONEncoder().encode(started))
        try containerExpect(saved.containerConfiguration?.bypassVendorPermissions == true, "pane persistence lost bypass")
        try fixture.controller.prepareContainerStop(started)
        try fixture.controller.stopPaneProcess(pane.id, expectedGeneration: nil)
        try fixture.controller.startPane(pane.id, permissionProfile: profile)
        let host = try fixture.controller.listPanes().first { $0.id == pane.id }!
        let launch = try fixture.controller.launchConfiguration(for: pane.id)
        // Back on the host the pane shows its vendor's own plan: partially
        // enforced where a launch argument exists, guidance only where none does
        // (Copilot's host plan carries nothing for this profile). Never bypass.
        let hostEnforcement = PermissionProfileAdapter.launchPlan(for: vendor, profile: profile).enforcement
        try containerExpect(host.containerConfiguration == nil && host.permissionEnforcement == hostEnforcement && hostEnforcement != .enforced,
            "return to host kept bypass metadata for \(vendor.label): \(host.permissionEnforcement)")
        let hostMarker = switch vendor {
        case .codex: "default_permissions="
        case .claude: "--permission-mode"
        case .agy: "--mode"
        default: "--allow-tool=shell(parley)"
        }
        try containerExpect(!launch.command.contains(expectedFlag) && launch.command.contains(hostMarker), "container bypass leaked into host launch")
        try fixture.controller.shutdown()
    }
}

/// Real vendor parsing/startup only; no model call, login, project or endpoint mount.
func checkContainerBypassSpike(image: String) throws {
    let directory = URL(fileURLWithPath: "/private/tmp/parley-bypass-spike-\(UUID().uuidString.lowercased())")
    let service = try ContainerPaneService(directory: directory, environment: ["HOME": NSHomeDirectory()])
    do {
        for vendor in PaneKind.allCases where vendor.isAgent {
            let configuration = try service.preview(image: image, vendor: vendor, legacyCodexSandbox: false, bypassVendorPermissions: true)
            try containerExpect(configuration.bypassVendorPermissions && !configuration.legacyCodexSandbox, "real image probe lost bypass selection")
            print("PASS Docker \(vendor.label) bypass startup and Linux utility probe without an inner sandbox")
        }
        try containerExpect((try service.records()).allSatisfy(\.removed), "probe cleanup left a live receipt")
        try FileManager.default.removeItem(at: directory)
    } catch {
        do {
            try service.stopAll()
            try FileManager.default.removeItem(at: directory)
        } catch {
            print("Probe cleanup not confirmed; receipts retained at \(directory.path)")
        }
        throw error
    }
}
