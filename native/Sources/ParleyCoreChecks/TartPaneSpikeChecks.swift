import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import ParleyCore

/// Explicit real-Tart/real-Ghostty spike for agent panes inside a Tart VM,
/// never counted as a passing skipped check. It answers the two unproven parts
/// of that idea: whether Parley's file transport works through Tart's virtio-fs
/// directory shares mounted at their host paths, and whether a Ghostty surface
/// running `tart exec -i -t` carries resize, Control-C and hidden input.
///
/// The named VM is never booted or changed. It must be stopped; the spike
/// clones it (copy-on-write, with Tart's automatic pruning of cached images
/// off), boots the clone with exactly the fixture's shares, and deletes it.
/// A disposable broker and credentials only: no installed pane, vendor
/// session or credential takes part. Fixture tokens ride `tart exec`'s argv,
/// because `tart exec` forwards no environment; a product would need
/// another channel for a pane's credential. Guest commands run on worker
/// threads as well as this one, so only the Ghostty part is main-actor work.
func checkTartPaneSpike(vm sourceVM: String, tart: String) throws {
    let fm = FileManager.default
    try tartExpect(fm.isExecutableFile(atPath: tart), "no Tart executable at \(tart); pass --tart <path>")
    try GhosttyLaunchPreflight.check()
    let runner = ProcessCommandRunner(timeout: 60, maximumCapturedBytes: 200_000)
    let environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "TART_NO_AUTO_PRUNE": "1"]
    func tartRun(_ arguments: [String], timeout: TimeInterval = 60) throws -> CommandOutput {
        try ProcessCommandRunner(timeout: timeout, maximumCapturedBytes: 200_000)
            .run(executable: URL(fileURLWithPath: tart), arguments: arguments, environment: environment)
    }
    func listedVMs() throws -> [[String: Any]] {
        let listing = try tartRun(["list", "--format", "json"])
        try tartExpect(listing.status == 0, "tart list failed: \(listing.stderrText)")
        return (try JSONSerialization.jsonObject(with: listing.stdout) as? [[String: Any]]) ?? []
    }
    guard let source = try listedVMs().first(where: { $0["Name"] as? String == sourceVM }) else {
        throw tartFailure("no local Tart VM named \(sourceVM); `tart list` names the candidates")
    }
    try tartExpect(source["Running"] as? Bool != true,
        "\(sourceVM) is running; stop it (tart stop \(sourceVM)) or name a stopped VM, because a running disk is not cloned")

    let suffix = String(UUID().uuidString.lowercased().prefix(8))
    let clone = "parley-tart-spike-\(suffix)"
    let root = URL(fileURLWithPath: "/private/tmp/parley-tart-spike-\(suffix)")
    let project = root.appendingPathComponent("project")
    let transportRoot = root.appendingPathComponent("transport")
    try fm.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let credentials = try RelayCredentials(file: root.appendingPathComponent("credentials.json"))
    let sourcePane = WorkbenchPane(id: "tart-source", kind: .codex, customName: "Source", terminalTitle: "", cwd: project.path,
        currentCommand: "codex", isActive: false, workspaceID: "spike", relayEnabled: true,
        protocolVersion: AgentProtocol.version, inputAvailable: true)
    let targetPane = WorkbenchPane(id: "tart-target", kind: .claude, customName: "Target", terminalTitle: "", cwd: project.path,
        currentCommand: "claude", isActive: false, workspaceID: "spike", relayEnabled: true,
        protocolVersion: AgentProtocol.version, inputAvailable: true)
    let broker = RelayBroker(credentials: credentials, panes: { [sourcePane, targetPane] }, paste: { _, _ in }, submit: { _, _ in },
        contextReviewStore: try AgentContextReviewStore(file: root.appendingPathComponent("context.json")))
    let sourceToken = try credentials.token(for: sourcePane.id)
    let targetToken = try credentials.token(for: targetPane.id)
    let outsiderToken = try credentials.token(for: "tart-outsider")
    for token in [sourceToken, targetToken, outsiderToken] {
        _ = try RelayFileTransport.prepareEndpoint(runtimeDirectory: transportRoot, paneToken: token)
    }
    let shim = try RelayShim.installCommand(in: root.appendingPathComponent("bin"), transportDirectory: transportRoot)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportRoot)
    try transport.start()
    defer { transport.stop() }

    // Each share is one exact folder under its own tag, the way a container
    // pane bind-mounts four exact folders. The outsider's endpoint is not
    // shared. Paths here carry no ':' or ',', which `--dir` would misread.
    let shares: [(tag: String, path: String, readOnly: Bool)] = [
        ("parley-project", project.path, false),
        ("parley-source", transportRoot.appendingPathComponent(sourceToken).path, false),
        ("parley-target", transportRoot.appendingPathComponent(targetToken).path, false),
        ("parley-bin", shim.deletingLastPathComponent().path, true),
    ]

    let cloned = try tartRun(["clone", sourceVM, clone], timeout: 600)
    try tartExpect(cloned.status == 0, "could not clone \(sourceVM): \(cloned.stderrText)")
    defer {
        let stop = try? tartRun(["stop", clone], timeout: 90)
        let delete = try? tartRun(["delete", clone], timeout: 120)
        let remaining = (try? listedVMs())?.contains(where: { $0["Name"] as? String == clone }) ?? true
        if remaining || delete?.status != 0 {
            print("Tart spike cleanup was not confirmed: VM \(clone) may remain (stop \(stop?.status ?? -1), delete \(delete?.status ?? -1)); remove it with `tart delete \(clone)`")
        } else {
            print("PASS disposable VM \(clone) stopped and deleted")
        }
    }
    print("PASS cloned \(sourceVM) to \(clone) without automatic pruning")

    let boot = TartPendingInvocation {
        try tartRun(["run", "--no-graphics"] + shares.map { "--dir=\($0.path):\($0.readOnly ? "ro," : "")tag=\($0.tag)" } + [clone],
            timeout: 1800)
    }
    boot.start()
    func guest(_ argv: [String], timeout: TimeInterval = 30) throws -> CommandOutput {
        try tartRun(["exec", clone] + argv, timeout: timeout)
    }
    let bootDeadline = Date().addingTimeInterval(300)
    var ready = false
    while Date() < bootDeadline {
        if let finished = boot.finished {
            throw tartFailure("\(clone) stopped while booting (Apple allows two macOS VMs running at once): \(finished)")
        }
        if let probe = try? guest(["/usr/bin/true"], timeout: 10), probe.status == 0 { ready = true; break }
        Thread.sleep(forTimeInterval: 2)
    }
    try tartExpect(ready, "\(clone)'s Tart Guest Agent did not answer within five minutes")
    let exitProbe = try guest(["/bin/sh", "-c", "exit 3"])
    try tartExpect(exitProbe.status == 3, "tart exec reported \(exitProbe.status) for a guest exit status of 3")
    let inherited = try ProcessCommandRunner(timeout: 30).run(executable: URL(fileURLWithPath: tart),
        arguments: ["exec", clone, "/bin/sh", "-c", "printf %s \"${PARLEY_TART_PROBE:-unset}\""],
        environment: environment.merging(["PARLEY_TART_PROBE": "host"]) { $1 })
    try tartExpect(inherited.stdoutText == "unset", "tart exec now forwards the host environment: \(inherited.stdoutText)")
    print("PASS \(clone) booted with \(shares.count) shares; tart exec returns the guest's exit status and forwards no host environment")

    // Mount every share at its host path, as an unprivileged guest user
    // first; the spike reports whether that needed the guest's root.
    var mountedWith: Set<String> = []
    for share in shares {
        let made = try guest(["/bin/mkdir", "-p", share.path])
        try tartExpect(made.status == 0, "could not make the mount point \(share.path) in the guest: \(made.stderrText)")
        if try guest(["/sbin/mount_virtiofs", share.tag, share.path]).status == 0 {
            mountedWith.insert("the guest user")
        } else {
            let privileged = try guest(["/usr/bin/sudo", "-n", "/sbin/mount_virtiofs", share.tag, share.path])
            try tartExpect(privileged.status == 0, "mount_virtiofs \(share.tag) at \(share.path) failed, with or without sudo: \(privileged.stderrText)")
            mountedWith.insert("root (sudo)")
        }
    }
    print("PASS shares mounted at their host paths by \(mountedWith.sorted().joined(separator: " and "))")

    let hostMarker = project.appendingPathComponent("from-host")
    try "host".write(to: hostMarker, atomically: true, encoding: .utf8)
    let readBack = try guest(["/bin/cat", hostMarker.path])
    try tartExpect(readBack.status == 0 && readBack.stdoutText == "host", "the guest could not read the host's file at the same path: \(readBack.stderrText)")
    let written = try guest(["/bin/sh", "-c", "printf guest > \"$1\"", "sh", project.appendingPathComponent("from-guest").path])
    try tartExpect(written.status == 0, "the guest could not write the project share: \(written.stderrText)")
    try tartExpect((try? String(contentsOf: project.appendingPathComponent("from-guest"), encoding: .utf8)) == "guest", "the guest's file did not reach the host")
    let readOnly = try guest(["/bin/sh", "-c", "printf x > \"$1\"", "sh", shim.deletingLastPathComponent().appendingPathComponent("written").path])
    try tartExpect(readOnly.status != 0, "the read-only shim share accepted a write")
    let guestUID = try guest(["/usr/bin/id", "-u"]).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    let endpointFacts = try guest(["/usr/bin/stat", "-f", "%u %Lp", shares[1].path]).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    print("PASS same-path files cross both ways, the shim share is read-only; guest uid \(guestUID) sees its endpoint as owner and mode \(endpointFacts) (host uid \(getuid()))")

    // Parley's agent Seatbelt boundary wraps the host Docker client; say
    // whether the Tart client can run inside it. A finding, not a gate.
    let app = root.appendingPathComponent("app")
    let protocolFolder = try AgentProtocol.install(in: app)
    let boundary = try AgentProcessBoundary(applicationDirectory: app, protocolDirectory: protocolFolder,
        shimDirectory: shim.deletingLastPathComponent(), protectedControlEndpoint: app.appendingPathComponent("relay.sock"),
        transportDirectory: transportRoot, paneToken: sourceToken)
    let bounded = boundary.arguments + [tart, "exec", clone, "/usr/bin/true"]
    let boundedRun = try runner.run(executable: URL(fileURLWithPath: bounded[0]), arguments: Array(bounded.dropFirst()), environment: environment)
    print(boundedRun.status == 0
        ? "PASS the Tart client runs inside Parley's agent Seatbelt boundary"
        : "NOTE the Tart client fails inside Parley's agent Seatbelt boundary (\(boundedRun.status)): \(boundedRun.stderrText.prefix(300))")

    try MainActor.assumeIsolated {
        try checkTartGhosttyTerminal(tart: tart, clone: clone, project: project)
    }

    // How the guest sees a file the Mac keeps changing, rewritten in place
    // (one inode) or replaced by rename (a new inode, as every heartbeat is).
    // Each reading is mtime:inode:content; the third column looks the
    // replaced file up again after listing its folder.
    let inPlace = project.appendingPathComponent("probe-in-place")
    let replaced = project.appendingPathComponent("probe-replaced")
    try "0".write(to: inPlace, atomically: false, encoding: .utf8)
    try "0".write(to: replaced, atomically: true, encoding: .utf8)
    let writer = TartPendingInvocation<Void> {
        for beat in 1...16 {
            Thread.sleep(forTimeInterval: 0.5)
            let handle = try FileHandle(forWritingTo: inPlace)
            try handle.write(contentsOf: Data(String(format: "%02d", beat).utf8))
            try handle.close()
            try String(format: "%02d", beat).write(to: replaced, atomically: true, encoding: .utf8)
        }
    }
    writer.start()
    var readings: [[String]] = []
    for index in 0..<5 {
        if index > 0 { Thread.sleep(forTimeInterval: 1.2) }
        let reading = try guest(["/bin/sh", "-c", """
            look() { printf '%s:%s' "$(/usr/bin/stat -f '%m:%i' "$1")" "$(/bin/cat "$1")"; }
            a=$(look "$1"); b=$(look "$2"); /bin/ls -la "$3" >/dev/null; c=$(look "$2"); printf '%s %s %s' "$a" "$b" "$c"
            """, "sh", inPlace.path, replaced.path, project.path])
        readings.append(reading.stdoutText.split(separator: " ").map(String.init))
    }
    _ = try writer.wait(timeout: 30)
    func view(_ column: Int) -> String {
        let parts = readings.compactMap { $0.count > column ? $0[column].split(separator: ":", omittingEmptySubsequences: false).map(String.init) : nil }
        func moves(_ index: Int) -> Bool { Set(parts.compactMap { $0.count > index ? $0[index] : nil }).count > 1 }
        let unreadable = parts.dropFirst().contains { $0.count < 3 || $0[2].isEmpty }
        return "time \(moves(0) ? "follows" : "stays stale"), file \(moves(1) ? "follows" : "stays the one first looked up"), contents \(unreadable ? "unreadable once replaced" : moves(2) ? "follow" : "stay cached")"
    }
    print("INFO guest view of a file the Mac keeps changing, as mtime:inode:contents: rewritten in place: \(view(0)); replaced by rename: \(view(1)); replaced, after listing its folder: \(view(2)); readings \(readings.map { $0.joined(separator: " ") })")

    // The shim judges the broker by its heartbeat: fresh by the guest's clock,
    // or seen to change. Each reading pairs a clock with the heartbeat's
    // modification time, as the guest and as the Mac see them.
    func heartbeatTrace(_ token: String) -> (text: String, guestFollowed: Bool) {
        let heartbeat = transportRoot.appendingPathComponent(token).appendingPathComponent("heartbeat").path
        var seenTimes: Set<String> = []
        let text = (0..<4).map { index in
            if index > 0 { Thread.sleep(forTimeInterval: 1.2) }
            let seen = (try? guest(["/bin/sh", "-c", "printf '%s/%s' \"$(/bin/date +%s)\" \"$(/usr/bin/stat -f %m \"$1\" 2>/dev/null || printf none)\"",
                "sh", heartbeat]))?.stdoutText ?? "unreadable"
            seenTimes.insert(String(seen.split(separator: "/").last ?? ""))
            let modified = (try? fm.attributesOfItem(atPath: heartbeat)[.modificationDate] as? Date).map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            return "guest \(seen) Mac \(Int(Date().timeIntervalSince1970))/\(modified)"
        }.joined(separator: "; ")
        return (text, seenTimes.count > 1)
    }
    func invoke(_ token: String, _ arguments: [String], status: Int32 = 0) throws -> String {
        let output = try guest(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/Users/admin",
            "PARLEY_RELAY_TOKEN=\(token)", shim.path] + arguments)
        guard output.status == status else {
            let trace = output.stderrText.contains("not running") ? " Heartbeat now (clock/modified): \(heartbeatTrace(token))" : ""
            throw tartFailure("guest shim \(arguments.first ?? "") gave \(output.status), expected \(status): \(output.stderrText) \(output.stdoutText)\(trace)")
        }
        return output.stdoutText
    }
    var stale: [String] = []
    for (name, token) in [("source", sourceToken), ("target", targetToken)] {
        let trace = heartbeatTrace(token)
        print("INFO \(name) heartbeat (clock/modified): \(trace.text)")
        if !trace.guestFollowed { stale.append(name) }
    }
    try tartExpect(stale.isEmpty, """
        Parley's file transport cannot run through a Tart share as written: the Mac replaces each endpoint's heartbeat by \
        rename every second and the guest keeps the heartbeat file it first looked up, so its time never moves and the \
        guest's parley judges the app stopped (\(stale.joined(separator: " and ")) endpoint). A time updated in place is what \
        the guest sees (the INFO line above). Relay, Ask and Answer, Delegate with done --file, context staging and the wake \
        path were not run.
        """)
    let identity = try invoke(sourceToken, ["whoami"])
    try tartExpect(identity.contains(sourcePane.id), "the guest's identity lost its source pane")
    print("PASS guest whoami: owner and mode checks and heartbeat accepted through virtio-fs")
    _ = try invoke(sourceToken, ["relay", targetPane.id, "Tart transport probe"])
    print("PASS guest Relay to a distinct fixture pane")
    let pending = TartPendingInvocation { try invoke(sourceToken, ["ask", targetPane.id, "Answer this fixture consultation"]) }
    pending.start()
    let askDeadline = Date().addingTimeInterval(20)
    while broker.consultations().isEmpty && Date() < askDeadline { Thread.sleep(forTimeInterval: 0.05) }
    guard let consultation = broker.consultations().first else { throw tartFailure("the guest's Ask never reached the broker") }
    _ = try invoke(targetToken, ["answer", consultation.id, "Exact correlated answer"])
    try tartExpect(try pending.wait(timeout: 30) == "Exact correlated answer", "the guest's Ask returned another response")
    print("PASS guest correlated Ask and Answer")
    let delegated = try invoke(sourceToken, ["delegate", targetPane.id, "Return the fixture file"])
    let receipt = try JSONSerialization.jsonObject(with: Data(delegated.utf8)) as? [String: Any]
    guard let handoffID = receipt?["handoffID"] as? String else { throw tartFailure("the guest's Delegate returned no handoff id: \(delegated)") }
    let result = project.appendingPathComponent("result.md")
    _ = try guest(["/bin/sh", "-c", "printf '## Implemented\\nFixture only\\n## Tested\\nTart file transport\\n' > \"$1\"", "sh", result.path])
    _ = try invoke(targetToken, ["done", "current", "--file", result.path])
    _ = try invoke(sourceToken, ["wait", handoffID])
    print("PASS guest Delegate, done --file written in the guest at its host path, and result recovery")
    _ = try invoke(sourceToken, ["context", "draft", "--name", "Tart probe", "--file", result.path])
    _ = try invoke(sourceToken, ["context", "list"])
    print("PASS guest context staging and list")
    let outsider = try guest(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "PARLEY_RELAY_TOKEN=\(outsiderToken)", shim.path, "whoami"])
    try tartExpect(outsider.status != 0, "a capability whose endpoint is not shared reached the broker from the guest")
    print("PASS an endpoint that is not shared is unreachable from the VM (shim exit \(outsider.status))")
    let visible = try guest(["/bin/ls", transportRoot.path]).stdoutText.split(separator: "\n").map(String.init)
    let exposed = [sourceToken, targetToken].filter { visible.contains($0) }.count
    print("NOTE every endpoint shared into one VM is listed by any process in it (\(exposed) of 2 here): panes sharing a VM can act as one another, so one VM is one identity boundary")

    // A heartbeat that is gone for a moment is waited out, and the shim's
    // wake entry, made inside the VM, reaches the Mac's inbox watcher.
    transport.stop()
    let inbox = transportRoot.appendingPathComponent(sourceToken).appendingPathComponent("inbox")
    let inboxDescriptor = open(inbox.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
    try tartExpect(inboxDescriptor >= 0, "could not watch the source inbox")
    final class Wakes: @unchecked Sendable { let lock = NSLock(); var count = 0 }
    let wakes = Wakes()
    let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: inboxDescriptor, eventMask: [.write, .link], queue: .global())
    watcher.setEventHandler { wakes.lock.withLock { wakes.count += 1 } }
    watcher.setCancelHandler { close(inboxDescriptor) }
    watcher.resume()
    defer { watcher.cancel() }
    Thread.sleep(forTimeInterval: 1.5)
    let stalled = TartPendingInvocation { try invoke(sourceToken, ["whoami"]) }
    stalled.start()
    Thread.sleep(forTimeInterval: 3)
    try tartExpect(wakes.lock.withLock { wakes.count } > 0, "the guest shim's wake entry never reached the Mac's inbox watcher")
    try transport.start()
    do {
        try tartExpect(try stalled.wait(timeout: 30).contains(sourcePane.id), "the guest shim did not complete once the transport was back")
        print("PASS guest shim waits out a missing heartbeat and wakes the Mac's transport")
    } catch let error as NSError where error.localizedDescription.contains("restarted before replying") {
        print("PASS guest shim reports the transport restart that discarded its request")
    }
}

