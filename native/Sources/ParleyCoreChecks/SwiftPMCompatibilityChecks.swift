import Foundation
import ParleyCore

private func swiftPMExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NSError(domain: "SwiftPMCompatibility", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func withSwiftPMFixture(enabled: Bool = true, _ body: (URL, WorkbenchController) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-swiftpm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let toolchain = root.appendingPathComponent("selected toolchain")
    try FileManager.default.createDirectory(at: toolchain, withIntermediateDirectories: true)
    let swift = toolchain.appendingPathComponent("swift")
    try "#!/bin/sh\nif [ \"$#\" -gt 0 ]; then printf '%s\\0' \"$@\"; fi\nexit 23\n".write(to: swift, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: swift.path)
    let controller = try WorkbenchController(
        applicationDirectory: root.appendingPathComponent("application"),
        environment: ["PATH": "\(toolchain.path):/usr/bin:/bin", "SHELL": "/bin/zsh"],
        swiftPMCompatibilityEnabled: enabled
    )
    try controller.bootstrap(cwd: root.path)
    controller.configureRelay(RelayRuntime(
        infoFile: root.appendingPathComponent("relay-url"), shimDirectory: root.appendingPathComponent("bin"),
        transportDirectory: root.appendingPathComponent("transport"),
        credentials: try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
    ))
    try body(root, controller)
}

private func swiftPMHelper(_ launch: GhosttyPaneLaunch) throws -> URL {
    guard let path = launch.environment["PARLEY_SWIFT_COMMAND"] else {
        throw NSError(domain: "SwiftPMCompatibility", code: 1, userInfo: [NSLocalizedDescriptionKey: "agent launch omitted the SwiftPM helper"])
    }
    return URL(fileURLWithPath: path)
}

func checkSwiftPMCompatibilityLaunchScope() throws {
    try withSwiftPMFixture { root, controller in
        for kind in PaneKind.allCases.filter(\.isAgent) {
            let pane = try controller.createPane(kind: kind, cwd: root.path)
            let launch = try controller.launchConfiguration(for: pane.id)
            try swiftPMExpect(launch.environment["PARLEY_SWIFTPM_COMPATIBILITY"] == "1", "\(kind) launch omitted SwiftPM compatibility")
            let helper = try swiftPMHelper(launch)
            try swiftPMExpect(FileManager.default.isExecutableFile(atPath: helper.path), "packaged runtime did not install an executable helper")
            try swiftPMExpect(helper.path.hasPrefix(controller.protocolDirectory.path + "/"), "helper escaped the existing read-only protocol boundary")
            try swiftPMExpect(launch.environment["PATH"]?.split(separator: ":").contains(Substring(helper.deletingLastPathComponent().path)) == true, "agent PATH omitted the helper")
            try swiftPMExpect(launch.command.contains("sandbox-exec") && launch.command.contains("deny file-read* file-write*"), "compatibility removed the outer boundary")
        }
        let shell = try controller.createPane(kind: .shell, cwd: root.path)
        let launch = try controller.launchConfiguration(for: shell.id)
        try swiftPMExpect(launch.environment["PARLEY_SWIFTPM_COMPATIBILITY"] == nil && launch.environment["PARLEY_SWIFT_COMMAND"] == nil, "human shell received agent compatibility")
        try swiftPMExpect(!launch.environment["PATH", default: ""].contains("swiftpm-bin"), "human shell received a Swift wrapper")
    }
}

func checkSwiftPMCompatibilityArgumentsAndToolchain() throws {
    try withSwiftPMFixture { root, controller in
        let pane = try controller.createPane(kind: .codex, cwd: root.path)
        let launch = try controller.launchConfiguration(for: pane.id)
        let helper = try swiftPMHelper(launch)
        let alias = root.appendingPathComponent("helper alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: helper.deletingLastPathComponent())
        let runner = ProcessCommandRunner(timeout: 3)
        func run(_ arguments: [String], mode: String? = "1", kind: String = "codex", path: String? = nil) throws -> CommandOutput {
            var environment = launch.environment
            environment["PARLEY_SWIFTPM_COMPATIBILITY"] = mode
            environment["PARLEY_PANE_KIND"] = kind
            environment["PATH"] = path ?? "\(alias.path):\(launch.environment["PATH"]!)"
            return try runner.run(executable: helper, arguments: arguments, environment: environment, input: nil)
        }
        func args(_ output: CommandOutput) -> [String] {
            output.stdoutText.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
        for verb in ["build", "test", "run", "package"] {
            let original = [verb, "a path with spaces", "", "literal;$(do-not-run)\nnext", "--", "--disable-sandbox"]
            let result = try run(original)
            try swiftPMExpect(result.status == 23, "helper changed the selected toolchain's exit code")
            try swiftPMExpect(args(result) == [verb, "--disable-sandbox"] + original.dropFirst(), "helper changed argv or failed to add the SwiftPM option")
        }
        for arguments in [["--version"], ["--help"], ["-frontend", "file.swift"], ["script.swift"], []] {
            try swiftPMExpect(args(try run(arguments)) == arguments, "helper changed a non-SwiftPM invocation")
        }
        for mode in [nil, "0", "other"] as [String?] {
            try swiftPMExpect(args(try run(["build"], mode: mode)) == ["build"], "helper ignored its explicit compatibility switch")
        }
        try swiftPMExpect(args(try run(["build"], kind: "shell")) == ["build"], "helper enabled itself for a human shell")
        let missing = try run(["build"], path: "\(helper.deletingLastPathComponent().path):\(alias.path)")
        try swiftPMExpect(missing.status == 127 && missing.stderrText.contains("Swift toolchain"), "missing toolchain recursed or selected an unrelated compiler")
    }
}

func checkSwiftPMCompatibilityOptInAndRestart() throws {
    try withSwiftPMFixture(enabled: false) { root, controller in
        let pane = try controller.createPane(kind: .codex, cwd: root.path)
        let disabled = try controller.launchConfiguration(for: pane.id)
        try swiftPMExpect(disabled.environment["PARLEY_SWIFTPM_COMPATIBILITY"] == "0", "compatibility did not default to off")
        try swiftPMExpect(!disabled.environment["PATH", default: ""].contains("swiftpm-bin"), "disabled launch shadowed Swift")
        controller.setSwiftPMCompatibilityEnabled(true)
        let retained = try controller.launchConfiguration(for: pane.id)
        try swiftPMExpect(retained.environment == disabled.environment, "a setting change altered a retained launch")
        try controller.restartPane(pane.id)
        let restarted = try controller.launchConfiguration(for: pane.id)
        try swiftPMExpect(restarted.environment["PARLEY_SWIFTPM_COMPATIBILITY"] == "1", "explicit restart did not apply the enabled setting")
        controller.setSwiftPMCompatibilityEnabled(false)
        try swiftPMExpect(try controller.launchConfiguration(for: pane.id).environment == restarted.environment, "disabling compatibility altered a retained process")
        try controller.restartPane(pane.id)
        try swiftPMExpect(try controller.launchConfiguration(for: pane.id).environment["PARLEY_SWIFTPM_COMPATIBILITY"] == "0", "restart did not apply opt-out")

        // A nested Development app must not leak its parent's helper into
        // ordinary Shell panes or implicitly opt new agents into compatibility.
        let inheritedController = try WorkbenchController(
            applicationDirectory: root.appendingPathComponent("nested-application"),
            environment: restarted.environment
        )
        try inheritedController.bootstrap(cwd: root.path)
        let shell = try inheritedController.createPane(kind: .shell, cwd: root.path)
        let shellLaunch = try inheritedController.launchConfiguration(for: shell.id)
        try swiftPMExpect(!shellLaunch.environment["PATH", default: ""].contains("swiftpm-bin"), "a nested app inherited the parent's helper")
        try swiftPMExpect(shellLaunch.environment["PARLEY_SWIFTPM_COMPATIBILITY"] == nil, "a nested app inherited compatibility authorization")
    }
}

func checkSwiftPMCompatibilityWithRealManifest() throws {
    try withSwiftPMFixture { root, controller in
        let pane = try controller.createPane(kind: .codex, cwd: root.path)
        let launch = try controller.launchConfiguration(for: pane.id)
        let helper = try swiftPMHelper(launch)
        let project = root.appendingPathComponent("unrelated Swift project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let packageFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let header = try String(contentsOf: packageFile, encoding: .utf8).components(separatedBy: "\n")[0]
        try "\(header)\nimport PackageDescription\nlet package = Package(name: \"ParleySwiftPMProbe\")\n"
            .write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("PARLEY_") { environment.removeValue(forKey: key) }
        environment["PARLEY_PANE"] = "1"
        environment["PARLEY_PANE_KIND"] = "codex"
        environment["PARLEY_SWIFTPM_COMPATIBILITY"] = "1"
        let result = try ProcessCommandRunner(timeout: 120).run(
            executable: helper,
            arguments: ["package", "--package-path", project.path, "dump-package"],
            environment: environment, input: nil
        )
        try swiftPMExpect(result.status == 0, "real SwiftPM could not load the unrelated manifest: \(result.stderrText)")
        let manifest = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        try swiftPMExpect(manifest?["name"] as? String == "ParleySwiftPMProbe", "helper did not execute the selected SwiftPM toolchain")
    }
}
