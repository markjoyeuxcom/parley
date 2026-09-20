import Darwin
import Foundation
import ParleyCore

private func ticketExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "RelayTicket", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A client for the ticket socket, used from a child process so the kernel
/// reports a real peer and the pane marker sits on a real ancestor.
enum TicketClient {
    static let requestID = "11111111-2222-4333-8444-555555555555"
    static func request(socketPath: String, token: String) throws -> String {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "TicketClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket: \(String(cString: strerror(errno)))"]) }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = Array(socketPath.utf8)
            for index in 0..<min(bytes.count, capacity - 1) { destination[index] = bytes[index] }
            destination[min(bytes.count, capacity - 1)] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw NSError(domain: "TicketClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect: \(String(cString: strerror(errno)))"]) }
        let line = token + " " + requestID + "\n"
        _ = line.withCString { Darwin.send(descriptor, $0, strlen($0), 0) }
        var reply = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < 512 {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress!, 512, 0) }
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[..<count])
        }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An injectable clock the check can move forward.
private final class TicketClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private func ticketDirectory() throws -> URL {
    // Short on purpose: a Unix socket path is limited to 103 bytes.
    let directory = URL(fileURLWithPath: "/tmp/parley-tk-\(getpid())-\(UInt32.random(in: 0...0xffff))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
}

private func checksExecutable() -> URL {
    Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
}

private func ticketPane(id: String, kind: PaneKind, container: Bool = false) -> WorkbenchPane {
    var pane = WorkbenchPane(id: id, kind: kind, customName: kind.label, terminalTitle: "", cwd: "/tmp", currentCommand: kind.rawValue, isActive: true, workspaceID: "ws")
    pane.isStarted = true
    pane.relayEnabled = true
    pane.inputAvailable = true
    pane.protocolVersion = AgentProtocol.version
    if container {
        pane.containerConfiguration = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
            daemonID: "daemon", imageID: "sha256:" + String(repeating: "a", count: 64), imageName: "fixture", legacyCodexSandbox: false)
    }
    return pane
}

/// Which panes must present a ticket: the facts behind the table, observed
/// from real panes on 14 September 2026, never a guess from terminal text.
/// Claude, Copilot and Agy reached the socket and must present one. Codex
/// must present one when its launch profile enables network; a container
/// never has the host socket mounted.
func checkTicketPolicyTable() throws {
    func requirement(_ kind: PaneKind, container: Bool = false, listening: Bool = true) -> RelayTicketPolicy.Requirement {
        RelayTicketPolicy.policy(kind: kind, inContainer: container, socketListening: listening).requirement
    }
    try ticketExpect(requirement(.claude) == .required && requirement(.copilot) == .required && requirement(.agy) == .required,
        "a host vendor observed reaching the socket is not required to present a ticket")
    try ticketExpect(requirement(.codex) == .optional, "a Codex pane of unknown profile is not optional")
    let networked = RelayTicketPolicy.policy(kind: .codex, inContainer: false, socketListening: true, codexNetworkAllowed: true)
    try ticketExpect(networked.requirement == .required && networked.reason.contains("network"), "a Codex pane whose profile enables network is not required: \(networked.reason)")
    let closed = RelayTicketPolicy.policy(kind: .codex, inContainer: false, socketListening: true, codexNetworkAllowed: false)
    try ticketExpect(closed.requirement == .optional && closed.reason.contains("escalation"), "a Codex pane without network is not optional with the escalation reason: \(closed.reason)")
    try ticketExpect(RelayTicketPolicy.policy(kind: .codex, inContainer: true, socketListening: true, codexNetworkAllowed: true).requirement == .unavailable, "network changed a container's policy")
    try ticketExpect(RelayTicketPolicy.policy(kind: .claude, inContainer: false, socketListening: true, codexNetworkAllowed: false).requirement == .required, "the Codex network rule leaked into another vendor")
    for kind in [PaneKind.claude, .codex, .agy, .copilot] {
        try ticketExpect(requirement(kind, container: true) == .unavailable, "\(kind.label) in a container is expected to reach an unmounted socket")
        try ticketExpect(requirement(kind, listening: false) == .unavailable, "\(kind.label) is required to present a ticket while no socket listens")
    }
    try ticketExpect(requirement(.shell) == .unavailable, "a shell pane has a ticket policy")
    let policy = RelayTicketPolicy.policy(for: ticketPane(id: "p", kind: .codex), socketListening: true)
    try ticketExpect(policy.reason.contains("not known"), "an unknown Codex profile did not say so: \(policy.reason)")
    var networkedPane = ticketPane(id: "p", kind: .codex)
    networkedPane.permissionSelection = PermissionProfileSelection(profileID: "flexible-network", approvedRoots: ["/tmp"], lifetime: .session, approvals: .person)
    try ticketExpect(RelayTicketPolicy.policy(for: networkedPane, socketListening: true, networkAllowed: true).requirement == .required, "the pane-level policy ignored the network answer")
    // whoami bounds its strings to 160 characters; a fixed reason must survive that whole.
    for kind in PaneKind.allCases {
        for (container, listening) in [(false, true), (true, true), (false, false)] {
            let reason = RelayTicketPolicy.policy(kind: kind, inContainer: container, socketListening: listening).reason
            try ticketExpect(reason.count <= 160, "\(kind.label)'s reason would be cut by whoami (\(reason.count) characters): \(reason)")
        }
    }
}

