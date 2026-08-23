import Foundation

public enum RuntimeReadinessID: String, CaseIterable, Sendable {
    case tmux
    case core
    case relay
    case protocolRules
    case claude
    case codex
    case agy
    case copilot
}

public enum RuntimeReadinessCategory: String, Sendable {
    case localSystem
    case vendor
}

public enum RuntimeReadinessState: String, Sendable {
    case ready
    case attention
    case unavailable
    case unchecked
}

public struct RuntimeReadinessItem: Identifiable, Equatable, Sendable {
    public let id: RuntimeReadinessID
    public let category: RuntimeReadinessCategory
    public let title: String
    public let state: RuntimeReadinessState
    public let detail: String
    public let recovery: String?
    public let required: Bool

    public init(
        id: RuntimeReadinessID,
        category: RuntimeReadinessCategory,
        title: String,
        state: RuntimeReadinessState,
        detail: String,
        recovery: String? = nil,
        required: Bool
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.state = state
        self.detail = detail
        self.recovery = recovery
        self.required = required
    }
}

public struct RuntimeReadinessSnapshot: Equatable, Sendable {
    public let checkedAt: Date
    public let items: [RuntimeReadinessItem]

    public init(checkedAt: Date = Date(), items: [RuntimeReadinessItem]) {
        self.checkedAt = checkedAt
        self.items = items
    }

    public func item(_ id: RuntimeReadinessID) -> RuntimeReadinessItem? {
        items.first { $0.id == id }
    }

    public var localItems: [RuntimeReadinessItem] {
        items.filter { $0.category == .localSystem }
    }

    public var vendorItems: [RuntimeReadinessItem] {
        items.filter { $0.category == .vendor }
    }

    public var readyVendorCount: Int {
        vendorItems.count { $0.state == .ready }
    }

    public var availableVendorCount: Int {
        vendorItems.count { $0.state == .ready || $0.state == .unchecked }
    }

    public var isOperational: Bool {
        localItems.allSatisfy { !$0.required || $0.state == .ready }
            && availableVendorCount >= 2
    }
}

/// Checks local dependencies and the vendors' own status-only commands. No
/// prompt is submitted and no model is invoked. Copilot currently exposes an
/// interactive login command but no read-only status command, so its state is
/// deliberately reported as unchecked instead of guessed.
public final class RuntimeReadinessChecker: @unchecked Sendable {
    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(
        runner: any CommandRunning = ProcessCommandRunner(timeout: 8),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    public func check(
        environment: [String: String],
        applicationDirectory: URL,
        coreHealthy: Bool,
        panes: [TmuxPane]
    ) -> RuntimeReadinessSnapshot {
        RuntimeReadinessSnapshot(items: [
            checkTmux(environment: environment),
            checkCore(coreHealthy),
            checkRelay(applicationDirectory: applicationDirectory),
            checkProtocol(applicationDirectory: applicationDirectory, panes: panes),
            checkClaude(environment: environment),
            checkCodex(environment: environment),
            checkAgy(environment: environment),
            checkCopilot(environment: environment),
        ])
    }

    private func checkTmux(environment: [String: String]) -> RuntimeReadinessItem {
        guard let executable = TmuxController.findTmux(
            environment: environment,
            fileManager: fileManager
        ) else {
            return local(
                .tmux,
                "tmux",
                .unavailable,
                "tmux was not found on Parley's resolved login PATH.",
                recovery: "Install tmux, then reopen Parley or run Check Again."
            )
        }
        guard run(executable, ["-V"], environment: environment)?.status == 0 else {
            return local(
                .tmux,
                "tmux",
                .attention,
                "The tmux executable was found but did not start successfully.",
                recovery: "Repair the tmux installation, then run Check Again."
            )
        }
        return local(.tmux, "tmux", .ready, "Available for Parley's private terminal server.")
    }

    private func checkCore(_ healthy: Bool) -> RuntimeReadinessItem {
        healthy
            ? local(.core, "Coordination core", .ready, "The authenticated local core is responding.")
            : local(
                .core,
                "Coordination core",
                .attention,
                "The terminal grid can remain attached, but cross-vendor actions are paused.",
                recovery: "Use Reconnect in the workbench before sending an Ask."
            )
    }

    private func checkRelay(applicationDirectory: URL) -> RuntimeReadinessItem {
        let command = applicationDirectory.appendingPathComponent("bin/parley")
        guard fileManager.isExecutableFile(atPath: command.path),
              let text = try? String(contentsOf: command, encoding: .utf8),
              text.contains("Parley Native managed relay shim") else {
            return local(
                .relay,
                "Relay command",
                .attention,
                "Parley's managed relay command is missing or was replaced.",
                recovery: "Reopen Parley to reinstall its owner-only relay command."
            )
        }
        return local(.relay, "Relay command", .ready, "The owner-only local relay command is installed.")
    }

    private func checkProtocol(
        applicationDirectory: URL,
        panes: [TmuxPane]
    ) -> RuntimeReadinessItem {
        let rules = applicationDirectory.appendingPathComponent("agent-protocol/AGENTS.md")
        guard let installed = try? String(contentsOf: rules, encoding: .utf8),
              installed == AgentProtocol.text else {
            return local(
                .protocolRules,
                "Cross-vendor protocol",
                .attention,
                "The installed agent instructions do not match this Parley build.",
                recovery: "Reopen Parley to refresh the shared protocol file."
            )
        }
        let stale = AgentProtocol.stalePaneIDs(in: panes)
        guard stale.isEmpty else {
            return local(
                .protocolRules,
                "Cross-vendor protocol",
                .attention,
                "\(stale.count) running agent pane\(stale.count == 1 ? " has" : "s have") an older protocol.",
                recovery: "Restart only the panes marked Protocol Stale when you are ready to end those conversations."
            )
        }
        return local(
            .protocolRules,
            "Cross-vendor protocol",
            .ready,
            "Shared protocol v\(AgentProtocol.version) is installed for every new agent pane."
        )
    }

    private func checkClaude(environment: [String: String]) -> RuntimeReadinessItem {
        guard let executable = executable(named: "claude", environment: environment) else {
            return missingVendor(.claude, "Claude", recovery: "Install Claude Code and sign in before starting a Claude pane.")
        }
        let output = run(executable, ["auth", "status", "--json"], environment: environment)
        let authenticated = output.flatMap { try? JSONDecoder().decode(ClaudeAuthStatus.self, from: $0.stdout) }?.loggedIn
        guard output?.status == 0, authenticated == true else {
            return vendor(
                .claude,
                "Claude",
                .attention,
                "Installed, but Claude did not report an authenticated account.",
                recovery: "Run `claude auth login` in Terminal, then Check Again."
            )
        }
        return vendor(.claude, "Claude", .ready, "Installed and authenticated.")
    }

    private func checkCodex(environment: [String: String]) -> RuntimeReadinessItem {
        guard let executable = executable(named: "codex", environment: environment) else {
            return missingVendor(.codex, "Codex", recovery: "Install Codex and sign in before starting a Codex pane.")
        }
        guard run(executable, ["login", "status"], environment: environment)?.status == 0 else {
            return vendor(
                .codex,
                "Codex",
                .attention,
                "Installed, but Codex did not report an authenticated account.",
                recovery: "Run `codex login` in Terminal, then Check Again."
            )
        }
        return vendor(.codex, "Codex", .ready, "Installed and authenticated.")
    }

    private func checkAgy(environment: [String: String]) -> RuntimeReadinessItem {
        guard let executable = executable(named: "agy", environment: environment) else {
            return missingVendor(.agy, "Agy", recovery: "Install Agy and sign in before starting an Agy pane.")
        }
        guard let output = run(executable, ["models"], environment: environment),
              output.status == 0,
              !output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return vendor(
                .agy,
                "Agy",
                .attention,
                "Installed, but Agy could not list the models available to the signed-in account.",
                recovery: "Run `agy` in Terminal to complete sign-in, then Check Again."
            )
        }
        return vendor(.agy, "Agy", .ready, "Installed and account access confirmed without invoking a model.")
    }

