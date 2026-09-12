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
    ("review regression Codex permissions cover both runtimes without a host wrapper", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try reviewController(root)
        let pane = try controller.createPane(kind: .codex, cwd: root.path)
        let command = try controller.launchConfiguration(for: pane.id).command
        try reviewExpect(command.contains("default_permissions=") && !command.contains("/usr/bin/sandbox-exec"), "host launch omitted native permissions or retained the outer wrapper")
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
        // Fixture setup only: a cold `git init`/`git add` on a loaded CI runner
        // has exceeded 3 s, which is not what this check measures.
        let runner = ProcessCommandRunner(timeout: 15)
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
    ("a profile's execution rule reaches Claude and is disclosed where it cannot", {
        let folder = FileManager.default.currentDirectoryPath
        let flexible = PermissionProfileDefinition.builtIns.first { $0.id == "flexible" }!
        let profile = try PermissionProfileResolver.resolve(definition: flexible, paneFolder: folder)
        try reviewExpect(profile.definition.rule(for: .localProcessExecution) != .allow,
            "this check needs a profile that restricts execution")
        try reviewExpect(PermissionProfileAdapter.shellCommandRule(profile) == .requireApproval,
            "a restricted execution capability must produce a requireApproval shell rule")

        // Claude carries it as a rule, because a permission mode cannot say
        // "accept edits but ask before commands".
        let settings = VendorHookAdapter.claudeSettingsJSON(
            shimExecutable: "/tmp/parley", shellCommandRule: PermissionProfileAdapter.shellCommandRule(profile))
        let decoded = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as! [String: Any]
        try reviewExpect(decoded["hooks"] != nil, "the settings dropped the lifecycle hooks")
        let permissions = decoded["permissions"] as? [String: [String]]
        try reviewExpect(permissions?["ask"] == ["Bash"],
            "a profile restricting execution did not produce an ask rule for Bash")

        // Exactly one --settings: the flag is not variadic, so a second would
        // be last-wins and silently drop either the hooks or the permissions.
        let arguments = VendorHookAdapter.launchArguments(
            for: .claude, protocolDirectory: URL(fileURLWithPath: "/tmp/protocol"),
            shellCommandRule: .requireApproval)
        try reviewExpect(arguments.filter { $0 == "--settings" }.count == 1,
            "Claude received more than one --settings; the later one wins and the earlier is lost")

        // An allowing profile uses the shared settings file, and that file
        // pre-allows Parley's own command so protocol commands do not prompt;
        // it must not pre-allow anything else, and the asking profile must
        // not pre-allow parley either, because the person chose asking.
        let broad = PermissionProfileDefinition.builtIns.first { $0.id == "broad-workspace" }!
        let open = try PermissionProfileResolver.resolve(definition: broad, paneFolder: folder, approvedRoots: [folder])
        try reviewExpect(PermissionProfileAdapter.shellCommandRule(open) == .allow,
            "broad-workspace allows execution and must produce no rule")
        try reviewExpect(VendorHookAdapter.launchArguments(
            for: .claude, protocolDirectory: URL(fileURLWithPath: "/tmp/protocol"), shellCommandRule: .allow)
            .contains("/tmp/protocol/claude-hooks.json"),
            "an allowing profile should still use the shared settings file")
        try reviewExpect(permissions?["allow"] == nil,
            "a profile that asks before shell commands pre-allowed something")
        let allowing = try JSONSerialization.jsonObject(with: Data(VendorHookAdapter.claudeSettingsJSON(
            shimExecutable: "/tmp/parley", shellCommandRule: .allow).utf8)) as! [String: Any]
        let allowRules = (allowing["permissions"] as? [String: [String]])?["allow"]
        try reviewExpect(allowRules == ["Bash(parley:*)", "Bash(/tmp/parley:*)"],
            "an allowing profile did not pre-allow exactly Parley's command: \(allowRules ?? [])")
        let protocolDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("parley-claude-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: protocolDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: protocolDirectory) }
        try VendorHookAdapter.install(in: protocolDirectory)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: protocolDirectory.appendingPathComponent("claude-hooks.json"))) as! [String: Any]
        let writtenRules = (written["permissions"] as? [String: [String]])?["allow"] ?? []
        try reviewExpect(written["hooks"] != nil && writtenRules.contains("Bash(parley:*)") && writtenRules.count == 2,
            "the shared settings file a permissive launch names does not carry the hooks plus Parley's allow rules: \(writtenRules)")

        // A vendor that cannot carry the rule must still say so.
        let copilot = PermissionProfileAdapter.launchPlan(for: .copilot, profile: profile)
        try reviewExpect(copilot.detail.contains("not translated into a launch argument"),
            "a vendor that cannot carry the execution rule must disclose that")
        let claudePlan = PermissionProfileAdapter.launchPlan(for: .claude, profile: profile)
        try reviewExpect(!claudePlan.detail.contains("not translated into a launch argument"),
            "Claude now carries the rule and must not claim it was dropped")
        try reviewExpect(claudePlan.detail.contains("outranks the permission mode"),
            "Claude's plan should say the rule outranks the mode")
    }),
    ("review regression cancelAll unblocks context reviews in awaitingReview", {
        let root = try reviewRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens.json"))
        let source = reviewPane("source", .claude), target = reviewPane("target", .codex)
        let sourceToken = try credentials.token(for: source.id)
        let reviewStore = try AgentContextReviewStore(file: root.appendingPathComponent("context-reviews.json"))
        let broker = RelayBroker(
            credentials: credentials,
            panes: { [source, target] },
            paste: { _, _ in },
            submit: { _, _ in },
            contextSubmit: { _, _ in },
            consultationTimeout: 60,
            contextReviewStore: reviewStore
        )
        let staged = broker.handleContextDraft(
            token: sourceToken,
            name: "Test review",
            path: "test.txt",
            text: "sample"
        )
        let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))

        final class SafeResult: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: RelayTextResponse?
            var value: RelayTextResponse? { lock.withLock { storage } }
            func set(_ val: RelayTextResponse) { lock.withLock { storage = val } }
        }
        let askResult = SafeResult()
        DispatchQueue.global(qos: .utility).async {
            askResult.set(broker.handleContextAsk(
                token: sourceToken,
                draftID: summary.id,
                target: target.id,
                text: "question"
            ))
        }

        let deadline = Date().addingTimeInterval(3)
        while broker.contextReviews().first?.state != .awaitingReview && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try reviewExpect(broker.contextReviews().first?.state == .awaitingReview, "draft did not reach awaitingReview")
        try reviewExpect(askResult.value == nil, "ask returned early before cancelAll")

        broker.cancelAll(reason: "App shutdown during review")

        let returnDeadline = Date().addingTimeInterval(3)
        while askResult.value == nil && Date() < returnDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let result = askResult.value else {
            throw NSError(domain: "ReviewRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "cancelAll did not unblock waiting handleContextAsk"])
        }
        try reviewExpect(result.status == 409, "unexpected status code: \(result.status)")
        try reviewExpect(result.text.contains("App shutdown during review"), "unexpected error text: \(result.text)")
        try reviewExpect(broker.contextReviews().first?.state == .interrupted, "context review was not marked interrupted")
        let reloaded = try AgentContextReviewStore(file: root.appendingPathComponent("context-reviews.json"))
        try reviewExpect(reloaded.reviews().first?.state == .interrupted, "persisted context review was not marked interrupted")
    }),
]