/// The pane's own terminal: a real Ghostty surface whose command is
/// `tart exec -i -t`, driven the way container panes' spike drives Docker.
@MainActor
private func checkTartGhosttyTerminal(tart: String, clone: String, project: URL) throws {
    _ = NSApplication.shared
    let controller = TerminalController { $0.withBackgroundOpacity(1) }
    let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
    terminal.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: project.path,
        command: GhosttyLaunchCommand.render([tart, "exec", "-i", "-t", clone, "/bin/sh", "-i"]), waitAfterCommand: true,
        resizeThrottleMilliseconds: 64)
    let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = terminal
    terminal.controller = controller
    window.orderFront(nil)
    defer { terminal.controller = nil; window.close() }
    func pump(_ condition: () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path) }
    func submit(_ command: String) throws {
        _ = terminal.acquireProgrammaticFocus()
        guard terminal.paste(text: command), terminal.sendKey(.enter) else { throw tartFailure("Ghostty refused the Tart fixture input") }
    }
    let quoted = "'" + project.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try submit("cd \(quoted) && /bin/ps -o tt=,pgid=,tpgid=,sess= -p $$ > ctty; printf ready > ready")
    guard pump({ exists("ready") }, timeout: 30) else { throw tartFailure("the guest shell did not receive Ghostty input through tart exec") }
    let ctty = (try? String(contentsOf: project.appendingPathComponent("ctty"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
    print("INFO guest shell terminal, process group, terminal's foreground group, session: \(ctty)")
    let initialLayout = Date().addingTimeInterval(0.5)
    _ = pump({ Date() >= initialLayout }, timeout: 1)
    try submit("stty size > settled-size")
    guard pump({ exists("settled-size") }) else { throw tartFailure("the guest did not report its initial terminal size") }
    let before = try String(contentsOf: project.appendingPathComponent("settled-size"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !before.isEmpty, before != "0 0" else { throw tartFailure("the guest TTY has no size after layout settled: \(before)") }
    window.setContentSize(NSSize(width: 800, height: 520))
    let settled = Date().addingTimeInterval(0.5)
    _ = pump({ Date() >= settled }, timeout: 1)
    try submit("stty size > after-size")
    guard pump({ exists("after-size") }) else { throw tartFailure("the resized guest did not answer") }
    let after = try String(contentsOf: project.appendingPathComponent("after-size"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard before != after, after != "0 0" else { throw tartFailure("Ghostty's resize did not reach the guest TTY: \(before) → \(after)") }
    print("PASS Ghostty → tart exec TTY resize: \(before) → \(after)")
    // A vendor CLI is a full-screen program in raw mode: it reads Control-C
    // as the byte 0x03, not as a signal. That is the gate.
    try submit("stty raw -echo; printf w > raw-waiting; /bin/dd bs=1 count=1 2>/dev/null | /usr/bin/od -An -tx1 > raw-byte; stty sane")
    guard pump({ exists("raw-waiting") }), terminal.sendKey(.c, modifiers: .ctrl) else { throw tartFailure("Ghostty refused Control-C") }
    guard pump({ ((try? String(contentsOf: project.appendingPathComponent("raw-byte"), encoding: .utf8)) ?? "").contains("03") }) else {
        throw tartFailure("Control-C did not reach a raw-mode guest program as its byte, which a vendor CLI reads")
    }
    print("PASS Ghostty → tart exec Control-C reaches a raw-mode guest program as 0x03, as a vendor CLI reads it")
    // A command the guest shell runs in cooked mode needs the terminal to
    // turn Control-C into SIGINT for its foreground process group.
    try submit("trap 'printf interrupted > interrupted' INT; printf waiting > waiting; sleep 8; printf slept > slept")
    guard pump({ exists("waiting") }), terminal.sendKey(.c, modifiers: .ctrl) else { throw tartFailure("Ghostty refused Control-C") }
    if pump({ exists("interrupted") }, timeout: 6) {
        print("PASS Ghostty → tart exec Control-C interrupts a cooked-mode guest command (SIGINT)")
    } else {
        print("NOTE Control-C sent no SIGINT to the guest shell's foreground command: the session \(pump({ exists("slept") }, timeout: 10) ? "carried on and the command ran to its end" : "did not finish the command")")
    }
    try submit("printf alive > alive")
    guard pump({ exists("alive") }) else { throw tartFailure("the tart exec session ended after Control-C") }
    print("PASS the tart exec session survives Control-C")
    window.orderOut(nil)
    try submit("printf hidden > hidden")
    guard pump({ exists("hidden") }) else { throw tartFailure("hiding the window stopped the guest's input path") }
    print("PASS hidden Ghostty input reaches the guest")
}

private final class TartPendingInvocation<Value>: @unchecked Sendable {
    private let operation: () throws -> Value
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    init(_ operation: @escaping () throws -> Value) { self.operation = operation }
    func start() {
        Thread.detachNewThread {
            let outcome = Result { try self.operation() }
            self.lock.withLock { self.result = outcome }
            self.done.signal()
        }
    }
    /// What the operation ended with, while it has ended; nil while it runs.
    var finished: String? {
        lock.withLock { result }.map { outcome in
            switch outcome {
            case .success(let value as CommandOutput): return "exit \(value.status): \(value.stderrText.suffix(400))"
            case .success(let value): return "\(value)"
            case .failure(let error): return error.localizedDescription
            }
        }
    }
    func wait(timeout: TimeInterval) throws -> Value {
        guard done.wait(timeout: .now() + timeout) == .success, let result = lock.withLock({ result }) else {
            throw tartFailure("a guest command did not finish within \(Int(timeout)) seconds")
        }
        return try result.get()
    }
}

private func tartFailure(_ message: String) -> NSError {
    NSError(domain: "TartPaneSpike", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func tartExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw tartFailure(message) }
}