    private func checkCopilot(environment: [String: String]) -> RuntimeReadinessItem {
        guard executable(named: "copilot", environment: environment) != nil else {
            return missingVendor(
                .copilot,
                "Copilot",
                recovery: "Install GitHub Copilot CLI and sign in before starting a Copilot pane."
            )
        }
        return vendor(
            .copilot,
            "Copilot",
            .unchecked,
            "Installed. Copilot exposes no status-only authentication command, so Parley will not guess or open a login flow.",
            recovery: "If a new pane asks you to sign in, run `copilot login` in Terminal and restart that pane."
        )
    }

    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]
    ) -> CommandOutput? {
        try? runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: nil
        )
    }

    private func executable(named name: String, environment: [String: String]) -> URL? {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        let conventionalCandidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        var seen = Set<String>()
        return (pathCandidates + conventionalCandidates).first { candidate in
            seen.insert(candidate.standardizedFileURL.path).inserted
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    private func local(
        _ id: RuntimeReadinessID,
        _ title: String,
        _ state: RuntimeReadinessState,
        _ detail: String,
        recovery: String? = nil
    ) -> RuntimeReadinessItem {
        RuntimeReadinessItem(
            id: id,
            category: .localSystem,
            title: title,
            state: state,
            detail: detail,
            recovery: recovery,
            required: true
        )
    }

    private func vendor(
        _ id: RuntimeReadinessID,
        _ title: String,
        _ state: RuntimeReadinessState,
        _ detail: String,
        recovery: String? = nil
    ) -> RuntimeReadinessItem {
        RuntimeReadinessItem(
            id: id,
            category: .vendor,
            title: title,
            state: state,
            detail: detail,
            recovery: recovery,
            required: false
        )
    }

    private func missingVendor(
        _ id: RuntimeReadinessID,
        _ title: String,
        recovery: String
    ) -> RuntimeReadinessItem {
        vendor(
            id,
            title,
            .unavailable,
            "Not installed on Parley's resolved login PATH. This vendor is optional.",
            recovery: recovery
        )
    }
}

private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
}