/// A caller's markers cannot replace those on the app-owned launch root.
func checkTicketAncestry() throws {
    let directory = try ticketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
    let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 200, 200: 100, 700: 600, 600: 100, 800: 1, 901: 900, 900: 100]
    let markers: [Int32: String] = [500: "pane-b", 300: "pane-a", 600: "pane-b", 800: "pane-a", 901: "pane-a"]
    let generations: [Int32: String] = [500: "1", 300: "3", 600: "1", 800: "3", 901: "3"]
    let idKey = PaneProcessAnchorProjection.markerKey
    let server = RelayTicketServer(socketFile: directory.appendingPathComponent("unused.sock"), credentials: credentials, applicationPID: 100,
        paneGeneration: { _ in nil }, markerValue: { key, pid in key == idKey ? markers[pid] : generations[pid] },
        parentPID: { parents[$0] }, isLaunchIntermediate: { $0 == 200 })
    try ticketExpect(server.attest(peerPID: 500, paneID: "pane-a", generation: 3), "a valid launch root was not admitted")
    try ticketExpect(!server.attest(peerPID: 500, paneID: "pane-b", generation: 1), "a child impersonated another pane with its environment")
    try ticketExpect(!server.attest(peerPID: 800, paneID: "pane-a", generation: 3), "a matching marker outside the app's tree was accepted")
    try ticketExpect(!server.attest(peerPID: 901, paneID: "pane-a", generation: 3), "an unreadable launch root fell back to a child's assertion")
    try ticketExpect(!server.attest(peerPID: 500, paneID: "pane-a", generation: 4), "a stale generation was admitted")
    try ticketExpect(server.attest(peerPID: 700, paneID: "pane-b", generation: 1), "a direct app-owned launch root was refused")
    for peer: Int32 in [0, 1, 100, 999] {
        try ticketExpect(!server.attest(peerPID: peer, paneID: "pane-a", generation: 3), "an invalid or unknown peer was admitted")
    }
    let cycle = RelayTicketServer(socketFile: directory.appendingPathComponent("unused.sock"), credentials: credentials, applicationPID: 100,
        paneGeneration: { _ in nil }, markerValue: { _, _ in "pane-a" }, parentPID: { $0 == 7 ? 8 : 7 })
    try ticketExpect(!cycle.attest(peerPID: 7, paneID: "pane-a", generation: 0), "a parent cycle was admitted")
}

