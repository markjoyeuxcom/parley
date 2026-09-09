import AppKit
import Darwin
import Foundation
import GhosttyTerminal
import ParleyCore

/// Explicit real-Docker/real-Ghostty check. No vendor session or credentials.
@MainActor
func checkContainerGhosttySpike(image: String, docker: String) throws {
    try GhosttyLaunchPreflight.check()
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: "/private/tmp/parley-container-tty-\(UUID().uuidString.lowercased())")
    let directory = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("app")
    let protocolFolder = try AgentProtocol.install(in: app)
    let shim = try RelayShim.installCommand(in: app.appendingPathComponent("bin"), transportDirectory: app.appendingPathComponent("relay"))
    let credentials = try RelayCredentials(file: app.appendingPathComponent("credentials.json"))
    let token = try credentials.token(for: "tty-fixture")
    let boundary = try AgentProcessBoundary(applicationDirectory: app, protocolDirectory: protocolFolder,
        shimDirectory: shim.deletingLastPathComponent(), protectedControlEndpoint: app.appendingPathComponent("relay.sock"),
        transportDirectory: app.appendingPathComponent("relay"), paneToken: token)
    let runner = ProcessCommandRunner(timeout: 15, maximumCapturedBytes: 16_000)
    let environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/local/bin:/usr/bin:/bin"]
    func dockerRun(_ argv: [String]) throws -> String {
        let output = try runner.run(executable: URL(fileURLWithPath: docker), arguments: argv, environment: environment)
        guard output.status == 0 else { throw ContainerPaneError.refused("Docker TTY check failed: \(output.stderrText)") }
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let id = try dockerRun(["create", "--rm", "-it", "--init", "--log-driver=none", "--network=none", "--cap-drop=ALL",
        "--security-opt=no-new-privileges=true", "--user", "\(getuid()):\(getgid())", "--workdir", directory.path,
        "--mount", "type=bind,source=\(directory.path),target=\(directory.path)", "--entrypoint", "/bin/sh", image, "-i"])
    guard ContainerLaunchProjection.isHex(id, length: 64) else { throw ContainerPaneError.refused("Docker gave no TTY container receipt.") }
    defer { _ = try? dockerRun(["container", "stop", "--time", "2", id]); _ = try? dockerRun(["container", "rm", id]) }
    let controller = TerminalController { $0.withBackgroundOpacity(1) }
    let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
    terminal.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: directory.path,
        command: GhosttyLaunchCommand.render(boundary.arguments + [docker, "start", "--attach", "--interactive", id]), waitAfterCommand: true,
        resizeThrottleMilliseconds: 64)
    let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = terminal
    terminal.controller = controller
    window.orderFront(nil)
    defer { terminal.controller = nil; window.close() }
    func pump(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
    func submit(_ command: String) throws {
        _ = terminal.acquireProgrammaticFocus()
        guard terminal.paste(text: command), terminal.sendKey(.enter) else { throw ContainerPaneError.refused("Ghostty refused the container fixture input.") }
    }
    try submit("stty size > before-size; printf ready > ready")
    guard pump({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) }) else {
        throw ContainerPaneError.refused("The Docker container did not receive Ghostty input.")
    }
    let initialLayout = Date().addingTimeInterval(0.5)
    _ = pump({ Date() >= initialLayout }, timeout: 1)
    try submit("stty size > settled-size")
    guard pump({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("settled-size").path) }) else {
        throw ContainerPaneError.refused("The initial terminal size was not reported.")
    }
    let before = try String(contentsOf: directory.appendingPathComponent("settled-size"), encoding: .utf8)
    guard !before.contains("0 0") else { throw ContainerPaneError.refused("The container TTY still has no initial size after layout settled.") }
    window.setContentSize(NSSize(width: 800, height: 520))
    let settled = Date().addingTimeInterval(0.3)
    _ = pump({ Date() >= settled }, timeout: 1)
    try submit("stty size > after-size")
    guard pump({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("after-size").path) }) else {
        throw ContainerPaneError.refused("The resized container did not answer.")
    }
    let after = try String(contentsOf: directory.appendingPathComponent("after-size"), encoding: .utf8)
    guard before != after, !after.contains("0 0") else { throw ContainerPaneError.refused("Ghostty resize did not reach the container TTY: \(before) → \(after)") }
    print("PASS Seatbelt → Ghostty → Docker TTY resize: \(before.trimmingCharacters(in: .whitespacesAndNewlines)) → \(after.trimmingCharacters(in: .whitespacesAndNewlines))")
    try submit("trap 'printf interrupted > interrupted' INT; printf waiting > waiting; sleep 30")
    guard pump({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("waiting").path) }), terminal.sendKey(.c, modifiers: .ctrl) else {
        throw ContainerPaneError.refused("Ghostty refused Control-C.")
    }
    guard pump({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("interrupted").path) }) else {
        throw ContainerPaneError.refused("Control-C did not reach the container foreground process.")
    }
    print("PASS Ghostty → Docker foreground Control-C")
    window.orderOut(nil)
    try submit("printf hidden > hidden")
    guard pump({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("hidden").path) }) else {
        throw ContainerPaneError.refused("Hiding the window stopped the container's input path.")
    }
    _ = try dockerRun(["container", "stop", "--time", "2", id])
    let remaining = try dockerRun(["container", "ls", "--all", "--no-trunc", "--filter", "id=\(id)", "--format", "{{.ID}}"])
    guard remaining.isEmpty else { throw ContainerPaneError.refused("Docker did not confirm TTY container removal.") }
    print("PASS hidden Ghostty input and confirmed container stop")
}
