import Foundation
import ParleyCore

// The terminal type a pane advertises. Ghostty's own `xterm-ghostty` is known
// on this Mac because Parley ships its terminfo; a remote host over ssh has no
// such entry, so ncurses programs refuse to start and readline loses the
// backspace key. These checks pin how the Compatible choice reaches a launch,
// that it reaches nothing already running, and that the two terminal types
// really do differ where Ghostty's terminfo is absent.

private func terminalTypeExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NSError(domain: "TerminalType", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func withTerminalTypeFixture(
    preference: TerminalTypePreference = .default,
    _ body: (URL, WorkbenchController) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-terminal-type-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let controller = try WorkbenchController(
        applicationDirectory: root.appendingPathComponent("application"),
        environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
        terminalTypePreference: preference
    )
    try controller.bootstrap(cwd: root.path)
    controller.configureRelay(RelayRuntime(
        infoFile: root.appendingPathComponent("relay-url"), shimDirectory: root.appendingPathComponent("bin"),
        transportDirectory: root.appendingPathComponent("transport"),
        credentials: try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    ))
    try body(root, controller)
}

/// The words of a rendered launch. Every word is one literal `'…'` and the
/// fixture paths carry no quote, so the quote-space-quote boundary is exact.
private func launchWords(_ launch: GhosttyPaneLaunch) throws -> [String] {
    try terminalTypeExpect(launch.command.hasPrefix("'") && launch.command.hasSuffix("'"), "launch is not rendered as literal words")
    return String(launch.command.dropFirst().dropLast()).components(separatedBy: "' '")
}

private func terminalAssignments(_ words: [String]) -> [String] {
    words.filter { $0.hasPrefix("\(TerminalTypePreference.environmentKey)=") }
}

/// Where `/usr/bin/env` stops reading options and assignments: the first
/// word after the leading `-u NAME` pairs that is not an assignment.
private func executableIndex(_ words: [String]) throws -> Int {
    try terminalTypeExpect(words.first == "/usr/bin/env", "launch does not start with /usr/bin/env: \(words)")
    var index = 1
    while index < words.count {
        if words[index] == "-u" { index += 2; continue }
        if words[index].contains("=") { index += 1; continue }
        return index
    }
    throw NSError(domain: "TerminalType", code: 2, userInfo: [NSLocalizedDescriptionKey: "launch names no executable: \(words)"])
}

func checkTerminalTypeDefaultsToGhosttyAndAddsNothing() throws {
    try terminalTypeExpect(TerminalTypePreference.default == .ghostty, "the default terminal type is not Ghostty's own")
    try terminalTypeExpect(TerminalTypePreference.ghostty.launchAssignment == nil, "Ghostty's own terminal type still rewrites TERM")
    try withTerminalTypeFixture { root, controller in
        for kind in PaneKind.allCases {
            let pane = try controller.createPane(kind: kind, cwd: root.path)
            let launch = try controller.launchConfiguration(for: pane.id)
            let words = try launchWords(launch)
            try terminalTypeExpect(terminalAssignments(words).isEmpty, "\(kind) launch set TERM without a choice: \(words)")
            try terminalTypeExpect(launch.environment["TERM"] == nil, "\(kind) launch put TERM into Ghostty's surface environment")
            try terminalTypeExpect(launch.terminalType == .ghostty, "\(kind) launch reported a terminal type it did not set")
        }
    }
}

func checkCompatibleTerminalTypeReachesEveryHostLaunch() throws {
    try withTerminalTypeFixture(preference: .compatible) { root, controller in
        for kind in PaneKind.allCases {
            let pane = try controller.createPane(kind: kind, cwd: root.path)
            let launch = try controller.launchConfiguration(for: pane.id)
            let words = try launchWords(launch)
            try terminalTypeExpect(terminalAssignments(words) == ["TERM=xterm-256color"], "\(kind) launch did not set TERM exactly once: \(words)")
            let executable = try executableIndex(words)
            try terminalTypeExpect(words[executable - 1] == "TERM=xterm-256color", "\(kind) launch placed TERM where env cannot read it: \(words)")
            // The command is the single source: Ghostty applies its own
            // `term` after the surface environment, so a value there would
            // be a second, contested copy.
            try terminalTypeExpect(launch.environment["TERM"] == nil, "\(kind) launch also put TERM into Ghostty's surface environment")
            try terminalTypeExpect(launch.terminalType == .compatible, "\(kind) launch did not report the compatible terminal type")
            if kind == .shell {
                try terminalTypeExpect(Array(words[executable...]) == ["/bin/zsh", "-l"], "shell launch changed beyond its TERM word: \(words)")
            } else {
                try terminalTypeExpect(words[executable].hasSuffix("/\(kind.rawValue)") || words[executable] == kind.rawValue,
                    "\(kind) launch no longer names its vendor after TERM: \(words)")
            }
        }
    }
}

func checkTerminalTypeChangeAppliesAtRestartOnly() throws {
    try withTerminalTypeFixture { root, controller in
        for kind in [PaneKind.shell, .codex] {
            let pane = try controller.createPane(kind: kind, cwd: root.path)
            let first = try controller.launchConfiguration(for: pane.id)
            try terminalTypeExpect(terminalAssignments(try launchWords(first)).isEmpty, "\(kind) launch set TERM before any choice")
            controller.setTerminalTypePreference(.compatible)
            let retained = try controller.launchConfiguration(for: pane.id)
            try terminalTypeExpect(retained == first, "a setting change altered a retained \(kind) launch")
            try controller.restartPane(pane.id)
            let restarted = try controller.launchConfiguration(for: pane.id)
            try terminalTypeExpect(terminalAssignments(try launchWords(restarted)) == ["TERM=xterm-256color"], "explicit \(kind) restart did not apply the choice")
            try terminalTypeExpect(restarted.terminalType == .compatible, "\(kind) restart did not report the compatible terminal type")
            controller.setTerminalTypePreference(.ghostty)
            try terminalTypeExpect(try controller.launchConfiguration(for: pane.id) == restarted, "reverting the setting altered a retained \(kind) process")
            try controller.restartPane(pane.id)
            let reverted = try controller.launchConfiguration(for: pane.id)
            try terminalTypeExpect(terminalAssignments(try launchWords(reverted)).isEmpty && reverted.terminalType == .ghostty,
                "\(kind) restart did not apply the reverted choice")
            try controller.closePane(pane.id)
        }
    }
}

func checkContainerLaunchKeepsDockerTerminalType() throws {
    // Docker fixes the container's TERM at create; the preference reports
    // that value for a container launch and never rewrites it.
    let config = ContainerConfiguration(dockerExecutable: "/usr/local/bin/docker", daemonEndpoint: "unix:///tmp/docker.sock",
        daemonID: "daemon-one", imageID: "sha256:" + String(repeating: "b", count: 64), imageName: "reviewed-image", legacyCodexSandbox: false)
    let facts = ContainerLaunchFacts(paneID: "pane-fixture", generation: 2, vendor: .codex, folder: "/project",
        endpoint: "/transport/" + String(repeating: "a", count: 48), protocolDirectory: "/runtime/agent-protocol",
        shimDirectory: "/runtime/linux-bin", uid: 501, gid: 20, volume: "parley-home-fixture", owner: "owner-fixture", runtime: "DEV")
    let argv = try ContainerLaunchProjection.createArguments(configuration: config, facts: facts, vendorArguments: [])
    let terms = zip(argv, argv.dropFirst()).filter { $0.0 == "--env" && $0.1.hasPrefix("TERM=") }.map(\.1)
    try terminalTypeExpect(terms == ["TERM=\(TerminalTypePreference.compatible.termValue)"], "container create no longer sets Docker's TERM once: \(terms)")
}

func checkTerminalTypePreferenceIsLiteralAndCodable() throws {
    for preference in TerminalTypePreference.allCases {
        try terminalTypeExpect(TerminalTypePreference(rawValue: preference.termValue) == preference, "\(preference) does not round-trip through its TERM value")
        let decoded = try JSONDecoder().decode(TerminalTypePreference.self, from: try JSONEncoder().encode(preference))
        try terminalTypeExpect(decoded == preference, "\(preference) does not round-trip through JSON")
        try terminalTypeExpect(preference.termValue.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 && $0 != "'" && $0 != "\"" && $0 != "\\" },
            "\(preference) carries a byte a shell word or terminfo name cannot hold")
        try terminalTypeExpect(!preference.label.isEmpty && !preference.detail.isEmpty, "\(preference) has no label or detail")
    }
    try terminalTypeExpect(TerminalTypePreference.compatible.launchAssignment == "TERM=xterm-256color", "the compatible assignment changed shape")
    try terminalTypeExpect(GhosttyLaunchCommand.render(["TERM=xterm-256color"]) == "'TERM=xterm-256color'", "the assignment is not rendered as one literal word")
    try terminalTypeExpect(TerminalTypePreference(rawValue: "xterm") == nil, "an unknown terminal type decoded")
    try terminalTypeExpect(TerminalTypePreference.remoteTerminfoCommand.hasPrefix("infocmp -x xterm-ghostty | ssh "), "the remote terminfo command no longer copies Ghostty's entry")
}