/// The socket, end to end: a child of this process that carries the marker
/// is issued a ticket the kernel can attribute; one without is refused; a
/// ticket redeems once, for its own capability, within its lifetime.
func checkTicketSocketIssuesAndRedeems() throws {
    let directory = try ticketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
    let token = try credentials.token(for: "pane-a")
    let other = try credentials.token(for: "pane-b")
    let clock = TicketClock()
    let server = RelayTicketServer(socketFile: directory.appendingPathComponent("t.sock"), credentials: credentials,
        paneGeneration: { $0 == "pane-a" ? 2 : $0 == "pane-b" ? 5 : nil }, clock: { clock.now })
    try server.start()
    defer { server.stop() }
    try ticketExpect(server.isListening && server.startFailure == nil, "the socket is not listening: \(server.startFailure ?? "")")
    let runner = ProcessCommandRunner(timeout: 10)
    let base = ProcessInfo.processInfo.environment
    func ask(marker: String?, presenting: String, generation: String? = "2") throws -> String {
        var environment = base
        environment[PaneProcessAnchorProjection.markerKey] = marker
        environment[RelayTicketServer.generationMarkerKey] = generation
        let result = try runner.run(executable: checksExecutable(),
            arguments: ["--ticket-client", server.socketFile.path, "--ticket-token", presenting], environment: environment, input: nil)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let ticket = try ask(marker: "pane-a", presenting: token)
    try ticketExpect(ticket.count == 48 && ticket.allSatisfy(\.isHexDigit), "a marked descendant was not issued a ticket: \(ticket)")
    try ticketExpect(!server.redeem(ticket, token: other, requestID: TicketClient.requestID), "a ticket redeemed for another capability")
    try ticketExpect(!server.redeem(ticket, token: token, requestID: UUID().uuidString), "a ticket copied to another request redeemed")
    try ticketExpect(server.redeem(ticket, token: token, requestID: TicketClient.requestID), "a fresh ticket did not redeem for its own request")
    try ticketExpect(!server.redeem(ticket, token: token, requestID: TicketClient.requestID), "a ticket redeemed twice")
    try ticketExpect(try ask(marker: nil, presenting: token).hasPrefix("refused:"), "an unmarked process was issued a ticket")
    try ticketExpect(try ask(marker: "pane-b", presenting: token).hasPrefix("refused:"), "a process of another pane was issued a ticket for this one")
    try ticketExpect(try ask(marker: "pane-a", presenting: "not-a-capability").hasPrefix("refused:"), "an unknown capability was issued a ticket")
    try ticketExpect(try ask(marker: "pane-a", presenting: token, generation: "1").hasPrefix("refused:"), "a process of an earlier launch generation was issued a ticket")
    try ticketExpect(try ask(marker: "pane-a", presenting: token, generation: nil).hasPrefix("refused:"), "a process without a generation marker was issued a ticket")
    let expiring = try ask(marker: "pane-a", presenting: token)
    clock.advance(by: RelayTicketServer.ticketLifetime + 1)
    try ticketExpect(!server.redeem(expiring, token: token, requestID: TicketClient.requestID), "an expired ticket redeemed")
    try ticketExpect(server.issuedCount == 2 && server.refusedCount == 5, "counts are wrong: issued \(server.issuedCount), refused \(server.refusedCount)")
    server.stop()
    try ticketExpect(!server.isListening && !FileManager.default.fileExists(atPath: server.socketFile.path), "stop left the socket behind")
    let tooLong = RelayTicketServer(socketFile: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock"), credentials: credentials, paneGeneration: { _ in nil })
    do { try tooLong.start(); throw NSError(domain: "long path accepted", code: 1) } catch is RelayFileTransportError {}
    try ticketExpect(!tooLong.isListening && tooLong.startFailure?.contains("longer") == true, "a too-long socket path was not reported")
}

/// The whole path through the real shim: a Claude host pane must present a
/// ticket, and does when its shell descends from a marked process; without
/// the marker the shim gets no ticket and the transport refuses; a Codex pane
/// is served token-only when no ticket arrives; with no socket every pane is
/// token-only and says so.
func checkTicketsThroughTheShim() throws {
    let directory = try ticketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
    let claudeToken = try credentials.token(for: "pane-claude")
    let codexToken = try credentials.token(for: "pane-codex")
    let panes = [ticketPane(id: "pane-claude", kind: .claude), ticketPane(id: "pane-codex", kind: .codex)]
    let broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in })
    let transportDirectory = directory.appendingPathComponent("t", isDirectory: true)
    let server = RelayTicketServer(socketFile: RelayTicketServer.socketURL(transportDirectory: transportDirectory), credentials: credentials,
        paneGeneration: { id in panes.first { $0.id == id }?.launchGeneration })
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let shim = shimDirectory.appendingPathComponent("parley").path
    let script = try String(contentsOfFile: shim, encoding: .utf8)
    try ticketExpect(script.contains(server.socketFile.path) && script.contains("request_ticket") && script.contains("/usr/bin/nc -U"), "the host shim does not ask the ticket socket")
    let linuxShim = try RelayShim.installCommand(in: directory.appendingPathComponent("linux-bin"), transportDirectory: transportDirectory, platform: .linux)
    let linuxScript = try String(contentsOfFile: linuxShim.path, encoding: .utf8)
    try ticketExpect(linuxScript.contains("ticket_socket=''"), "the container shim carries a ticket socket path it cannot reach")

    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory, tickets: server)
    try transport.start()
    defer { transport.stop() }
    try server.start()
    defer { server.stop() }
    let runner = ProcessCommandRunner(timeout: 15)
    func whoami(token: String, marker: String?, generation: String? = "0") throws -> (status: Int32, identity: RelayAgentIdentity?, stderr: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["PARLEY_RELAY_TOKEN"] = token
        environment[PaneProcessAnchorProjection.markerKey] = marker
        environment[RelayTicketServer.generationMarkerKey] = generation
        // A marked parent stays alive above the shell that runs the shim, as
        // the vendor process does above a real pane's shell.
        let result = try runner.run(executable: checksExecutable(), arguments: ["--run-marked", "/bin/sh", shim, "whoami"], environment: environment, input: nil)
        let identity = try? JSONDecoder().decode(RelayAgentIdentity.self, from: result.stdout)
        // The shim prints a refusal body on stdout with a non-zero status; keep both streams for the message.
        return (Int32(result.status), identity, String(decoding: result.stderr, as: UTF8.self) + String(decoding: result.stdout, as: UTF8.self))
    }
    let attested = try whoami(token: claudeToken, marker: "pane-claude")
    try ticketExpect(attested.status == 0 && attested.identity?.attestation == "peer-verified" && attested.identity?.ticketPolicy == "required",
        "a marked Claude pane was not peer-verified: status \(attested.status) \(attested.identity?.attestation ?? "nil") \(attested.stderr)")
    let stale = try whoami(token: claudeToken, marker: "pane-claude", generation: "7")
    try ticketExpect(stale.status != 0 && stale.stderr.contains("ticket is required"), "a process of an earlier generation of the Claude pane was served: status \(stale.status) \(stale.stderr)")
    let unmarked = try whoami(token: claudeToken, marker: nil)
    try ticketExpect(unmarked.status != 0 && unmarked.stderr.contains("ticket is required"), "an unmarked caller with a Claude capability was served: status \(unmarked.status) \(unmarked.stderr)")
    let codex = try whoami(token: codexToken, marker: nil)
    try ticketExpect(codex.status == 0 && codex.identity?.attestation == "token-only" && codex.identity?.ticketPolicy == "optional"
        && codex.identity?.ticketPolicyReason?.contains("Codex") == true, "a Codex pane without a ticket was not served token-only as optional: \(codex.identity?.ticketPolicyReason ?? codex.stderr)")
    let codexAttested = try whoami(token: codexToken, marker: "pane-codex")
    try ticketExpect(codexAttested.status == 0 && codexAttested.identity?.attestation == "peer-verified" && codexAttested.identity?.ticketPolicy == "optional",
        "a Codex pane that could reach the socket was not peer-verified: \(codexAttested.identity?.attestation ?? codexAttested.stderr)")
    server.stop()
    let noSocket = try whoami(token: claudeToken, marker: nil)
    try ticketExpect(noSocket.status == 0 && noSocket.identity?.attestation == "token-only" && noSocket.identity?.ticketPolicy == "unavailable",
        "with no socket a Claude pane was not served token-only: status \(noSocket.status) \(noSocket.stderr)")
}

