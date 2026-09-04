import Foundation
import ParleyCore

private func reviewExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ReviewRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func reviewRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parley-review-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func reviewPane(_ id: String, _ kind: PaneKind) -> WorkbenchPane {
    WorkbenchPane(id: id, kind: kind, customName: id, terminalTitle: "", cwd: "/private/tmp", currentCommand: kind.rawValue, isActive: false, workspaceID: "workspace", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "workspace", inputAvailable: true)
}
private func reviewController(_ root: URL) throws -> WorkbenchController {
    let controller = try WorkbenchController(applicationDirectory: root, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
    try controller.bootstrap(cwd: root.path)
    controller.configureRelay(RelayRuntime(infoFile: root.appendingPathComponent("relay-url"), shimDirectory: root.appendingPathComponent("bin"), transportDirectory: root.appendingPathComponent("transport"), credentials: try RelayCredentials(file: root.appendingPathComponent("fixture-tokens.json"))))
    return controller
}

@MainActor let reviewRegressionChecks: [(String, () throws -> Void)] = [
    ("review regression Ask preserves early answer and cancellation", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let source = reviewPane("source", .codex), target = reviewPane("target", .claude)
        let sourceToken = try credentials.token(for: source.id), targetToken = try credentials.token(for: target.id)
        for cancel in [false, true] {
          for lateFailure in [false, true] {
            var broker: RelayBroker!
            broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in
                if cancel { _ = broker.cancelHandoff(token: sourceToken, handoffID: "current") }
                else { _ = broker.handleAnswer(token: targetToken, consultationID: broker.consultations().first!.id, text: "answer") }
                if lateFailure { throw NSError(domain: "writer-after-delivery", code: 1) }
            }, consultationTimeout: 0.1)
            let response = broker.handleAsk(token: sourceToken, target: target.id, text: "question")
            if !cancel { try reviewExpect(response.text == "answer", "late writer error replaced the returned answer") }
            try reviewExpect(broker.handoffs().first!.state == (cancel ? .cancelled : .completed), "submission resurrected a terminal Ask")
          }
        }
    }),
    ("review regression exited panes end tracked work", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        var source = reviewPane("source", .codex), target = reviewPane("target", .claude)
        let token = try credentials.token(for: source.id)
        let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in })
        _ = broker.handleDelegate(token: token, target: target.id, text: "task")
        target.inputAvailable = false
        try reviewExpect(broker.handoffs().first!.state == .waiting, "detachment is not process exit")
        target.isDead = true
        try reviewExpect(broker.handoffs().first!.state == .failed, "exited target left delegation active")
        target.isDead = false; target.inputAvailable = true
        _ = broker.handleDelegate(token: token, target: target.id, text: "another task")
        source.isStarted = false
        try reviewExpect(!broker.handoffs().contains { $0.state == .waiting }, "stopped source left delegation active")
    }),
    ("review regression launch protects both runtimes and control sockets", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try reviewController(root)
        let pane = try controller.createPane(kind: .claude, cwd: root.path)
        let command = try controller.launchConfiguration(for: pane.id).command
        try reviewExpect(command.contains("deny network-outbound"), "real launch omitted socket deny")
        for mode in ParleyRuntimeMode.allCases {
            let runtime = ParleyRuntime.make(mode: mode, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            try reviewExpect(command.contains(runtime.applicationDirectory.path), "sibling control directory unprotected")
            try reviewExpect(command.contains(RelayFileTransport.runtimeDirectory(applicationDirectory: runtime.applicationDirectory).path), "sibling transport unprotected")
        }
    }),
    ("review regression PID equality cannot restore a previous generation", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try reviewController(root)
        let pane = try controller.createPane(kind: .claude, cwd: root.path)
        let state = root.appendingPathComponent("workbench-state.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
        object["ownerSessionID"] = "a-previous-process-with-the-same-pid"
        try JSONSerialization.data(withJSONObject: object).write(to: state)
        let reopened = try reviewController(root)
        try reviewExpect(try reopened.listPanes().first { $0.id == pane.id }!.isStarted == false, "PID reuse auto-restored agent")
    }),
    ("review regression native pane IDs support external navigation", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try reviewController(root)
        let pane = try controller.createPane(kind: .claude, cwd: root.path)
        let url = try ExternalNavigation.url(for: .pane(pane.id))
        try reviewExpect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == pane.id, "native pane ID failed navigation")
    }),
    ("review regression hook failures are non-blocking and silent", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let protocolDirectory = try AgentProtocol.install(in: root)
        let shimDirectory = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        let shim = shimDirectory.appendingPathComponent("parley")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: protocolDirectory.appendingPathComponent("claude-hooks.json"))) as! [String: Any]
        let hooks = json["hooks"] as! [String: [[String: Any]]]
        let copilotJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: protocolDirectory.appendingPathComponent("copilot-hooks/hooks.json"))) as! [String: Any]
        let copilotHooks = copilotJSON["hooks"] as! [String: [[String: Any]]]
        let codexArguments = VendorHookAdapter.launchArguments(for: .codex, protocolDirectory: protocolDirectory)
        let expression = try NSRegularExpression(pattern: #"command = ("(?:\\.|[^"])*")"#)
        let codexCommands = try codexArguments.filter { $0.hasPrefix("hooks.") }.map { config -> String in
            let match = expression.firstMatch(in: config, range: NSRange(config.startIndex..., in: config))!
            let quoted = String(config[Range(match.range(at: 1), in: config)!])
            return try JSONDecoder().decode(String.self, from: Data(quoted.utf8))
        }
        for status in [0, 2, 22] {
            // A fake executable; never signals any live Parley broker.
            try "#!/bin/sh\necho unexpected-output\necho unavailable >&2\nexit \(status)\n".write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            for group in copilotHooks.values.flatMap({ $0 }) {
                let result = try ProcessCommandRunner(timeout: 2).run(executable: URL(fileURLWithPath: group["exec"] as! String), arguments: group["args"] as! [String], environment: ["PATH": "/usr/bin:/bin"], input: nil)
                try reviewExpect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty, "Copilot hook propagated output or failure")
            }
            for command in codexCommands {
                let result = try ProcessCommandRunner(timeout: 2).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin"], input: nil)
                try reviewExpect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty, "Codex hook propagated output or failure")
            }
            for event in ["UserPromptSubmit", "Stop"] {
                let command = (hooks[event]!.first!["hooks"] as! [[String: Any]]).first!["command"] as! String
                let result = try ProcessCommandRunner(timeout: 2).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin"], input: nil)
                try reviewExpect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty, "advisory hook propagated output or failure")
            }
        }
    }),
    ("review regression human review requires durable save", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let source = reviewPane("source", .codex), target = reviewPane("target", .claude)
        let token = try credentials.token(for: source.id), targetToken = try credentials.token(for: target.id)
        let file = root.appendingPathComponent("journal")
        let journal = try RelayHandoffJournal(file: file)
        let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in }, handoffJournal: journal)
        let id = broker.handleDelegate(token: token, target: target.id, text: "task").body.handoffID!
        _ = broker.handleDelegationResult(token: targetToken, handoffID: id, text: "result", succeeded: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        let result = broker.updateHandoffReview(RelayHandoffReviewUpdate(handoffID: id, expectedReviewRevision: 0, verdict: nil, note: "note"))
        try reviewExpect(result.status >= 400, "failed persistence was acknowledged as saved")
        try reviewExpect(broker.handoffs().first!.humanReviewNote == nil, "failed review leaked into memory")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let retry = broker.updateHandoffReview(RelayHandoffReviewUpdate(handoffID: id, expectedReviewRevision: 0, verdict: nil, note: "note"))
        try reviewExpect(retry.status == 200, "failed save consumed review revision")
        try reviewExpect(try RelayHandoffJournal(file: file).handoffs().first!.humanReviewNote == "note", "successful retry not durable")
    }),
    ("review regression truncated Git facts never overstate lower bound", {
        let before = DelegationGitSnapshot(capturedAt: Date(), folder: "/tmp", headRevision: "same", branch: "main", isDetached: false, dirtyPaths: (1...200).map { String(format: "a%03d", $0) }, dirtyPathCount: 201)
        let after = DelegationGitSnapshot(capturedAt: Date(), folder: "/tmp", headRevision: "same", branch: "main", isDetached: false, dirtyPaths: (0...199).map { String(format: "a%03d", $0) }, dirtyPathCount: 202)
        let comparison = DelegationGitFacts.compare(delegation: before, returned: after)!
        try reviewExpect(comparison.isLowerBound && comparison.changedPathCount <= 1, "truncated window manufactured a second changed path")
    }),
    ("review regression selected Git filenames are literal", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessCommandRunner(timeout: 3)
        func git(_ args: [String]) throws {
            let result = try runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", root.path] + args, environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"], input: nil)
            try reviewExpect(result.status == 0, result.stderrText)
        }
        try git(["init", "-q"])
        for name in ["file[1].txt", "file1.txt", ":(glob)*.txt"] { try "before".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try git(["add", "."])
        for name in ["file[1].txt", "file1.txt", ":(glob)*.txt"] { try "after".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        for name in ["file[1].txt", ":(glob)*.txt"] {
            let part = try ContextPackBuilder().gitDiff(in: root.path, scope: .workingTree, relativeFile: name)
            try reviewExpect(!part.text.contains("file1.txt"), "selected filename expanded to another path")
            try reviewExpect(part.text.contains("+after"), "selected diff missing")
        }
    }),
    ("review regression shell drops inherited pane authority", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try reviewController(root)
        let shell = try controller.createPane(kind: .shell, cwd: root.path)
        let launch = try controller.launchConfiguration(for: shell.id)
        let command = launch.command + " -f -c 'if [ -n \"${PARLEY_RELAY_TOKEN+x}\" ]; then echo inherited; else echo absent; fi'"
        let result = try ProcessCommandRunner(timeout: 3).run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin", "PARLEY_RELAY_TOKEN": "fixture-only"], input: nil)
        try reviewExpect(result.status == 0 && result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "absent", "shell inherited parent authority")
    }),
    ("review regression Copilot refuses input before human trust confirmation", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try reviewController(root)
        var deliveries = 0
        controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in deliveries += 1 }, interrupt: { _ in }, captureSelectedText: { _ in "" }, terminate: { _ in }, terminateAll: {}))
        let pane = try controller.createPane(kind: .copilot, cwd: root.path)
        try controller.terminalDidAttach(paneID: pane.id)
        // An advisory hook cannot approve trust on the person's behalf.
        try controller.recordVendorSignal(paneID: pane.id, signal: .sessionStarted, occurredAt: Date())
        do { try controller.paste("message", into: pane.id, submit: true) }
        catch ParleyWorkbenchError.copilotTrustRequired {}
        try reviewExpect(deliveries == 0, "input reached Copilot before trust confirmation")
        try controller.confirmCopilotFolderTrust(paneID: pane.id, expectedGeneration: pane.launchGeneration, expectedFolder: pane.cwd)
        try controller.paste("message", into: pane.id, submit: true)
        try reviewExpect(deliveries == 1, "confirmed Copilot handoff was refused")
        try controller.restartPane(pane.id)
        try controller.terminalDidAttach(paneID: pane.id)
        do { try controller.paste("message", into: pane.id, submit: true) }
        catch ParleyWorkbenchError.copilotTrustRequired {}
        try reviewExpect(deliveries == 1, "trust confirmation survived restart")
        do {
            try controller.confirmCopilotFolderTrust(paneID: pane.id, expectedGeneration: pane.launchGeneration, expectedFolder: pane.cwd)
            throw NSError(domain: "stale confirmation accepted", code: 1)
        } catch ParleyWorkbenchError.unsafeRelayTarget {}
    }),
    ("review regression Claude default uses canonical permission mode", {
        let profile = try PermissionProfileResolver.resolve(definition: PermissionProfileDefinition.builtIns.first { $0.id == "default" }!, paneFolder: FileManager.default.currentDirectoryPath)
        try reviewExpect(PermissionProfileAdapter.launchPlan(for: .claude, profile: profile).arguments == ["--permission-mode", "default"], "version-specific alias emitted")
    }),
]