/// Reproduces the remote host locally: with Ghostty's terminfo directory out
/// of reach, `xterm-ghostty` is unknown while `xterm-256color` is found in
/// the system database. A user-level `~/.terminfo` is kept out of the way.
func checkCompatibleTerminalTypeIsKnownWithoutGhosttyTerminfo() throws {
    let tput = URL(fileURLWithPath: "/usr/bin/tput")
    guard FileManager.default.isExecutableFile(atPath: tput.path) else {
        throw NSError(domain: "TerminalType", code: 3, userInfo: [NSLocalizedDescriptionKey: "prerequisite: /usr/bin/tput is missing"])
    }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("parley-terminal-type-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let runner = ProcessCommandRunner(timeout: 10)
    let environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "TERMINFO": home.appendingPathComponent("absent").path]
    let ghostty = try runner.run(executable: tput, arguments: ["-T", TerminalTypePreference.ghostty.termValue, "colors"], environment: environment, input: nil)
    try terminalTypeExpect(ghostty.status != 0 && ghostty.stderrText.contains("unknown terminal"),
        "xterm-ghostty was found without Ghostty's terminfo, so the remote-host failure is not reproduced (\(ghostty.status)): \(ghostty.stderrText)")
    let compatible = try runner.run(executable: tput, arguments: ["-T", TerminalTypePreference.compatible.termValue, "colors"], environment: environment, input: nil)
    try terminalTypeExpect(compatible.status == 0 && compatible.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "256",
        "xterm-256color is not in the system terminfo database (\(compatible.status)): \(compatible.stderrText)")
}

@MainActor
let terminalTypeChecks: [(String, () throws -> Void)] = [
    ("terminal type defaults to Ghostty's own and adds nothing to a launch", checkTerminalTypeDefaultsToGhosttyAndAddsNothing),
    ("compatible terminal type reaches every host launch as one env word", checkCompatibleTerminalTypeReachesEveryHostLaunch),
    ("terminal type change applies at the next restart and never to a retained launch", checkTerminalTypeChangeAppliesAtRestartOnly),
    ("container launches keep Docker's fixed terminal type", checkContainerLaunchKeepsDockerTerminalType),
    ("terminal type preference is literal and codable", checkTerminalTypePreferenceIsLiteralAndCodable),
    ("compatible terminal type is known where Ghostty's terminfo is absent", checkCompatibleTerminalTypeIsKnownWithoutGhosttyTerminfo),
]