/// Claude's own sandbox switch, read where Claude reads it and in its
/// precedence; a pane under that sandbox is asked for a ticket, not required
/// to present one, because the sandbox denies Unix sockets by default.
func checkClaudeSandboxFactAndPolicy() throws {
    let root = try ticketDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let folder = root.appendingPathComponent("project", isDirectory: true)
    let managed = root.appendingPathComponent("managed.json")
    for directory in [home.appendingPathComponent(".claude"), folder.appendingPathComponent(".claude")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func write(_ file: URL, _ text: String) throws { try Data(text.utf8).write(to: file) }
    func fact(environment: [String: String] = [:]) -> ClaudeSandboxFact {
        ClaudeHostConfiguration.sandbox(folder: folder.path, home: home, managedFile: managed, environment: environment)
    }
    let user = home.appendingPathComponent(".claude/settings.json")
    let project = folder.appendingPathComponent(".claude/settings.json")
    let local = folder.appendingPathComponent(".claude/settings.local.json")

    try ticketExpect(fact() == .unset, "no settings at all reported a sandbox value")
    try write(user, #"{"model": "x", "sandbox": {"enabled": true, "allowUnixSockets": []}}"#)
    try ticketExpect(fact().enabled == true && fact().source == user.path, "the person's settings did not enable the sandbox")
    try write(project, #"{"sandbox": {"enabled": false}}"#)
    try ticketExpect(fact().enabled == false && fact().source == project.path, "project settings did not outrank the person's")
    try write(local, #"{"sandbox": {"enabled": true}}"#)
    try ticketExpect(fact().enabled == true && fact().source == local.path, "local project settings did not outrank shared project settings")
    try ticketExpect(fact(environment: [ClaudeHostConfiguration.forceEnvironmentKey: "1"]).source == ClaudeHostConfiguration.forceEnvironmentKey, "the force variable did not outrank project settings")
    try write(managed, #"{"sandbox": {"enabled": false}}"#)
    try ticketExpect(fact(environment: [ClaudeHostConfiguration.forceEnvironmentKey: "1"]).enabled == false, "managed settings did not outrank everything")
    try FileManager.default.removeItem(at: managed)
    try write(local, "{ not json")
    try ticketExpect(fact().enabled == false && fact().source == project.path, "an unreadable local file was not skipped for the next source")
    try write(local, #"{"sandbox": "yes"}"#)
    try ticketExpect(fact().source == project.path, "a sandbox value of the wrong shape was not skipped")
    try write(local, #"{"sandbox": {"enabled": true}}"#)

    let on = RelayTicketPolicy.policy(kind: .claude, inContainer: false, socketListening: true, claudeSandbox: fact())
    try ticketExpect(on.requirement == .optional && on.reason.contains(local.path) && on.reason.contains("allowUnixSockets"), "a Claude pane under its own sandbox was still required to present a ticket: \(on.reason)")
    let off = RelayTicketPolicy.policy(kind: .claude, inContainer: false, socketListening: true, claudeSandbox: ClaudeSandboxFact(enabled: false, source: project.path))
    try ticketExpect(off.requirement == .required, "a Claude pane whose sandbox is off was not required to present a ticket")
    let unknown = RelayTicketPolicy.policy(kind: .claude, inContainer: false, socketListening: true, claudeSandbox: .unset)
    try ticketExpect(unknown.requirement == .required, "an unset sandbox changed the policy")
    let container = RelayTicketPolicy.policy(kind: .claude, inContainer: true, socketListening: true, claudeSandbox: fact())
    try ticketExpect(container.requirement == .unavailable && container.reason.contains("container"), "a container pane's reason was replaced by the host sandbox")
    var pane = ticketPane(id: "pane-sb", kind: .claude)
    pane.cwd = folder.path
    try ticketExpect(RelayTicketPolicy.policy(for: pane, socketListening: true).requirement == .required,
        "mutable project settings relaxed policy without a launch snapshot")
    try ticketExpect(RelayTicketPolicy.policy(for: pane, socketListening: true, claudeSandbox: fact()).requirement == .optional,
        "the pane-level policy ignored the supplied launch snapshot")
}

@MainActor
let relayTicketChecks: [(String, () throws -> Void)] = [
    ("Claude's own sandbox setting is read in Claude's precedence and relaxes the ticket policy", checkClaudeSandboxFactAndPolicy),
    ("ticket policy follows the pane's sandbox facts, never a guess", checkTicketPolicyTable),
    ("ticket ancestry admits a marked descendant and nothing else", checkTicketAncestry),
    ("the ticket socket issues to a kernel-attributed descendant and redeems once", checkTicketSocketIssuesAndRedeems),
    ("tickets travel through the real shim and are required, optional or unavailable by policy", checkTicketsThroughTheShim),
]
