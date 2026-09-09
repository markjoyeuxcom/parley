import Darwin
import Foundation
import ParleyCore

private func containerExpect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "ContainerPaneChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

var containerPaneChecks: [(String, () throws -> Void)] { [
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
    try containerExpect(!argv.contains(where: { $0.contains("PARLEY_RELAY_TOKEN=") }), "credential value leaked into argv")
    try containerExpect(argv.contains("PARLEY_RELAY_TOKEN"), "credential is not passed by environment name")
    for bypass in [["--yolo"], ["--sandbox=danger-full-access"], ["--permission-mode", "bypassPermissions"], ["-c", "sandbox_mode='danger-full-access'"], ["--ask-for-approval=never"]] {
        do { _ = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: bypass); throw NSError(domain: "accepted vendor approval bypass", code: 1) }
        catch is ContainerPaneError {}
    }
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
        if a.contains("info") { text = daemon }
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
    let configuration = ContainerConfiguration(dockerExecutable: "/fixture/docker", daemonEndpoint: "unix:///tmp/docker.sock",
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
    try controller.stopPaneProcess(pane.id)
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
    let configuration = ContainerConfiguration(dockerExecutable: "/fixture/docker", daemonEndpoint: "unix:///tmp/docker.sock",
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
        try controller.stopPaneProcess(pane.id)
        return try controller.listPanes().first { $0.id == pane.id }!
    }
}

func checkContainerPreparedRemovalRecovery() throws {
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
            try fixture.controller.stopPaneProcess(pane.id)
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
    try fixture.controller.stopPaneProcess(pane.id)
}
